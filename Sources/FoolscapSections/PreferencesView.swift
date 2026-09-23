import SwiftUI
import AppKit
import Carbon.HIToolbox
import FoolscapCore
import FoolscapUI

/// Preferences: theme, notebook folder, export defaults.
public struct PreferencesView: View {
    @Binding var themeID: String
    let notesFolderPath: String
    let chooseFolder: (URL) -> Void
    let moveToFolder: (URL) -> Void
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("exportFormat") private var exportFormat = "markdown"
    @AppStorage("exportIncludeAttachments") private var exportAttachments = true

    public init(themeID: Binding<String>, notesFolderPath: String, chooseFolder: @escaping (URL) -> Void,
                moveToFolder: @escaping (URL) -> Void) {
        self._themeID = themeID
        self.notesFolderPath = notesFolderPath
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
                Text("Also ⌘+ and ⌘− in the View menu. Line height and ruling scale with the text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                LabeledContent("Quick task (anywhere)") { ShortcutRecorder(name: "quickTaskHotKey", defaultCombo: .quickTaskDefault) }
                Text("Opens a small panel over any app; ↩ adds the task to the Tasks tab.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Tabs") { Text("⌘D Daily Notes · ⌘T Tasks").foregroundStyle(.secondary) }
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
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
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
                                    .fill(i == 0 ? theme.ink.color.opacity(0.7) : theme.page.ruleColor.color)
                                    .frame(width: i == 0 ? 34 : 54, height: i == 0 ? 3 : 1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(8)
                    )
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8))
                Rectangle().fill(theme.cover.bandColor.color).frame(width: 4)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 12)
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
