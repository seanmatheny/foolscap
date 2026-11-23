import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

/// One Reference note in the editor, with its cover (which opens the picker) and the
/// way back to the shelf in the corner where the daily page keeps its day controls.
struct ReferenceNotePage: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Bindable var section: ReferenceSection
    let path: String
    /// Set from `.task`, not fetched in `body`: opening a note creates a document.
    @State private var document: NoteDocument?
    @State private var picking: ReferenceNote?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let document, document.isLoaded {
                MarkdownEditor(document: document, revealLine: section.pendingLine,
                               tags: { [library = section.library] in library.knownTags }) { section.library.scheduleSave() }
                    // A folder switch or a restore replaces every document.
                    .id("\(document.path)/\(section.library.generation)")
                    .ignoresPageInsets(compact)
            }
            controls
                .padding(.top, 8)
                .padding(.trailing, compact ? PageRuling.textRight : 44)
                .clearOfTabChip()
            if let document {
                NoteLoadStatus(document: document, compact: compact)
                NoteChangeBanners(document: document, compact: compact)
            }
        }
        .task(id: "\(path)/\(section.library.generation)") {
            let library = section.library
            let doc = library.document(atRelativePath: path)
            document = doc
            await library.save()
            library.releaseDocuments(except: [doc.path, NotesFolder.tasksFileName])
        }
        .sheet(item: compact ? $picking : .constant(nil)) { note in
            CoverPicker(section: section, note: note).presentationDetents([.medium, .large])
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if let note = section.note(atPath: path) {
                Button { picking = note } label: {
                    NoteCover(cover: section.cover(for: note), title: note.title, width: 18, showsLabel: false)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                }
                .buttonStyle(.plain)
                .help("Change the cover")
                .popover(item: compact ? .constant(nil) : $picking, arrowEdge: .bottom) { note in
                    CoverPicker(section: section, note: note)
                }
            }
            Button { section.showShelf() } label: {
                Label(compact ? "Shelf" : "All notes", systemImage: "chevron.left")
                    .font(theme.type.body.face(12, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(theme.page.paperColor.color.opacity(0.85)))
                    .background(Capsule().fill(theme.accent.color.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Back to the shelf")
        }
    }
}
