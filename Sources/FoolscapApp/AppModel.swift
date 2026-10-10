import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI
import FoolscapSections
import FoolscapScribe
import FoolscapHighlights
import FoolscapJira
import FoolscapSecrets

/// Wires the store, the section registry and user preferences together.
@MainActor
@Observable
final class AppModel {
    var sections: [any NotebookSection] = []
    var selectedSectionID: String {
        didSet {
            UserDefaults.standard.set(selectedSectionID, forKey: "selectedSection")
            if oldValue == SecretsSection.sectionID, selectedSectionID != oldValue { secretsSection?.didLeaveTab() }
            if selectedSectionID == SecretsSection.sectionID, selectedSectionID != oldValue { secretsSection?.didEnterTab() }
            // Going somewhere (a tab, the Go menu, a search result) turns the flyleaf away.
            if flyleafPresented { flyleafPresented = false }
        }
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
    /// The Highlights tab is a hard toggle too: off means no section, no import, no index rows.
    private(set) var highlightsEnabled = false
    /// `--highlights` / `--flyleaf` keep the tab on for this launch whatever Settings says.
    private var highlightsForced = false
    private(set) var highlightsSection: HighlightsSection?
    /// The day's highlights lie on a loose page over the notebook until clicked away.
    var flyleafPresented = false {
        didSet {
            // Turning the flyleaf away onto a locked Secrets page counts as turning to the tab.
            if oldValue, !flyleafPresented, selectedSectionID == SecretsSection.sectionID { secretsSection?.didEnterTab() }
        }
    }
    /// The Jira tab is a hard toggle: off means no section, no requests.
    private(set) var jiraEnabled = false
    /// `--jira` keeps the tab on for this launch whatever Settings says.
    private var jiraForced = false
    private(set) var jiraSection: JiraSection?
    /// The Secrets tab is a hard toggle: off means no section, no vault read.
    private(set) var secretsEnabled = false
    /// `--secrets` keeps the tab on for this launch whatever Settings says.
    private var secretsForced = false
    private(set) var secretsSection: SecretsSection?

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
            daily.taskAggregator = tasks.aggregator
            daily.openSearch = { [weak self] in self?.search.open() }
            daily.openRoute = { [weak self] sectionID, route in
                guard let self else { return }
                self.selectedSectionID = sectionID
                self.section(id: sectionID)?.navigate(to: route)
            }
            sections = [daily, tasks]
            tasksSection = tasks
            search.navigate = { [weak self] sectionID, route in
                guard let self else { return }
                self.selectedSectionID = sectionID
                self.section(id: sectionID)?.navigate(to: route)
            }
            highlightsForced = CommandLine.arguments.contains { $0 == "--highlights" || $0.hasPrefix("--highlights=") || $0 == "--flyleaf" }
            setHighlightsEnabled(highlightsForced || defaults.bool(forKey: "highlightsEnabled"))
            scribeForced = CommandLine.arguments.contains { $0 == "--scribe" || $0.hasPrefix("--scribe=") }
            setScribeEnabled(scribeForced || defaults.bool(forKey: "scribeEnabled"))
            jiraForced = CommandLine.arguments.contains("--jira")
            setJiraEnabled(jiraForced || defaults.bool(forKey: "jiraEnabled"))
            secretsForced = CommandLine.arguments.contains("--secrets")
            setSecretsEnabled(secretsForced || defaults.bool(forKey: SecretsSection.enabledKey))
            rewireSections()
            // Today's page once listed tasks tagged #today; now it lists the Today status.
            if !defaults.bool(forKey: "todayTagMigrated") {
                Task { await library.migrateTodayTagToStatus(); defaults.set(true, forKey: "todayTagMigrated") }
            }
        }
        if section(id: selectedSectionID) == nil { selectedSectionID = sections.first?.id ?? "" }
        if jiraForced { selectedSectionID = JiraSection.sectionID }
        if secretsForced { selectedSectionID = SecretsSection.sectionID }
        // `--highlights` opens the tab; `--highlights=books` on the shelf, `--highlights=Highlights/<Title>.md`
        // on a book, `--highlights=search:<words>` with that search typed in.
        if highlightsForced, let highlights = highlightsSection {
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--highlights") }) { selectedSectionID = HighlightsSection.sectionID }
            if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--highlights=") })?.dropFirst("--highlights=".count) {
                if value == "books" { highlights.showBooks() }
                else if value.hasPrefix("search:") { highlights.searchText = String(value.dropFirst("search:".count)) }
                else if !value.isEmpty { highlights.open(book: String(value)) }
            }
        }
        // `--scribe=<Folder>/<Notebook>` opens the Scribe tab on that notebook;
        // `--scribe-zoom=N` lifts its page N into the zoom view once it is shown.
        if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--scribe=") })?.dropFirst("--scribe=".count),
           !value.isEmpty, let scribe = section(id: ScribeSection.sectionID) {
            selectedSectionID = ScribeSection.sectionID
            scribe.navigate(to: SectionRoute(path: "\(NotesFolder.scribeDirectoryName)/\(value).md"))
        }
        if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--scribe-zoom=") })?.dropFirst("--scribe-zoom=".count),
           let page = Int(value), let scribe = section(id: ScribeSection.sectionID) as? ScribeSection {
            scribe.pendingZoomPage = page
        }
        flyleafPresented = highlightsEnabled && (CommandLine.arguments.contains("--flyleaf") || defaults.bool(forKey: "flyleafOnOpen"))
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
        if let tab = flagValue("--tab"), sections.contains(where: { $0.id == tab }) {
            selectedSectionID = tab
        }
        // Page turns to watch: the tab changes once the window is up, as from the Go menu;
        // `--turn-to=tasks,daily,tasks` turns on, 2.5 s apart.
        if let list = flagValue("--turn-to") {
            for (i, tab) in list.split(separator: ",").map(String.init).enumerated() where sections.contains(where: { $0.id == tab }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 * Double(i + 1)) { [weak self] in self?.selectedSectionID = tab }
            }
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
        // Opening on the Secrets tab asks for Touch ID once the cover has opened (the
        // property observer does not run for assignments inside init); under the flyleaf
        // it waits for the flyleaf to be turned away.
        if selectedSectionID == SecretsSection.sectionID, !flyleafPresented {
            secretsSection?.didEnterTab(after: .milliseconds(args.contains("--no-opening") ? 800 : 2200))
        }
        // `--window=WxH` sizes the main window (to see the tabs shrink to their icons).
        if let size = flagValue("--window")?.split(separator: "x"), size.count == 2,
           let w = Double(size[0]), let h = Double(size[1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return }
                var frame = window.frame
                frame.origin.y += frame.height - h
                frame.size = NSSize(width: w, height: h)
                window.setFrame(frame, display: true, animate: false)
            }
        }
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
        // Each character is a key-down event, 0.15 s apart, so the completion list
        // sees keys as it would from the keyboard.
        if let raw = flagValue("--type") {
            // Named keys: {up} {down} {left} {right} {tab} {esc} {paste} (⌘V); \n is Return.
            let named: [String: (String, UInt16)] = [
                "up": ("\u{F700}", 126), "down": ("\u{F701}", 125), "left": ("\u{F702}", 123), "right": ("\u{F703}", 124),
                "tab": ("\t", 48), "esc": ("\u{1B}", 53), "paste": ("v", 9)]
            var keys: [(chars: String, code: UInt16)] = []
            var rest = Substring(raw.replacingOccurrences(of: "\\n", with: "\n"))
            while let ch = rest.first {
                if ch == "{", let close = rest.firstIndex(of: "}"), let key = named[String(rest[rest.index(after: rest.startIndex)..<close])] {
                    keys.append(key); rest = rest[rest.index(after: close)...]; continue
                }
                keys.append(ch == "\n" ? ("\r", 36) : (String(ch), ch == " " ? 49 : 0))
                rest = rest.dropFirst()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                func editor(in view: NSView?) -> NSTextView? {
                    guard let view else { return nil }
                    if let text = view as? NSTextView, text.isEditable { return text }
                    return view.subviews.lazy.compactMap { editor(in: $0) }.first
                }
                guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }),
                      let textView = window.firstResponder as? NSTextView ?? editor(in: window.contentView) else { return }
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                // Posted to the event queue from a background thread (postEvent allows
                // that), so keys also reach the completion list's own event loop.
                let windowNumber = window.windowNumber
                Thread.detachNewThread {
                    for key in keys {
                        Thread.sleep(forTimeInterval: 0.15)
                        var flags: NSEvent.ModifierFlags = key.chars.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } == true
                            ? [.function, .numericPad] : []
                        if key.chars == "v" && key.code == 9 { flags = .command }
                        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                                           windowNumber: windowNumber, context: nil,
                                                           characters: key.chars, charactersIgnoringModifiers: key.chars,
                                                           isARepeat: false, keyCode: key.code) else { continue }
                        NSApp.postEvent(event, atStart: false)
                    }
                }
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
                let highlights = defaults.bool(forKey: "highlightsEnabled")
                if !self.highlightsForced, highlights != self.highlightsEnabled { self.setHighlightsEnabled(highlights) }
                let jira = defaults.bool(forKey: "jiraEnabled")
                if !self.jiraForced, jira != self.jiraEnabled { self.setJiraEnabled(jira) }
                let secrets = defaults.bool(forKey: SecretsSection.enabledKey)
                if !self.secretsForced, secrets != self.secretsEnabled { self.setSecretsEnabled(secrets) }
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
        if highlightsEnabled {
            setHighlightsEnabled(false)
            setHighlightsEnabled(true)
        }
        if jiraEnabled {
            setJiraEnabled(false)
            setJiraEnabled(true)
        }
        if secretsEnabled {
            setSecretsEnabled(false)
            setSecretsEnabled(true)
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

    /// Add or remove the Highlights section at runtime (`rewireSections` places it).
    func setHighlightsEnabled(_ on: Bool) {
        guard on != highlightsEnabled, let library else { return }
        highlightsEnabled = on
        if on {
            // `--kindle-data=<dir>` reads a copy of the Kindle app's container (for verification).
            let kindleData = CommandLine.arguments.first { $0.hasPrefix("--kindle-data=") }
                .map { URL(fileURLWithPath: String($0.dropFirst("--kindle-data=".count))) }
            let highlights = HighlightsSection(library: library,
                                               extractor: NativeKindleExtractor(dataDirectory: kindleData ?? KindleLibrary.defaultDataDirectory))
            sections.append(highlights)
            highlightsSection = highlights
            library.indexesHighlights = true
            highlights.start()
        } else {
            highlightsSection?.stop()
            highlightsSection = nil
            sections.removeAll { $0.id == HighlightsSection.sectionID }
            library.indexesHighlights = false
            flyleafPresented = false
            if selectedSectionID == HighlightsSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
    }

    /// Add or remove the Jira section at runtime (`rewireSections` places it after Tasks).
    /// Nothing is indexed: it writes only task lines, through the library.
    func setJiraEnabled(_ on: Bool) {
        guard on != jiraEnabled, let library else { return }
        jiraEnabled = on
        if on {
            let jira = JiraSection(library: library)
            sections.append(jira)
            jiraSection = jira
            jira.start()
        } else {
            jiraSection?.stop()
            jiraSection = nil
            sections.removeAll { $0.id == JiraSection.sectionID }
            if selectedSectionID == JiraSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
    }

    /// Add or remove the Secrets section at runtime (`rewireSections` puts it last).
    /// Nothing is indexed: the vault never enters the library.
    func setSecretsEnabled(_ on: Bool) {
        guard on != secretsEnabled, let library else { return }
        secretsEnabled = on
        if on {
            let secrets = SecretsSection(library: library)
            sections.append(secrets)
            secretsSection = secrets
            secrets.start()
        } else {
            secretsSection?.stop()
            secretsSection = nil
            sections.removeAll { $0.id == SecretsSection.sectionID }
            if selectedSectionID == SecretsSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
    }

    /// Where a tab sits whatever order the sections were switched on in: Daily Notes first,
    /// Tasks next, Jira after Tasks, Secrets last; everything else (Highlights, Scribe,
    /// plug-ins) in between in the order it was added.
    static func tabRank(_ id: String) -> Int {
        switch id {
        case "daily": return 0
        case "tasks": return 1
        case JiraSection.sectionID: return 2
        case HighlightsSection.sectionID: return 10
        case ScribeSection.sectionID: return 11
        case SecretsSection.sectionID: return 100
        default: return 50
        }
    }

    private func rewireSections() {
        // `sort` is stable, so same-ranked sections keep their order.
        sections.sort { Self.tabRank($0.id) < Self.tabRank($1.id) }
        tasksSection?.aggregator.setProviders(sections.compactMap(\.taskProvider))
        (section(id: "daily") as? DailyNotesSection)?.dayPagesProviders = sections.compactMap(\.dayPagesProvider)
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

    /// Synchronous, for quitting: the vault locks (and saves) first, and a sync or
    /// import under way is cancelled so its helper (scribe-vlm, Calibre, the hidden
    /// Kindle) does not outlive the app.
    func flush() {
        secretsSection?.lockNow()
        (section(id: ScribeSection.sectionID) as? ScribeSection)?.stop()
        highlightsSection?.stop()
        library?.flushAll()
    }

    func save() {
        secretsSection?.saveIfDirty()
        guard let library else { return }
        Task { await library.save() }
    }
}

private extension Double {
    func rounded(toPlaces n: Int) -> Double { let p = pow(10.0, Double(n)); return (self * p).rounded() / p }
}
