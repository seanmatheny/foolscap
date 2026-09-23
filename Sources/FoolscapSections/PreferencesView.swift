import SwiftUI
import AppKit
import FoolscapCore
import FoolscapUI

/// Preferences: theme, notebook folder, export defaults.
public struct PreferencesView: View {
    @Binding var themeID: String
    let notesFolderPath: String
    let chooseFolder: (URL) -> Void
    let moveToFolder: (URL) -> Void
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
