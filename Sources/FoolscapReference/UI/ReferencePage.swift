import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// The Reference tab: the shelf, or one note open in the editor.
struct ReferencePage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: ReferenceSection

    var body: some View {
        ZStack {
            switch section.mode {
            case .shelf:
                ReferenceShelf(section: section)
                    .transition(.opacity)
            case .note(let path):
                ReferenceNotePage(section: section, path: path)
                    .id(path)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: section.mode)
        .foregroundStyle(theme.ink.color)
        .task { await section.reload() }
    }
}

/// The settings both apps show for the tab (under its toggle).
struct ReferenceSettingsPane: View {
    @Bindable var section: ReferenceSection

    var body: some View {
        Picker("Order the shelf", selection: $section.sort) {
            Text("By title").tag(ReferenceSort.title)
            Text("Recently edited first").tag(ReferenceSort.edited)
        }
        Text("Notes live in the Reference folder of your notebook, one file each. Their covers are kept beside them in a small file the iPhone reads too.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
