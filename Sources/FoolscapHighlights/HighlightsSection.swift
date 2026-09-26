import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// Import progress and outcome, for the page and the settings pane.
@MainActor
@Observable
public final class HighlightsImportStatus {
    public var isRunning = false
    public var phase: String?
    public var lastRun: Date?
    public var lastReport: ImportReport?
    public var lastError: String?
    /// The Kindle app's container could not be read: Full Disk Access.
    public var needsFullDiskAccess = false
    public init() {}
}

/// When the Kindle app's annotations are checked for new highlights. Every
/// choice but `manual` also checks once when the tab starts.
public enum HighlightsImportSchedule: String, CaseIterable, Sendable {
    case atLaunch, whenKindleSyncs, hourly, everyThreeHours, daily, manual

    public static let key = "highlightsImportSchedule"
    /// Whether an import may open the Kindle app hidden to fetch what is new (default on).
    public static let opensKindleKey = "highlightsOpensKindle"

    public var title: String {
        switch self {
        case .atLaunch: return "When Foolscap opens"
        case .whenKindleSyncs: return "Whenever the Kindle app syncs"
        case .hourly: return "Every hour"
        case .everyThreeHours: return "Every 3 hours"
        case .daily: return "Once a day"
        case .manual: return "Only when I ask"
        }
    }

    var minutes: Int? {
        switch self {
        case .hourly: return 60
        case .everyThreeHours: return 180
        case .daily: return 24 * 60
        default: return nil
        }
    }

    /// Whether the tab's start should import: every schedule but manual does,
    /// and "once a day" only when the last run is a day old.
    public static func startupImportDue(_ schedule: HighlightsImportSchedule, lastRun: Date?, now: Date = Date()) -> Bool {
        switch schedule {
        case .manual: return false
        case .daily: return lastRun.map { now.timeIntervalSince($0) >= 24 * 3600 } ?? true
        default: return true
        }
    }
}

/// The Highlights tab: Kindle highlights as one markdown file per book, three
/// of them a day, browsed by cover, searched and tagged like tasks.
@MainActor
@Observable
public final class HighlightsSection: NotebookSection {
    public static let sectionID = "highlights"
    public let id = HighlightsSection.sectionID
    public let tab = TabAppearance(label: "Highlights", systemImage: "highlighter", colorIndex: 2, shortcut: "l")

    public enum Mode: Equatable {
        case today, books
        case book(String)
    }

    public var mode: Mode = .today
    public var searchText = ""
    public var selectedTag: String?
    /// Every highlight in the index, in reading order per book.
    public private(set) var items: [HighlightItem] = []
    public private(set) var books: [SearchIndex.HighlightBookRecord] = []
    /// Book path → its cover file, found once per reload (not stat-ed per cell).
    public private(set) var coverURLs: [String: URL] = [:]
    /// Today's three.
    public private(set) var picks: [HighlightItem] = []
    /// A highlight to scroll to once its book page is shown (from search or a card).
    public var pendingHighlightID: String?
    public let status = HighlightsImportStatus()
    let library: NotebookLibrary

    @ObservationIgnored private let extractor: any KindleExtracting
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let dailyURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var importer: HighlightsImporter?
    @ObservationIgnored private var scheduler: PeriodicScheduler?
    @ObservationIgnored private var watcher: KindleWatcher?
    @ObservationIgnored private var changeListener: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var midnightTask: Task<Void, Never>?
    @ObservationIgnored private var history = DailyPickHistory()
    /// Edits are written one after another (see `edit`).
    @ObservationIgnored private var writeChain: Task<Void, Never>?
    @ObservationIgnored private lazy var provider = HighlightsSearchProvider(section: self)
    @ObservationIgnored private var started = false

    public init(library: NotebookLibrary, extractor: any KindleExtracting = NativeKindleExtractor(),
                stateURL: URL = HighlightsPaths.stateURL, dailyURL: URL = HighlightsPaths.dailyURL,
                defaults: UserDefaults = .standard) {
        self.library = library
        self.extractor = extractor
        self.stateURL = stateURL
        self.dailyURL = dailyURL
        self.defaults = defaults
    }

    // MARK: Settings

    public var schedule: HighlightsImportSchedule {
        HighlightsImportSchedule(rawValue: defaults.string(forKey: HighlightsImportSchedule.key) ?? "") ?? .atLaunch
    }

    /// Called by the settings pane after the schedule changes.
    public func settingsChanged() {
        guard started else { return }
        applySchedule()
    }

    public var kindleInstalled: Bool {
        KindleLibrary.isInstalled(dataDirectory: (extractor as? NativeKindleExtractor)?.dataDirectory ?? KindleLibrary.defaultDataDirectory)
    }
    public var kfxAvailability: KFXExtractor.Availability { (extractor as? NativeKindleExtractor)?.kfx.availability ?? .ready }

    // MARK: Lifecycle

    /// Load the index, watch for changes and start the import schedule. Off
    /// (the tab disabled), none of this exists.
    public func start() {
        guard !started else { return }
        started = true
        history = DailyPickHistory.load(from: dailyURL)
        importer = HighlightsImporter(extractor: extractor, library: library, stateURL: stateURL)
        changeListener = Task { [weak self] in
            guard let self else { return }
            for await _ in library.changes {
                guard !Task.isCancelled else { return }
                self.scheduleReload()
            }
        }
        scheduleReload()
        applySchedule()
        let lastRun = HighlightsState.load(from: stateURL).lastRun
        if HighlightsImportSchedule.startupImportDue(schedule, lastRun: lastRun) {
            startupTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.importNow()
            }
        }
        scheduleMidnight()
    }

    public func stop() {
        started = false
        scheduler?.stop(); scheduler = nil
        watcher?.stop(); watcher = nil
        changeListener?.cancel(); changeListener = nil
        reloadTask?.cancel(); reloadTask = nil
        startupTask?.cancel(); startupTask = nil
        midnightTask?.cancel(); midnightTask = nil
        cancelImport()
        importer = nil
    }

    private func applySchedule() {
        scheduler?.stop(); scheduler = nil
        watcher?.stop(); watcher = nil
        let schedule = self.schedule
        if let minutes = schedule.minutes {
            let s = PeriodicScheduler(identifier: "com.seanmatheny.foolscap.highlights-import") { [weak self] in self?.importNow() }
            s.start(minutes: minutes)
            scheduler = s
        } else if schedule == .whenKindleSyncs,
                  let url = KindleAnnotations.databaseURL(dataDirectory: (extractor as? NativeKindleExtractor)?.dataDirectory ?? KindleLibrary.defaultDataDirectory) {
            let w = KindleWatcher(url: url) { [weak self] in self?.importNow(opensKindle: false) }
            w.start()
            watcher = w
        }
    }

    /// Picks are for the day: re-drawn at local midnight.
    private func scheduleMidnight() {
        midnightTask?.cancel()
        midnightTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                guard let next = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 5), matchingPolicy: .nextTime) else { return }
                try? await Task.sleep(for: .seconds(max(60, next.timeIntervalSince(now))))
                guard !Task.isCancelled, let self else { return }
                self.refreshPicks()
            }
        }
    }

    // MARK: Import

    public var opensKindle: Bool {
        defaults.object(forKey: HighlightsImportSchedule.opensKindleKey) == nil ? true : defaults.bool(forKey: HighlightsImportSchedule.opensKindleKey)
    }

    /// Import now. Kindle only fetches new highlights while it runs, so unless
    /// told otherwise this first opens it hidden, waits for its sync, and quits
    /// it again afterwards (never a Kindle the user had open).
    public func importNow(opensKindle: Bool = true) {
        guard importTask == nil, let importer else { return }
        let status = self.status
        status.isRunning = true
        status.lastError = nil
        let dataDirectory = (extractor as? NativeKindleExtractor)?.dataDirectory
        let launchesKindle = opensKindle && self.opensKindle && dataDirectory == KindleLibrary.defaultDataDirectory
            && KindleApp.isInstalled && KindleApp.running == nil
        importTask = Task { [weak self] in
            var launched: NSRunningApplication?
            defer { launched?.terminate() }
            do {
                if launchesKindle {
                    status.phase = "Opening Kindle to fetch new highlights…"
                    launched = try await KindleApp.launchHidden()
                    status.phase = "Waiting for Kindle to sync…"
                    _ = await KindleApp.waitForSync(of: KindleApp.syncFiles(dataDirectory: KindleLibrary.defaultDataDirectory), timeout: 45)
                    try Task.checkCancellation()
                }
                let report = try await importer.run { phase in
                    Task { @MainActor in status.phase = phase }
                }
                status.lastReport = report
                status.lastRun = Date()
                status.needsFullDiskAccess = false
            } catch is CancellationError {
            } catch let failure as ExtractionFailure {
                status.lastError = failure.message
                if case .accessDenied = failure { status.needsFullDiskAccess = true }
            } catch {
                status.lastError = error.localizedDescription
            }
            status.isRunning = false
            status.phase = nil
            self?.importTask = nil
        }
    }

    public func cancelImport() {
        importTask?.cancel()
        importTask = nil
        status.isRunning = false
        status.phase = nil
    }

    // MARK: Data

    /// Coalesce bursts of change notifications.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    public func reload() async {
        let index = library.index
        let (items, books) = await Task.detached(priority: .userInitiated) {
            ((try? index.highlights()) ?? [], (try? index.highlightBooks()) ?? [])
        }.value
        self.items = items
        var seen = Set<String>()
        self.books = books.filter { seen.insert($0.path).inserted }
        let folder = library.folder
        let paths = self.books.map(\.path)
        coverURLs = await Task.detached(priority: .userInitiated) {
            var found: [String: URL] = [:]
            for path in paths {
                let url = folder.url(forRelativePath: HighlightsImporter.coverPath(for: path))
                if FileManager.default.fileExists(atPath: url.path) { found[path] = url }
            }
            return found
        }.value
        CoverCache.shared.warm(Array(coverURLs.values), maxPixels: CoverThumbnail.shelfPixels)
        refreshPicks()
    }

    private func refreshPicks() {
        let day = DailyPicks.dayKey(Date())
        var h = history
        let picks = DailyPicks.picks(items, day: day, history: &h)
        if h != history {
            h.prune()
            history = h
            try? h.save(to: dailyURL)
        }
        if picks != self.picks { self.picks = picks }
    }

    public var knownTags: [String] { library.knownTags }

    public func highlights(inBook path: String) -> [HighlightItem] { items.filter { $0.path == path } }

    public func book(at path: String) -> SearchIndex.HighlightBookRecord? { books.first { $0.path == path } }

    /// The cover beside the book file, when there is one.
    public func coverURL(for path: String) -> URL? { coverURLs[path] }

    /// The tags in use across highlights, most used first.
    public var highlightTags: [String] {
        var counts: [String: Int] = [:]
        for item in items { for tag in item.tags { counts[tag, default: 0] += 1 } }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    public var searchQuery: SearchQuery { SearchQuery(searchText) }

    /// Highlights matching the search field, across every book.
    public var searchResults: [HighlightItem] {
        let query = searchQuery
        guard !query.isEmpty else { return [] }
        return items.filter { Self.matches($0, query) }
    }

    static func matches(_ item: HighlightItem, _ query: SearchQuery) -> Bool {
        let words = query.words.map { $0.lowercased() }
        if !words.isEmpty {
            let hay = (item.text + "\n" + (item.note ?? "") + "\n" + item.bookTitle + "\n" + item.bookAuthor).lowercased()
            guard words.allSatisfy({ hay.contains($0) }) else { return false }
        }
        guard query.tags.allSatisfy({ item.tags.contains($0) }) else { return false }
        if let partial = query.pendingTag, !partial.isEmpty { return item.tags.contains { $0.hasPrefix(partial) } }
        return true
    }

    // MARK: Navigation

    public func open(book path: String, highlight id: String? = nil) {
        mode = .book(path)
        selectedTag = nil
        pendingHighlightID = id
    }

    public func showBooks() { mode = .books; selectedTag = nil }
    public func showToday() { mode = .today }

    // MARK: Edits (through the file, like tasks)

    public func toggleFavourite(_ item: HighlightItem) { edit(item) { $0.isFavourite.toggle() } }

    public func setHidden(_ item: HighlightItem, _ hidden: Bool) { edit(item) { $0.isHidden = hidden } }

    public func addTag(_ tag: String, to item: HighlightItem) {
        let clean = tag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard !clean.isEmpty else { return }
        edit(item) { if !$0.tags.contains(clean) { $0.tags.append(clean) } }
    }

    public func removeTag(_ tag: String, from item: HighlightItem) { edit(item) { $0.tags.removeAll { $0 == tag } } }

    /// Apply a change to the highlight's meta: the lists now (from the latest
    /// copy, since the caller's may predate an edit still being written), the
    /// file next, one write after another so each builds on the last.
    private func edit(_ item: HighlightItem, _ change: @escaping @Sendable (inout HighlightMeta) -> Void) {
        let current = items.first { $0.id == item.id } ?? item
        var meta = current.meta
        change(&meta)
        guard meta != current.meta else { return }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].meta = meta }
        if let i = picks.firstIndex(where: { $0.id == item.id }) {
            if meta.isHidden { picks.remove(at: i) } else { picks[i].meta = meta }
        }
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let doc = await library.loadedDocument(atRelativePath: current.path)
            do {
                try doc.replaceHighlightMeta(line: current.line, expectedKey: current.contentKey, change: change)
                await library.save()
            } catch {
                status.lastError = "Could not edit the highlight: \(error)"
                await reload()
            }
        }
    }

    // MARK: NotebookSection

    public func makeRootView() -> AnyView { AnyView(HighlightsPage(section: self)) }

    /// The day's three, for the flyleaf shown when the app opens.
    public func makeFlyleafView() -> AnyView { AnyView(FlyleafView(section: self)) }

    public var searchProvider: (any SearchProvider)? { provider }

    public func makeSettingsPane() -> AnyView? { AnyView(HighlightsSettingsPane(section: self)) }

    /// A search hit: the book file and the highlight's first line.
    public func navigate(to route: SectionRoute) {
        searchText = ""
        open(book: route.path, highlight: route.line.map { HighlightItem.id(path: route.path, line: $0) })
    }
}

/// Watches the Kindle app's annotation database, so a sync on the Kindle
/// side triggers an import without any polling.
@MainActor
final class KindleWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var debounce: Task<Void, Never>?
    private var reopen: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { scheduleReopen(); return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let events = s.data
            if events.contains(.delete) || events.contains(.rename) {
                self.stop()
                self.scheduleReopen()
            }
            self.changed()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    func stop() {
        source?.cancel()
        source = nil
        debounce?.cancel(); debounce = nil
        reopen?.cancel(); reopen = nil
    }

    /// The Kindle app writes in bursts while it syncs: wait for quiet.
    private func changed() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }

    private func scheduleReopen() {
        reopen?.cancel()
        reopen = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }
}
