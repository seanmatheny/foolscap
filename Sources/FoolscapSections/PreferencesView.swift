#if canImport(AppKit)
import SwiftUI
import AppKit
import Carbon.HIToolbox
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// Preferences: theme, notebook folder, export defaults, plug-in sections.
/// The sections both apps share are in PreferencePanes.swift.
public struct PreferencesView: View {
    @Binding var themeID: String
    let notesFolderPath: String
    let tabsSummary: String
    let sectionPanes: [SectionSettingsPane]
    let chooseFolder: (URL) -> Void
    let moveToFolder: (URL) -> Void
    let backup: BackupManager?
    /// Every tag in the notebook, offered when a pen's tag is chosen.
    let knownTags: [String]
    @AppStorage("exportFormat") private var exportFormat = "markdown"
    @AppStorage("exportIncludeAttachments") private var exportAttachments = true
    @AppStorage("scribeEnabled") private var scribeEnabled = false
    @AppStorage("highlightsEnabled") private var highlightsEnabled = false
    @AppStorage("jiraEnabled") private var jiraEnabled = false
    @AppStorage("secretsEnabled") private var secretsEnabled = false
    @AppStorage("flyleafOnOpen") private var flyleafOnOpen = false
    @AppStorage(BackupManager.intervalKey) private var backupInterval = BackupInterval.off.rawValue
    @AppStorage(BackupManager.keepKey) private var backupKeep = 10

    public init(themeID: Binding<String>, notesFolderPath: String, tabsSummary: String, sectionPanes: [SectionSettingsPane],
                backup: BackupManager? = nil, knownTags: [String] = [],
                chooseFolder: @escaping (URL) -> Void, moveToFolder: @escaping (URL) -> Void) {
        self._themeID = themeID
        self.notesFolderPath = notesFolderPath
        self.tabsSummary = tabsSummary
        self.sectionPanes = sectionPanes
        self.backup = backup
        self.knownTags = knownTags
        self.chooseFolder = chooseFolder
        self.moveToFolder = moveToFolder
    }

    /// The tab Settings opens on; `--prefs-tab=name` picks one for screenshots.
    @AppStorage("settingsTab") private var tab = "notebook"

    public var body: some View {
        TabView(selection: $tab) {
            notebookTab.tabItem { Label("Notebook", systemImage: "book.closed") }.tag("notebook")
            shortcutsTab.tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag("shortcuts")
            tasksTab.tabItem { Label("Tasks", systemImage: "checklist") }.tag("tasks")
            scribeTab.tabItem { Label("Scribe", systemImage: "pencil.and.scribble") }.tag("scribe")
            highlightsTab.tabItem { Label("Highlights", systemImage: "highlighter") }.tag("highlights")
            jiraTab.tabItem { Label("Jira", systemImage: "checkmark.rectangle.stack") }.tag("jira")
            secretsTab.tabItem { Label("Secrets", systemImage: "lock") }.tag("secrets")
            ForEach(sectionPanes.filter { !["scribe", "highlights", "jira", "secrets"].contains($0.id) }) { pane in
                settingsForm(height: 420) { Section(pane.title) { pane.view } }
                    .tabItem { Label(pane.title, systemImage: "puzzlepiece.extension") }.tag(pane.id)
            }
            filesTab.tabItem { Label("Files", systemImage: "folder") }.tag("files")
        }
        .frame(width: 600)
        .onAppear {
            if let flag = CommandLine.arguments.first(where: { $0.hasPrefix("--prefs-tab=") }) {
                tab = String(flag.dropFirst("--prefs-tab=".count))
            }
        }
    }

    /// Every tab is a grouped form of the same width; the window follows the tab's height.
    private func settingsForm<C: View>(height: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(height: height)
    }

    private var notebookTab: some View {
        settingsForm(height: 900) { NotebookSettingsSections(themeID: $themeID) }
    }

    private var shortcutsTab: some View {
        settingsForm(height: 800) {
            Section("Shortcuts") {
                LabeledContent("Quick task (anywhere)") { ShortcutRecorder(name: "quickTaskHotKey", defaultCombo: .quickTaskDefault) }
                Text("Opens a small panel over any app; ↩ adds the task to the Tasks tab.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Tabs") { Text(tabsSummary).foregroundStyle(.secondary) }
            }
            Section("Writing") {
                shortcutRow("Bold · Italic · Strikethrough · Inline code", "⌘B · ⌘I · ⇧⌘X · ⇧⌘C")
                shortcutRow("Link (a URL on the clipboard fills the address)", "⌘K")
                shortcutRow("Heading 1–6 (again for plain text)", "⌘1 – ⌘6")
                shortcutRow("Bulleted list · Numbered list · Task", "⇧⌘L · ⌥⌘L · ⌥⌘T")
                shortcutRow("Mark task done", "⌘↩")
                shortcutRow("Block quote · Code block · Horizontal rule", "⌘' · ⌥⌘C · ⌥⌘-")
                shortcutRow("Next list item, task or quote line", "↩")
                shortcutRow("Plain new line inside a list", "⇧↩")
                shortcutRow("Indent · outdent a list item", "⇥ · ⇧⇥")
                Text("↩ on an empty item ends the list; on a nested one it steps out a level.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sections") {
                shortcutRow("Fold · unfold the section at the caret", "⌥⌘← · ⌥⌘→")
                shortcutRow("Fold · unfold every section", "⌥⇧⌘← · ⌥⇧⌘→")
                Text("A heading's chevron in the margin folds it too; folded sections stay folded when the note is reopened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var tasksTab: some View {
        settingsForm(height: 620) { PensSettings(knownTags: knownTags) }
    }

    private func shortcutRow(_ label: String, _ keys: String) -> some View {
        LabeledContent(label) { Text(keys).foregroundStyle(.secondary).monospacedDigit() }
    }

    private var scribeTab: some View {
        settingsForm(height: 600) {
            Section("Kindle Scribe") {
                Toggle("Sync Kindle Scribe notebooks", isOn: $scribeEnabled)
                Text("Adds a Scribe tab. Off, nothing runs: no sync, no handwriting recognition, no tab.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sectionPanes.filter { $0.id == "scribe" }) { pane in pane.view }
            }
        }
    }

    private var highlightsTab: some View {
        settingsForm(height: 760) {
            Section("Kindle Highlights") {
                Toggle("Show Kindle highlights", isOn: $highlightsEnabled)
                Text("Adds a Highlights tab: the highlights from the Kindle app on this Mac, three of them a day. Off, nothing runs: no import, no tab.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open on today's highlights", isOn: $flyleafOnOpen)
                    .disabled(!highlightsEnabled)
                Text("The cover opens onto a loose page with the day's three; a click turns it to the notebook.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sectionPanes.filter { $0.id == "highlights" }) { pane in pane.view }
            }
        }
    }

    private var jiraTab: some View {
        settingsForm(height: 560) {
            Section("Jira") {
                Toggle("Connect to Jira Cloud", isOn: $jiraEnabled)
                Text("Adds a Jira tab listing the issues assigned to you. Off, nothing runs: no requests, no tab.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sectionPanes.filter { $0.id == "jira" }) { pane in pane.view }
            }
        }
    }

    private var secretsTab: some View {
        settingsForm(height: 560) {
            Section("Secrets") {
                Toggle("Keep secrets in the notebook", isOn: $secretsEnabled)
                Text("Adds a padlocked Secrets tab: an address book of passwords, keys and codes, encrypted with AES-256 in one file in the notebook folder and opened with Touch ID or your password. Nothing in it is indexed or searchable from the other tabs. Off, the tab is gone and the vault is left as it is.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sectionPanes.filter { $0.id == "secrets" }) { pane in pane.view }
            }
        }
    }

    private var filesTab: some View {
        settingsForm(height: 700) {
            Section("Storage") {
                LabeledContent("Notebook folder") {
                    HStack {
                        Text(notesFolderPath).truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                            panel.prompt = "Use Folder"
                            panel.message = "Choose where daily notes and attachments are kept. iCloud Drive syncs between Macs."
                            panel.directoryURL = URL(fileURLWithPath: notesFolderPath)
                            guard panel.runModal() == .OK, let url = panel.url else { return }
                            let alert = NSAlert()
                            alert.messageText = "Use \(url.lastPathComponent)?"
                            alert.informativeText = "Move your existing notes and attachments into this folder, or open it as it is? The current folder is left untouched either way."
                            alert.addButton(withTitle: "Move Notes Here")
                            alert.addButton(withTitle: "Open As Is")
                            alert.addButton(withTitle: "Cancel")
                            switch alert.runModal() {
                            case .alertFirstButtonReturn: moveToFolder(url)
                            case .alertSecondButtonReturn: chooseFolder(url)
                            default: break
                            }
                        }
                    }
                }
                Text("Notes are plain markdown files: Daily/YYYY-MM-DD.md with images in Attachments/. The search index is rebuilt automatically and lives in ~/Library/Application Support/Foolscap.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Export") {
                Picker("Default format", selection: $exportFormat) {
                    Text("Markdown").tag("markdown")
                    Text("HTML").tag("html")
                    Text("PDF").tag("pdf")
                }
                Toggle("Include attachments with Markdown exports", isOn: $exportAttachments)
            }
            if let backup {
                Section("Backup") {
                    BackupSettings(backup: backup, interval: $backupInterval, keep: $backupKeep)
                }
            }
        }
    }
}

/// The Backup section of Settings: schedule, folder, one-off backup and restore.
struct BackupSettings: View {
    let backup: BackupManager
    @Binding var interval: String
    @Binding var keep: Int

    var body: some View {
        Picker("Back up automatically", selection: $interval) {
            ForEach(BackupInterval.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }
        .onChange(of: interval) { _, _ in backup.checkSchedule() }
        if interval != BackupInterval.off.rawValue {
            Stepper("Keep the last \(keep) backup\(keep == 1 ? "" : "s")", value: $keep, in: 1...100)
            Text("A due backup runs shortly after Foolscap is next opened, and then once the interval has passed again while it stays open.")
                .font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Backup folder") {
            HStack {
                Text(backup.folder.path).truncationMode(.middle).lineLimit(1).foregroundStyle(.secondary)
                Button("Choose…") { BackupCommands.chooseFolder(backup) }
            }
        }
        LabeledContent("Last backup") {
            HStack {
                Text(backup.lastBackup.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "Never")
                    .foregroundStyle(.secondary)
                if let file = backup.lastFile, FileManager.default.fileExists(atPath: file.path) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            }
        }
        HStack {
            Button(backup.isRunning ? (backup.phase ?? "Working…") : "Back Up Now…") { BackupCommands.backUpNow(backup) }
                .disabled(backup.isRunning)
            Button("Restore from Backup…") { BackupCommands.restore(backup) }
                .disabled(backup.isRunning)
        }
        if let error = backup.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let message = backup.lastMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        Text("One zip file holds everything: notes and attachments, Tasks.md, Scribe notebooks and transcripts, highlight books and covers, the search index, sync state and these settings. Restoring replaces all of it; the current notebook is backed up to the folder above first.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Click, press a key combination, done. Stored in UserDefaults under `name`;
/// `HotKeyPreferences.changed` tells the app to re-register.
struct ShortcutRecorder: View {
    let name: String
    let defaultCombo: HotKeyCombo
    @State private var combo: HotKeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: startRecording) {
                Text(recording ? "Press keys…" : (combo?.display ?? "Off"))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            Button("Default") { set(defaultCombo) }.disabled(combo == defaultCombo)
            Button("Off") { set(nil) }.disabled(combo == nil)
        }
        .onAppear { combo = HotKeyCombo.load(name) ?? defaultCombo; if UserDefaults.standard.bool(forKey: name + ".off") { combo = nil } }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty { stopRecording(); return nil }
            guard !mods.isEmpty || event.keyCode >= UInt16(kVK_F1) else { NSSound.beep(); return nil }
            set(HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods, display: HotKeyCombo.display(for: event)))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func set(_ c: HotKeyCombo?) {
        combo = c
        if let c { c.save(name); UserDefaults.standard.set(false, forKey: name + ".off") }
        else { UserDefaults.standard.set(true, forKey: name + ".off") }
        NotificationCenter.default.post(name: HotKeyPreferences.changed, object: nil)
    }
}

public enum HotKeyPreferences {
    public static let changed = Notification.Name("foolscap.hotkeys.changed")
    public static let quickTaskName = "quickTaskHotKey"

    /// The effective quick-task combo, or nil when turned off.
    public static var quickTask: HotKeyCombo? {
        if UserDefaults.standard.bool(forKey: quickTaskName + ".off") { return nil }
        return HotKeyCombo.load(quickTaskName) ?? .quickTaskDefault
    }
}
#endif
