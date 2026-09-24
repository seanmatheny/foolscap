import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI
import FoolscapSections
import FoolscapScribe

/// Wires the store, the section registry and user preferences together.
@MainActor
@Observable
final class AppModel {
    var sections: [any NotebookSection] = []
    var selectedSectionID: String {
        didSet { UserDefaults.standard.set(selectedSectionID, forKey: "selectedSection") }
    }
    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "themeID") }
    }
    /// Text size multiplier (View ▸ Bigger/Smaller Text, or the Settings slider).
    var textScale: Double {
        didSet { UserDefaults.standard.set(textScale, forKey: "textScale") }
    }
    /// Paper and cover options from Settings, independent of the theme.
    private(set) var ruling: Ruling = .blank
    private(set) var marginRule = false
    private(set) var elasticBand = false
    private(set) var tabEdge: TabEdge = .left
    private(set) var paperTexture: PaperTexture = .none
    private(set) var library: NotebookLibrary?
    private(set) var backup: BackupManager?
    private(set) var startupError: String?
    let search = SearchCoordinator()
    var showExport = false
    /// The Scribe tab is a hard toggle: off means no section object, no sync, no index rows.
    private(set) var scribeEnabled = false
    /// `--scribe` keeps the tab on for this launch whatever Settings says.
    private var scribeForced = false
    private var tasksSection: TasksSection?

    var theme: NotebookTheme {
        (NotebookTheme.builtIn(id: themeID) ?? .classicBlack).scaled(by: textScale).onPaper(paperTexture).ruled(ruling, marginRule: marginRule)
    }
    var tabs: [NotebookTabItem] { sections.map { NotebookTabItem(id: $0.id, appearance: $0.tab) } }
    var notesFolderPath: String { library?.folder.root.path ?? "" }

    init() {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: "themeID") ?? NotebookTheme.classicBlack.id
        textScale = defaults.object(forKey: "textScale") as? Double ?? 1.0
        selectedSectionID = defaults.string(forKey: "selectedSection") ?? "daily"
        readAppearancePreferences()
        let root = defaults.string(forKey: "notesFolder").map { URL(fileURLWithPath: $0) } ?? NotesFolder.defaultRoot
        do {
            library = try NotebookLibrary(folder: NotesFolder(root: root))
        } catch {
            startupError = "Could not open notebook folder \(root.path): \(error.localizedDescription)"
        }
        if let library {
            let backup = BackupManager(library: library)
            backup.onRestored = { [weak self] in self?.reloadAfterRestore() }
            backup.startSchedule()
            self.backup = backup
            let daily = DailyNotesSection(library: library)
            let tasks = TasksSection(library: library) { [weak self] route in
                guard let self else { return }
                self.selectedSectionID = "daily"
                daily.navigate(to: route)
            }
            sections = [daily, tasks]
            tasksSection = tasks
            search.navigate = { [weak self] sectionID, route in
                guard let self else { return }
                self.selectedSectionID = sectionID
                self.section(id: sectionID)?.navigate(to: route)
            }
            scribeForced = CommandLine.arguments.contains("--scribe")
            setScribeEnabled(scribeForced || defaults.bool(forKey: "scribeEnabled"))
            rewireSections()
        }
        if section(id: selectedSectionID) == nil { selectedSectionID = sections.first?.id ?? "" }
        // `Foolscap --day=2026-09-22` opens on a given day (handy for scripted screenshots).
        // Values ride inside the flag: with `open … --args`, a bare value argument makes
        // AppKit treat the launch as "open these files" and the main window never appears.
        let args = CommandLine.arguments
        func flagValue(_ flag: String) -> String? {
            if let joined = args.first(where: { $0.hasPrefix(flag + "=") }) { return String(joined.dropFirst(flag.count + 1)) }
            if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
            return nil
        }
        if let day = flagValue("--day").flatMap(DayKey.init) {
            dailyNotes?.selectedDay = day
            selectedSectionID = "daily"
        }
        if let query = flagValue("--search") {
            search.open(with: query)
        }
        if args.contains("--export") { showExport = true }
        // `--prefs-bottom` scrolls the Settings form to its end once open, and
        // `--prefs-scroll=<points>` to that offset (for screenshots).
        let prefsScroll = args.first { $0.hasPrefix("--prefs-scroll=") }.flatMap { Double($0.dropFirst("--prefs-scroll=".count)) }
        if args.contains("--prefs-bottom") || prefsScroll != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                @MainActor func scrollView(in view: NSView?) -> NSScrollView? {
                    guard let view else { return nil }
                    if let s = view as? NSScrollView { return s }
                    for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
                    return nil
                }
                guard let window = NSApp.windows.first(where: { $0.title.hasSuffix("Settings") }),
                      let scroll = scrollView(in: window.contentView), let doc = scroll.documentView else { return }
                let bottom = max(0, doc.frame.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: prefsScroll.map { min(bottom, $0) } ?? bottom))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        registerHotKeys()
        if args.contains("--fullscreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.windows.first { $0.isVisible }?.toggleFullScreen(nil) }
        }
        if args.contains("--find") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { FindCommands.perform(.showFindInterface) }
        }
        if args.contains("--quick-task") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.quickTask() }
        }
        // `--backup=<file.zip>` and `--restore=<file.zip>` run a backup or a restore
        // (no confirmation) once the window is up, for scripts and for verification.
        if let backup, let path = flagValue("--backup") {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { try? await backup.backUp(to: url) } }
        }
        if let backup, let path = flagValue("--restore") {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { try? await backup.restore(from: url) } }
        }
        // `--type=text` types into the focused editor after launch, so typing-driven
        // behaviour (tag completion) can be screenshotted without an Accessibility grant.
        if let raw = flagValue("--type") {
            let text = raw.replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                for ch in text { textView.insertText(String(ch), replacementRange: textView.selectedRange()) }
            }
        }
        NotificationCenter.default.addObserver(forName: HotKeyPreferences.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys() }
        }
        // Settings changes the scale, the paper options and the Scribe toggle through
        // @AppStorage (and a restore rewrites them all); mirror them here.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let defaults = UserDefaults.standard
                let v = defaults.object(forKey: "textScale") as? Double ?? 1.0
                if v != self.textScale { self.textScale = v }
                if let id = defaults.string(forKey: "themeID"), id != self.themeID, NotebookTheme.builtIn(id: id) != nil { self.themeID = id }
                self.readAppearancePreferences()
                let scribe = defaults.bool(forKey: "scribeEnabled")
                if !self.scribeForced, scribe != self.scribeEnabled { self.setScribeEnabled(scribe) }
            }
        }
    }

    private func readAppearancePreferences() {
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
    }

    /// A restore replaced the files, the index and the settings underneath the
    /// sections: the Scribe section re-reads its state, the Tasks tab reloads.
    private func reloadAfterRestore() {
        if scribeEnabled {
            setScribeEnabled(false)
            setScribeEnabled(true)
        }
        tasksSection?.aggregator.scheduleReload()
        if section(id: selectedSectionID) == nil { selectedSectionID = sections.first?.id ?? "" }
    }

    /// Add or remove the Scribe section at runtime, and everything derived from `sections`.
    func setScribeEnabled(_ on: Bool) {
        guard on != scribeEnabled, let library else { return }
        scribeEnabled = on
        if on {
            let scribe = ScribeSection(library: library)
            sections.append(scribe)
            library.indexesScribe = true
            scribe.start()
        } else {
            (section(id: ScribeSection.sectionID) as? ScribeSection)?.stop()
            sections.removeAll { $0.id == ScribeSection.sectionID }
            library.indexesScribe = false
            if selectedSectionID == ScribeSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
    }

    private func rewireSections() {
        tasksSection?.aggregator.setProviders(sections.compactMap(\.taskProvider))
        search.setSections(sections)
    }

    /// One line for Settings: "⌘D Daily Notes · ⌘T Tasks · ⌘K Scribe".
    var tabsSummary: String {
        sections.compactMap { s in s.tab.shortcut.map { "⌘\($0.uppercased()) \(s.tab.label)" } }.joined(separator: " · ")
    }

    var sectionSettingsPanes: [SectionSettingsPane] {
        sections.compactMap { s in s.makeSettingsPane().map { SectionSettingsPane(id: s.id, title: s.tab.label, view: $0) } }
    }

    func registerHotKeys() {
        GlobalHotKey.shared.register(name: HotKeyPreferences.quickTaskName, combo: HotKeyPreferences.quickTask) { [weak self] in
            guard let self, let library = self.library else { return }
            QuickTaskPanel.shared.toggle(library: library, theme: self.theme)
        }
    }

    func adjustTextScale(by delta: Double) {
        textScale = min(1.6, max(0.8, (textScale + delta).rounded(toPlaces: 2)))
    }

    func quickTask() {
        guard let library else { return }
        QuickTaskPanel.shared.toggle(library: library, theme: theme)
    }

    func section(id: String) -> (any NotebookSection)? { sections.first { $0.id == id } }

    func changeNotesFolder(to url: URL) {
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

    var dailyNotes: DailyNotesSection? { section(id: "daily") as? DailyNotesSection }

    func showDailyNotes() { selectedSectionID = "daily" }

    func moveNotesFolder(to url: URL) {
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

    func rebuildIndex() {
        Task { await library?.rebuildIndex() }
    }

    /// Synchronous, for quitting.
    func flush() { library?.flushAll() }

    func save() {
        guard let library else { return }
        Task { await library.save() }
    }
}

/// Phase 0 stand-in until the real sections exist.
@MainActor
final class PlaceholderSection: NotebookSection {
    let id: String
    let tab: TabAppearance
    init(id: String, label: String, symbol: String) {
        self.id = id
        self.tab = TabAppearance(label: label, systemImage: symbol)
    }
    func makeRootView() -> AnyView {
        AnyView(PlaceholderPage(label: tab.label))
    }
}

private struct PlaceholderPage: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(AppModel.self) private var model
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 26, weight: .bold, design: .serif))
            Text("Coming in the next phase.").font(.system(size: 15, design: .serif)).opacity(0.6)
            if let lib = model.library {
                Text("\(lib.days.count) daily notes in \(lib.folder.root.path) · index v\(lib.indexVersion)")
                    .font(.system(size: 12, design: .monospaced)).opacity(0.5)
            }
            if let err = model.startupError ?? model.library?.lastError {
                Text(err).foregroundStyle(.red)
            }
            Spacer()
        }
        .foregroundStyle(theme.ink.color)
        .padding(EdgeInsets(top: 34, leading: 64, bottom: 24, trailing: 40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension Double {
    func rounded(toPlaces n: Int) -> Double { let p = pow(10.0, Double(n)); return (self * p).rounded() / p }
}
