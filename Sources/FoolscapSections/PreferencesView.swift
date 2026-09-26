import SwiftUI
import AppKit
import Carbon.HIToolbox
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// A section's own settings, shown under its heading in Preferences.
public struct SectionSettingsPane: Identifiable {
    public var id: String
    public var title: String
    public var view: AnyView
    public init(id: String, title: String, view: AnyView) { self.id = id; self.title = title; self.view = view }
}

/// Preferences: theme, notebook folder, export defaults, plug-in sections.
public struct PreferencesView: View {
    @Binding var themeID: String
    let notesFolderPath: String
    let tabsSummary: String
    let sectionPanes: [SectionSettingsPane]
    let chooseFolder: (URL) -> Void
    let moveToFolder: (URL) -> Void
    let backup: BackupManager?
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("openingAnimation") private var openingAnimation = true
    @AppStorage(PreferenceKeys.ruling) private var ruling = Ruling.blank.rawValue
    @AppStorage(PreferenceKeys.marginRule) private var marginRule = false
    @AppStorage(PreferenceKeys.elasticBand) private var elasticBand = false
    @AppStorage(PreferenceKeys.tabEdge) private var tabEdge = TabEdge.left.rawValue
    @AppStorage(PreferenceKeys.paperTexture) private var paperTexture = PaperTexture.none.rawValue
    @AppStorage("exportFormat") private var exportFormat = "markdown"
    @AppStorage("exportIncludeAttachments") private var exportAttachments = true
    @AppStorage("scribeEnabled") private var scribeEnabled = false
    @AppStorage("highlightsEnabled") private var highlightsEnabled = false
    @AppStorage("flyleafOnOpen") private var flyleafOnOpen = false
    @AppStorage(BackupManager.intervalKey) private var backupInterval = BackupInterval.off.rawValue
    @AppStorage(BackupManager.keepKey) private var backupKeep = 10

    public init(themeID: Binding<String>, notesFolderPath: String, tabsSummary: String, sectionPanes: [SectionSettingsPane],
                backup: BackupManager? = nil, chooseFolder: @escaping (URL) -> Void, moveToFolder: @escaping (URL) -> Void) {
        self._themeID = themeID
        self.notesFolderPath = notesFolderPath
        self.tabsSummary = tabsSummary
        self.sectionPanes = sectionPanes
        self.backup = backup
        self.chooseFolder = chooseFolder
        self.moveToFolder = moveToFolder
    }

    public var body: some View {
        Form {
            Section("Notebook") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(NotebookTheme.builtIn) { theme in
                        ThemeSwatch(theme: theme, isSelected: theme.id == themeID)
                            .onTapGesture { themeID = theme.id }
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $textScale, in: 0.8...1.6, step: 0.05).frame(width: 200)
                        Text("\(Int((textScale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        Button("Reset") { textScale = 1 }.disabled(textScale == 1)
                    }
                }
                Text("Also ⌘+ and ⌘− in the View menu. Line height scales with the text.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Ruling", selection: $ruling) {
                    ForEach([Ruling.blank, .lined, .dotted, .grid], id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Red margin line", isOn: $marginRule)
                Text("Rules follow the text size and take their colour from the theme.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Paper") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                        ForEach(PaperTexture.allCases, id: \.self) { texture in
                            PaperSwatch(texture: texture, theme: NotebookTheme.builtIn(id: themeID) ?? .classicBlack,
                                        isSelected: texture.rawValue == paperTexture)
                                .onTapGesture { paperTexture = texture.rawValue }
                        }
                    }
                    .frame(width: 330)
                }
                Picker("Index tabs", selection: $tabEdge) {
                    ForEach(TabEdge.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Toggle("Elastic band around the cover", isOn: $elasticBand)
                Toggle("Open the cover when the app starts", isOn: $openingAnimation)
            }
            Section("Shortcuts") {
                LabeledContent("Quick task (anywhere)") { ShortcutRecorder(name: "quickTaskHotKey", defaultCombo: .quickTaskDefault) }
                Text("Opens a small panel over any app; ↩ adds the task to the Tasks tab.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Tabs") { Text(tabsSummary).foregroundStyle(.secondary) }
            }
            Section("Kindle Scribe") {
                Toggle("Sync Kindle Scribe notebooks", isOn: $scribeEnabled)
                Text("Adds a Scribe tab. Off, nothing runs: no sync, no handwriting recognition, no tab.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sectionPanes.filter { $0.id == "scribe" }) { pane in pane.view }
            }
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
            ForEach(sectionPanes.filter { !["scribe", "highlights"].contains($0.id) }) { pane in
                Section(pane.title) { pane.view }
            }
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
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520, idealHeight: 820)
    }
}

/// Settings keys the app mirrors into the theme and the chrome environment.
public enum PreferenceKeys {
    public static let ruling = "ruling"
    public static let marginRule = "marginRule"
    public static let elasticBand = "elasticBand"
    public static let tabEdge = "tabEdge"
    public static let paperTexture = "paperTexture"
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

/// A corner of the current theme's paper in one texture, with its name.
struct PaperSwatch: View {
    let texture: PaperTexture
    let theme: NotebookTheme
    let isSelected: Bool

    var body: some View {
        let page = theme.onPaper(texture).page
        VStack(spacing: 4) {
            ZStack {
                page.paperColor.color
                TextureOverlay(tile: page.textureTile, opacity: page.textureOpacity, blend: page.textureBlend)
            }
            .frame(width: 60, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.accentColor : Color.black.opacity(0.15), lineWidth: isSelected ? 2.5 : 0.5))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            Text(texture.title).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
        .help(texture == .none ? "Plain paper" : "\(texture.title) paper")
    }
}

/// A tiny notebook: cover colour, paper and ruling, with the theme's name.
struct ThemeSwatch: View {
    let theme: NotebookTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(theme.cover.baseColor.color)
                TextureOverlay(tile: theme.cover.textureTile, opacity: theme.cover.grainOpacity, blend: theme.cover.blend)
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.page.paperColor.color)
                    .overlay(
                        VStack(spacing: 5) {
                            ForEach(0..<6, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(theme.ink.color.opacity(i == 0 ? 0.75 : 0.3))
                                    .frame(width: i == 0 ? 34 : 54, height: i == 0 ? 3 : 1.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(8)
                    )
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8))
            }
            .frame(width: 112, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.black.opacity(0.15), lineWidth: isSelected ? 2.5 : 0.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            Text(theme.name).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
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
