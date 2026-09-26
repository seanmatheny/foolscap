import SwiftUI
import Network
import FoolscapCore
import FoolscapStore

/// Sync progress and outcome, for the page and the settings pane.
@MainActor
@Observable
public final class ScribeSyncStatus {
    public var isRunning = false
    public var phase: String?
    public var lastRun: Date?
    public var lastReport: SyncReport?
    public var lastError: String?
    /// The last pass found no connection; the next one runs when it returns.
    public var isOffline = false
    /// Amazon wants a fresh sign-in before anything else can happen.
    public var needsSignIn = false
    public init() {}
}

/// The Kindle Scribe tab: notebooks fetched from Amazon as PDFs, recognised
/// into transcripts, their handwritten TODOs turned into `#scribe` tasks.
@MainActor
@Observable
public final class ScribeSection: NotebookSection {
    public static let sectionID = "scribe"
    public static let looseFolderID = ""
    public let id = ScribeSection.sectionID
    public let tab = TabAppearance(label: "Scribe", systemImage: "pencil.and.scribble", colorIndex: 3, shortcut: "k")

    let library: NotebookLibrary
    public let account = ScribeAccount()
    public let status = ScribeSyncStatus()
    public private(set) var state: ScribeState
    /// `state`'s tree, indexed whenever the state is replaced.
    public private(set) var tree: ScribeTree
    /// The top-level Kindle folder shown in the sub-tab row (`looseFolderID` for
    /// notebooks outside any folder).
    public var selectedFolderID: String?
    public var selectedNotebookID: String?
    /// A page to scroll to once the notebook is shown (from search).
    public var pendingPage: Int?

    @ObservationIgnored let renderer = ScribePageRenderer()
    /// A search hit's page, being worked out off the main actor.
    @ObservationIgnored var pageLookup: Task<Void, Never>?
    @ObservationIgnored private var engine: ScribeSyncEngine?
    @ObservationIgnored private var scheduler: PeriodicScheduler?
    /// Watches for the connection coming back after an offline pass.
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// Whether the running pass fetches every recently edited notebook.
    @ObservationIgnored private var runningRecheckAll = false
    /// Sync Now arrived during a paced pass: a full pass follows it.
    @ObservationIgnored private var recheckAllPending = false
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    /// Bumped by every pass and by stop and sign-out, so a pass that was
    /// cancelled or superseded leaves status and state alone when it returns.
    @ObservationIgnored private var passID = 0
    @ObservationIgnored private lazy var provider = ScribeSearchProvider(library: library)

    public static let defaultSyncMinutes = 30
    public static let defaultLanguages = ["en-US"]

    /// Folders the user has closed in the contents column, by Amazon id.
    public private(set) var collapsedFolderIDs: Set<String>
    static let collapsedFoldersKey = "scribeCollapsedFolders"

    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults

    public init(library: NotebookLibrary, stateURL: URL = ScribePaths.stateURL, cacheDirectory: URL = ScribePaths.ocrDirectory,
                defaults: UserDefaults = .standard) {
        self.library = library
        self.stateURL = stateURL
        self.cacheDirectory = cacheDirectory
        self.defaults = defaults
        let loaded = ScribeState.load(from: stateURL)
        state = loaded
        tree = ScribeTree(loaded)
        collapsedFolderIDs = Set(defaults.stringArray(forKey: Self.collapsedFoldersKey) ?? [])
        selectDefaultsIfNeeded()
    }

    // MARK: Settings

    public var syncMinutes: Int {
        let v = defaults.integer(forKey: "scribeSyncMinutes")
        return v > 0 ? v : Self.defaultSyncMinutes
    }

    public var languages: [String] {
        let raw = defaults.string(forKey: "scribeLanguages") ?? ""
        let list = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return list.isEmpty ? Self.defaultLanguages : list
    }

    /// Called by the settings pane after the interval changes.
    public func settingsChanged() {
        scheduler?.start(minutes: syncMinutes)
    }

    // MARK: Lifecycle

    /// Build the engine and start the schedule. A signed-in account syncs
    /// shortly after launch; otherwise the page asks for a sign-in.
    public func start() {
        guard engine == nil else { return }
        let helper = ProcessOCRRunner.locateHelper()
        let ocr: any OCRRunning = helper.map { ProcessOCRRunner(helperURL: $0) } ?? MissingOCRRunner()
        engine = ScribeSyncEngine(client: AmazonScribeClient(), ocr: ocr, cache: OCRCache(directory: cacheDirectory),
                                  stateURL: stateURL, sink: LibraryTaskSink(library: library))
        let scheduler = PeriodicScheduler(identifier: "com.seanmatheny.foolscap.scribe-sync") { [weak self] in await self?.runSync() }
        scheduler.start(minutes: syncMinutes)
        self.scheduler = scheduler
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.status.isOffline else { return }
                self.syncNow()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        account.refresh()
        if account.isSignedIn {
            startupTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.syncNow()
            }
        } else {
            status.needsSignIn = true
        }
    }

    public func stop() {
        scheduler?.stop()
        scheduler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        cancelSync()
        engine = nil
        Task { await renderer.releaseAll() }
    }

    public func signIn() {
        account.beginSignIn { [weak self] in
            self?.status.needsSignIn = false
            self?.syncNow()
        }
    }

    public func signOut() {
        cancelSync()
        account.signOut()
        status.needsSignIn = true
    }

    /// Sync Now, launch, sign-in and reconnect: the user has usually just synced
    /// the Kindle, so every recently edited notebook is fetched, not only those
    /// the pacing is due to recheck.
    public func syncNow() { startSync(recheckAll: true) }

    /// One paced pass from the schedule, awaited (it needs to know when it finished).
    func runSync() async { await startSync(recheckAll: false).value }

    /// Every pass, from launch, the schedule or Sync Now, runs as `syncTask`, so
    /// stopping or signing out can cancel it; asking while one runs joins it, and
    /// Sync Now during a paced pass queues a full pass after it.
    @discardableResult
    private func startSync(recheckAll: Bool) -> Task<Void, Never> {
        if let syncTask {
            if recheckAll && !runningRecheckAll { recheckAllPending = true }
            return syncTask
        }
        passID += 1
        let pass = passID
        runningRecheckAll = recheckAll
        let task = Task { [weak self] in
            await self?.performSync(pass: pass, recheckAll: recheckAll)
            guard let self, self.passID == pass else { return }
            self.syncTask = nil
            if self.recheckAllPending {
                self.recheckAllPending = false
                self.startSync(recheckAll: true)
            }
        }
        syncTask = task
        return task
    }

    /// Cancel the pending and running passes. A cancelled pass may take a moment
    /// to unwind; `passID` keeps it from reporting anything when it does.
    private func cancelSync() {
        startupTask?.cancel()
        startupTask = nil
        syncTask?.cancel()
        syncTask = nil
        recheckAllPending = false
        passID += 1
        status.isRunning = false
        status.phase = nil
    }

    private func performSync(pass: Int, recheckAll: Bool) async {
        guard let engine else { return }
        guard account.isSignedIn else { status.needsSignIn = true; return }
        status.isRunning = true
        status.lastError = nil
        defer {
            if passID == pass { status.isRunning = false; status.phase = nil }
        }
        // Progress hops to the main actor and can land after the pass has ended;
        // only a pass still running shows it.
        let progress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in
                guard let self, self.passID == pass, self.status.isRunning else { return }
                self.status.phase = message
            }
        }
        do {
            let report = try await engine.syncOnce(notesRoot: library.folder.root, languages: languages,
                                                   recheckAll: recheckAll, progress: progress)
            let newState = await engine.state
            guard passID == pass else { return }
            apply(newState)
            status.lastRun = Date()
            status.lastReport = report
            status.needsSignIn = false
            status.isOffline = false
            if !report.errors.isEmpty { status.lastError = report.errors.joined(separator: "\n") }
            if report.changedFiles { await library.rescan() }
            selectDefaultsIfNeeded()
        } catch ScribeClientError.signedOut {
            guard passID == pass else { return }
            account.markSignedOut()
            status.needsSignIn = true
            status.isOffline = false
            status.lastError = "Amazon asked for a fresh sign-in."
        } catch is CancellationError {
            // Stopped: nothing to report.
        } catch where ScribeClientError.isOffline(error) {
            guard passID == pass else { return }
            status.isOffline = true
        } catch {
            guard passID == pass else { return }
            status.isOffline = false
            status.lastError = "\(error)"
        }
    }

    private func apply(_ newState: ScribeState) {
        if newState.items != state.items { tree = ScribeTree(newState) }
        state = newState
    }

    // MARK: Selection

    /// The sub-tab row: every top-level folder, plus "Notebooks" for loose ones.
    public var folderTabs: [(id: String, name: String)] {
        let roots = tree.children(of: nil)
        var tabs = roots.filter(\.isFolder).map { (id: $0.id, name: $0.name) }
        if roots.contains(where: { !$0.isFolder }) { tabs.append((id: Self.looseFolderID, name: "Notebooks")) }
        return tabs
    }

    /// One line of the contents column: a folder with its disclosure state, or a notebook.
    public struct ContentsRow: Identifiable, Equatable, Sendable {
        public var item: ScribeItem
        public var depth: Int
        public var isExpanded: Bool
        public var notebookCount: Int
        public var id: String { item.id }
    }

    /// The contents column as an outline: inside each folder its notebooks come
    /// first, then its subfolders, each expanded unless collapsed. The "Notebooks"
    /// sub-tab lists only the loose notebooks.
    public var contentsRows: [ContentsRow] { rows(respectingCollapse: true) }

    /// Notebooks the column currently shows, in order.
    public var visibleNotebooks: [ScribeItem] { contentsRows.map(\.item).filter { !$0.isFolder } }

    /// Every notebook under the selected sub-tab, collapsed or not, in outline order.
    var treeNotebooks: [ScribeItem] { rows(respectingCollapse: false).map(\.item).filter { !$0.isFolder } }

    private func rows(respectingCollapse: Bool) -> [ContentsRow] {
        guard let folderID = selectedFolderID else { return [] }
        var rows: [ContentsRow] = []
        func walk(_ parent: String?, depth: Int, includeFolders: Bool) {
            let children = tree.children(of: parent)
            for notebook in children where !notebook.isFolder {
                rows.append(ContentsRow(item: notebook, depth: depth, isExpanded: false, notebookCount: 0))
            }
            guard includeFolders else { return }
            for folder in children where folder.isFolder {
                let expanded = !respectingCollapse || !collapsedFolderIDs.contains(folder.id)
                rows.append(ContentsRow(item: folder, depth: depth, isExpanded: expanded,
                                        notebookCount: tree.notebookCounts[folder.id] ?? 0))
                if expanded { walk(folder.id, depth: depth + 1, includeFolders: true) }
            }
        }
        if folderID == Self.looseFolderID {
            walk(nil, depth: 0, includeFolders: false)
        } else {
            walk(folderID, depth: 0, includeFolders: true)
        }
        return rows
    }

    public var selectedNotebook: ScribeItem? { selectedNotebookID.flatMap { state.items[$0] } }

    public func toggle(folder id: String) {
        if collapsedFolderIDs.contains(id) { collapsedFolderIDs.remove(id) } else { collapsedFolderIDs.insert(id) }
        saveCollapsedFolders()
    }

    /// Expand every folder above a notebook so its row is on screen.
    public func reveal(notebook id: String) {
        guard var current = state.items[id] else { return }
        var changed = false
        while let parentID = current.parentID, let parent = state.items[parentID] {
            if collapsedFolderIDs.remove(parentID) != nil { changed = true }
            current = parent
        }
        if changed { saveCollapsedFolders() }
    }

    private func saveCollapsedFolders() {
        defaults.set(Array(collapsedFolderIDs).sorted(), forKey: Self.collapsedFoldersKey)
    }

    public func select(folder id: String) {
        guard id != selectedFolderID else { return }
        selectedFolderID = id
        selectedNotebookID = nil
        pendingPage = nil
        selectDefaultsIfNeeded()
    }

    public func select(notebook id: String) {
        selectedNotebookID = id
        pendingPage = nil
    }

    /// Keep a valid sub-tab and notebook selected: the first visible notebook,
    /// or the first in the tree with its folders opened.
    func selectDefaultsIfNeeded() {
        let tabs = folderTabs
        if selectedFolderID == nil || !tabs.contains(where: { $0.id == selectedFolderID }) {
            selectedFolderID = tabs.first?.id
        }
        let all = treeNotebooks
        if let selected = selectedNotebookID, all.contains(where: { $0.id == selected }) { return }
        if let first = visibleNotebooks.first {
            selectedNotebookID = first.id
        } else if let first = all.first {
            selectedNotebookID = first.id
            reveal(notebook: first.id)
        } else {
            selectedNotebookID = nil
        }
    }

    /// The top-level folder holding an item (nil when loose).
    func topFolder(of item: ScribeItem) -> String {
        var current = item
        while let parent = current.parentID, let p = state.items[parent] { current = p }
        return current.isFolder ? current.id : Self.looseFolderID
    }

    // MARK: NotebookSection

    public func makeRootView() -> AnyView { AnyView(ScribePage(section: self)) }

    public var searchProvider: (any SearchProvider)? { provider }

    public func makeSettingsPane() -> AnyView? { AnyView(ScribeSettingsPane(section: self)) }

    /// A search hit: `Scribe/<path>.md` and a line, mapped to notebook and page.
    public func navigate(to route: SectionRoute) {
        guard let item = state.item(atTranscriptPath: route.path) else { return }
        selectedFolderID = topFolder(of: item)
        selectedNotebookID = item.id
        reveal(notebook: item.id)
        pendingPage = nil
        guard let line = route.line else { return }
        // Coordinated read off the main actor: iCloud can hold it for seconds.
        let url = library.folder.url(forRelativePath: route.path)
        pageLookup = Task { [weak self] in
            let page = await Task.detached(priority: .userInitiated) {
                (try? FileIO.read(url)).flatMap {
                    ScribeTranscript.pageNumber(forLine: line, in: ScribeTranscript.parse(String(decoding: $0, as: UTF8.self)))
                }
            }.value
            guard let self, self.selectedNotebookID == item.id else { return }
            self.pendingPage = page
        }
    }

    // MARK: Files

    public func pdfURL(for item: ScribeItem) -> URL { library.folder.url(forRelativePath: item.pdfRelativePath) }
    public func transcriptURL(for item: ScribeItem) -> URL { library.folder.url(forRelativePath: item.transcriptRelativePath) }
}

/// Stands in when the bundled helper cannot be found (a development build
/// that has not run `make app-debug`).
struct MissingOCRRunner: OCRRunning {
    func recognise(pdf: URL, languages: [String]) async throws -> OCRResult { throw OCRError.helperMissing }
}
