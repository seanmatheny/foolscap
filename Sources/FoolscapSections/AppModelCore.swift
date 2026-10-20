import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// Wires the store, the section registry and the user's preferences together:
/// the part of the app model the Mac and the iPhone share. The Mac's `AppModel`
/// adds the optional sections (Scribe, Highlights, Jira, Secrets), backups, the
/// launch flags and the panels; the phone's model adds the Files-picker folder.
@MainActor
@Observable
open class AppModelCore {
    public var sections: [any NotebookSection] = []
    public var selectedSectionID: String {
        didSet {
            UserDefaults.standard.set(selectedSectionID, forKey: "selectedSection")
            sectionSelectionChanged(from: oldValue)
        }
    }
    public var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "themeID") }
    }
    /// Text size multiplier (View ▸ Bigger/Smaller Text, or the Settings slider).
    public var textScale: Double {
        didSet { UserDefaults.standard.set(textScale, forKey: "textScale") }
    }
    /// Paper and cover options from Settings, independent of the theme.
    public private(set) var ruling: Ruling = .blank
    public private(set) var marginRule = false
    public private(set) var elasticBand = false
    public private(set) var tabEdge: TabEdge = .left
    public private(set) var paperTexture: PaperTexture = .none
    /// The highlighter pens from Settings ▸ Tasks, and whether the lanes sort by them.
    public private(set) var pens = TaskPens()
    /// Font families chosen in Settings over the theme's own ("" keeps the theme's).
    public private(set) var bodyFont = ""
    public private(set) var headingFont = ""
    public private(set) var monoFont = ""
    public private(set) var library: NotebookLibrary?
    public var startupError: String?
    public let search = SearchCoordinator()
    public private(set) var tasksSection: TasksSection?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    /// How this device takes part in the appearance sync: the Mac writes the
    /// appearance file, the phone reads it while "Follow the Mac's appearance" is on.
    public var appearanceRole: AppearanceRole = .independent {
        didSet { if appearanceRole != oldValue { syncAppearance() } }
    }
    /// Whether this device's appearance came from the file (so Settings can say so).
    public private(set) var followedAppearance: AppearanceSettings?

    public var theme: NotebookTheme {
        (NotebookTheme.builtIn(id: themeID) ?? .classicBlack).withType(body: bodyFont, heading: headingFont, mono: monoFont)
            .scaled(by: textScale).onPaper(paperTexture).ruled(ruling, marginRule: marginRule)
    }
    public var tabs: [NotebookTabItem] { sections.map { NotebookTabItem(id: $0.id, appearance: $0.tab) } }
    public var notesFolderPath: String { library?.folder.root.path ?? "" }

    /// Opens the notebook at `root` with the Daily Notes and Tasks sections wired
    /// up; a subclass adds its own sections and then calls `rewireSections()`.
    public init(notesFolder root: URL) {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: "themeID") ?? NotebookTheme.classicBlack.id
        textScale = defaults.object(forKey: "textScale") as? Double ?? 1.0
        selectedSectionID = defaults.string(forKey: "selectedSection") ?? "daily"
        readAppearancePreferences()
        do {
            library = try NotebookLibrary(folder: NotesFolder(root: root))
        } catch {
            startupError = "Could not open notebook folder \(root.path): \(error.localizedDescription)"
        }
        if let library {
            let daily = DailyNotesSection(library: library)
            let tasks = TasksSection(library: library) { [weak self] route in
                guard let self else { return }
                self.selectedSectionID = "daily"
                daily.navigate(to: route)
            }
            daily.taskAggregator = tasks.aggregator
            daily.openSearch = { [weak self] in self?.search.open() }
            daily.openRoute = { [weak self] sectionID, route in
                // A route to a tab that is switched off (Jira, say) goes nowhere.
                guard let self, let target = self.section(id: sectionID) else { return }
                self.selectedSectionID = sectionID
                target.navigate(to: route)
            }
            sections = [daily, tasks]
            tasksSection = tasks
            search.navigate = { [weak self] sectionID, route in
                guard let self else { return }
                self.selectedSectionID = sectionID
                self.section(id: sectionID)?.navigate(to: route)
            }
            rewireSections()
            // Today's page once listed tasks tagged #today; now it lists the Today status.
            if !defaults.bool(forKey: "todayTagMigrated") {
                Task { await library.migrateTodayTagToStatus(); defaults.set(true, forKey: "todayTagMigrated") }
            }
        }
        if section(id: selectedSectionID) == nil { selectedSectionID = sections.first?.id ?? "" }
        // Settings changes the scale, the paper options and the section toggles through
        // @AppStorage (and a restore rewrites them all); mirror them here.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
    }

    /// The defaults changed (Settings, a restore): the shared ones are mirrored
    /// here; a subclass adds its section toggles and calls this.
    open func defaultsChanged() {
        let defaults = UserDefaults.standard
        let v = defaults.object(forKey: "textScale") as? Double ?? 1.0
        if v != textScale { textScale = v }
        if let id = defaults.string(forKey: "themeID"), id != themeID, NotebookTheme.builtIn(id: id) != nil { themeID = id }
        readAppearancePreferences()
        syncAppearance()
    }

    /// As the source, write the appearance file when the look changed.
    public func syncAppearance() {
        guard appearanceRole == .source, let library else { return }
        let settings = AppearanceSettings()
        Task { await library.writeAppearance(settings) }
    }

    /// As a follower, take the look from the file (when there is one). `fontAvailable`
    /// says which families this device has; others fall back to the theme's face.
    public func applyFollowedAppearance(fontAvailable: @escaping (String) -> Bool) async {
        guard appearanceRole == .follower, let library, let settings = await library.readAppearance() else { return }
        followedAppearance = settings
        if settings.apply(to: .standard, fontAvailable: fontAvailable) { defaultsChanged() }
    }

    /// The open tab changed (also called when it was set to the same tab again).
    open func sectionSelectionChanged(from old: String) {}

    public func readAppearancePreferences() {
        let defaults = UserDefaults.standard
        let r = Ruling(rawValue: defaults.string(forKey: PreferenceKeys.ruling) ?? "") ?? .blank
        if r != ruling { ruling = r }
        let m = defaults.bool(forKey: PreferenceKeys.marginRule)
        if m != marginRule { marginRule = m }
        let b = defaults.bool(forKey: PreferenceKeys.elasticBand)
        if b != elasticBand { elasticBand = b }
        let e = TabEdge(rawValue: defaults.string(forKey: PreferenceKeys.tabEdge) ?? "") ?? .left
        if e != tabEdge { tabEdge = e }
        let p = PaperTexture(rawValue: defaults.string(forKey: PreferenceKeys.paperTexture) ?? "") ?? .none
        if p != paperTexture { paperTexture = p }
        let pens = TaskPens.load(from: defaults)
        if pens != self.pens { self.pens = pens }
        let body = defaults.string(forKey: PreferenceKeys.bodyFont) ?? ""
        if body != bodyFont { bodyFont = body }
        let heading = defaults.string(forKey: PreferenceKeys.headingFont) ?? ""
        if heading != headingFont { headingFont = heading }
        let mono = defaults.string(forKey: PreferenceKeys.monoFont) ?? ""
        if mono != monoFont { monoFont = mono }
    }

    /// Where a tab sits whatever order the sections were switched on in: Daily Notes first,
    /// Tasks next, Jira after Tasks, Secrets last; everything else (Highlights, Scribe,
    /// plug-ins) in between in the order it was added.
    public static func tabRank(_ id: String) -> Int {
        switch id {
        case "daily": return 0
        case "tasks": return 1
        case TaskItem.jiraSectionID: return 2
        case "highlights": return 10
        case "scribe": return 11
        case "secrets": return 100
        default: return 50
        }
    }

    /// Order the tabs and hand every section's providers to the ones that gather them.
    public func rewireSections() {
        // `sort` is stable, so same-ranked sections keep their order.
        sections.sort { Self.tabRank($0.id) < Self.tabRank($1.id) }
        tasksSection?.aggregator.setProviders(sections.compactMap(\.taskProvider))
        (section(id: "daily") as? DailyNotesSection)?.dayPagesProviders = sections.compactMap(\.dayPagesProvider)
        search.setSections(sections)
    }

    /// One line for Settings: "⌘D Daily Notes · ⌘T Tasks · ⌘K Scribe".
    public var tabsSummary: String {
        sections.compactMap { s in s.tab.shortcut.map { "⌘\($0.uppercased()) \(s.tab.label)" } }.joined(separator: " · ")
    }

    public var sectionSettingsPanes: [SectionSettingsPane] {
        sections.compactMap { s in s.makeSettingsPane().map { SectionSettingsPane(id: s.id, title: s.tab.label, view: $0) } }
    }

    public func adjustTextScale(by delta: Double) {
        textScale = min(1.6, max(0.8, (textScale + delta).rounded(toPlaces: 2)))
    }

    public func section(id: String) -> (any NotebookSection)? { sections.first { $0.id == id } }

    public func changeNotesFolder(to url: URL) {
        do {
            if let library {
                try library.open(folder: NotesFolder(root: url))
            } else {
                library = try NotebookLibrary(folder: NotesFolder(root: url))
                startupError = nil
            }
            UserDefaults.standard.set(url.path, forKey: "notesFolder")
        } catch {
            startupError = "Could not open \(url.path): \(error.localizedDescription)"
        }
    }

    public var dailyNotes: DailyNotesSection? { section(id: "daily") as? DailyNotesSection }

    public func showDailyNotes() { selectedSectionID = "daily" }

    public func moveNotesFolder(to url: URL) {
        guard let library else { changeNotesFolder(to: url); return }
        Task {
            do {
                try await library.migrate(to: url)
                UserDefaults.standard.set(url.path, forKey: "notesFolder")
            } catch {
                startupError = "Could not move the notebook: \(error.localizedDescription)"
            }
        }
    }

    public func rebuildIndex() {
        Task { await library?.rebuildIndex() }
    }

    /// Synchronous, for quitting or going to the background: everything dirty is written now.
    open func flush() {
        library?.flushAll()
    }

    open func save() {
        guard let library else { return }
        Task { await library.save() }
    }
}

private extension Double {
    func rounded(toPlaces n: Int) -> Double { let p = pow(10.0, Double(n)); return (self * p).rounded() / p }
}

/// A device's part in the appearance sync.
public enum AppearanceRole: Sendable {
    /// Settings here are this device's own.
    case independent
    /// This device's Settings are written to the notebook folder for the others.
    case source
    /// This device takes its look from the file the source wrote.
    case follower
}
