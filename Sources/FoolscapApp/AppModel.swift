import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI
import FoolscapSections
import FoolscapScribe
import FoolscapHighlights
import FoolscapJira
import FoolscapSecrets

/// The Mac's app model: the shared wiring (`AppModelCore`) plus the optional
/// sections, backups, the launch flags and the panels.
@MainActor
@Observable
final class AppModel: AppModelCore {
    private(set) var backup: BackupManager?
    var showExport = false
    /// The Scribe tab is a hard toggle: off means no section object, no sync, no index rows.
    private(set) var scribeEnabled = false
    /// `--scribe` keeps the tab on for this launch whatever Settings says.
    private var scribeForced = false
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

    init() {
        let defaults = UserDefaults.standard
        let root = defaults.string(forKey: "notesFolder").map { URL(fileURLWithPath: $0) } ?? NotesFolder.defaultRoot
        super.init(notesFolder: root)
        if let library {
            let backup = BackupManager(library: library)
            backup.onRestored = { [weak self] in self?.reloadAfterRestore() }
            backup.startSchedule()
            self.backup = backup
            highlightsForced = CommandLine.arguments.contains { $0 == "--highlights" || $0.hasPrefix("--highlights=") || $0 == "--flyleaf" }
            setHighlightsEnabled(highlightsForced || defaults.bool(forKey: "highlightsEnabled"))
            scribeForced = CommandLine.arguments.contains { $0 == "--scribe" || $0.hasPrefix("--scribe=") }
            setScribeEnabled(scribeForced || defaults.bool(forKey: "scribeEnabled"))
            jiraForced = CommandLine.arguments.contains("--jira")
            setJiraEnabled(jiraForced || defaults.bool(forKey: "jiraEnabled"))
            secretsForced = CommandLine.arguments.contains("--secrets")
            setSecretsEnabled(secretsForced || defaults.bool(forKey: SecretsSection.enabledKey))
            rewireSections()
        }
        if section(id: selectedSectionID) == nil { selectedSectionID = sections.first?.id ?? "" }
        if jiraForced { selectedSectionID = JiraSection.sectionID }
        if secretsForced { selectedSectionID = SecretsSection.sectionID }
        // `--highlights` opens the tab; `--highlights=books` on the shelf (the default), `--highlights=today` on the day's three, `--highlights=Highlights/<Title>.md`
        // on a book, `--highlights=search:<words>` with that search typed in.
        if highlightsForced, let highlights = highlightsSection {
            if CommandLine.arguments.contains(where: { $0.hasPrefix("--highlights") }) { selectedSectionID = HighlightsSection.sectionID }
            if let value = CommandLine.arguments.first(where: { $0.hasPrefix("--highlights=") })?.dropFirst("--highlights=".count) {
                if value == "books" { highlights.showBooks() } else if value == "today" { highlights.showToday() }
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
        // `--dump=file.png` writes a CPU render of the main window 5 s after launch
        // (`cacheDisplay`, so textures and blend modes come out flat): text and layout
        // can be checked while the screen is locked and `screencapture` refuses.
        if let path = flagValue("--dump") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                guard let view = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
    }

    /// The shared defaults are mirrored by the core; the section toggles here.
    override func defaultsChanged() {
        super.defaultsChanged()
        let defaults = UserDefaults.standard
        let scribe = defaults.bool(forKey: "scribeEnabled")
        if !scribeForced, scribe != scribeEnabled { setScribeEnabled(scribe) }
        let highlights = defaults.bool(forKey: "highlightsEnabled")
        if !highlightsForced, highlights != highlightsEnabled { setHighlightsEnabled(highlights) }
        let jira = defaults.bool(forKey: "jiraEnabled")
        if !jiraForced, jira != jiraEnabled { setJiraEnabled(jira) }
        let secrets = defaults.bool(forKey: SecretsSection.enabledKey)
        if !secretsForced, secrets != secretsEnabled { setSecretsEnabled(secrets) }
    }

    override func sectionSelectionChanged(from old: String) {
        if old == SecretsSection.sectionID, selectedSectionID != old { secretsSection?.didLeaveTab() }
        if selectedSectionID == SecretsSection.sectionID, selectedSectionID != old { secretsSection?.didEnterTab() }
        // Going somewhere (a tab, the Go menu, a search result) turns the flyleaf away.
        if flyleafPresented { flyleafPresented = false }
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
            highlights.turnToTab = { [weak self] in
                guard let self, self.selectedSectionID != HighlightsSection.sectionID else { return false }
                self.selectedSectionID = HighlightsSection.sectionID
                return true
            }
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

    func registerHotKeys() {
        GlobalHotKey.shared.register(name: HotKeyPreferences.quickTaskName, combo: HotKeyPreferences.quickTask) { [weak self] in
            guard let self, let library = self.library else { return }
            QuickTaskPanel.shared.toggle(library: library, theme: self.theme)
        }
    }

    func quickTask() {
        guard let library else { return }
        QuickTaskPanel.shared.toggle(library: library, theme: theme)
    }

    /// Synchronous, for quitting: the vault locks (and saves) first, and a sync or
    /// import under way is cancelled so its helper (scribe-vlm, Calibre, the hidden
    /// Kindle) does not outlive the app.
    override func flush() {
        secretsSection?.lockNow()
        (section(id: ScribeSection.sectionID) as? ScribeSection)?.stop()
        highlightsSection?.stop()
        super.flush()
    }

    override func save() {
        secretsSection?.saveIfDirty()
        super.save()
    }
}
