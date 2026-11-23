import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// The shelf: a header with the order chips and the title filter, then every note's
/// cover and, last, a card that starts a new note.
struct ReferenceShelf: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Bindable var section: ReferenceSection
    @FocusState private var filterFocused: Bool
    @State private var prompt: TitlePrompt?
    @State private var promptText = ""
    @State private var promptError: String?
    @State private var trashing: ReferenceNote?
    @State private var trashFailed: ReferenceNote?
    @State private var picking: ReferenceNote?

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    enum TitlePrompt: Identifiable, Equatable {
        case create
        case rename(ReferenceNote)
        var id: String {
            switch self {
            case .create: return "create"
            case .rename(let note): return "rename:" + note.path
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let leading = PageColumn.textLeft, trailing = PageColumn.trailing(compact: compact)
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(minHeight: geo.size.height)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        Spacer().frame(height: pitch / 2)
                        if section.hasLoaded && section.notes.isEmpty {
                            Text("Notes you come back to (a packing list, the boiler's manual, how the backups work) live here, each with a cover of its own.")
                                .font(theme.type.body.face(14 * scale)).foregroundStyle(theme.dimInk.color)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, pitch)
                        }
                        if section.hasLoaded || !section.notes.isEmpty {
                            grid(width: max(120, geo.size.width - leading - trailing))
                        }
                        Spacer(minLength: pitch * 2)
                    }
                    .padding(.leading, leading)
                    .padding(.trailing, trailing)
                    .padding(.top, pitch)
                }
            }
        }
        .alert(promptTitle, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField("Title", text: $promptText)
            Button(prompt == .create ? "Create" : "Rename") { commitPrompt() }
            Button("Cancel", role: .cancel) { prompt = nil }
        } message: {
            if let promptError { Text(promptError) }
        }
        .confirmationDialog(trashing.map { "Move “\($0.title)” to the Trash?" } ?? "",
                            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                guard let note = trashing else { return }
                Task {
                    do { try await section.remove(note) } catch { trashFailed = note }
                }
            }
        }
        .confirmationDialog(trashFailed.map { "“\($0.title)” could not go to the Trash. Delete it for good?" } ?? "",
                            isPresented: Binding(get: { trashFailed != nil }, set: { if !$0 { trashFailed = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let note = trashFailed else { return }
                Task {
                    do { try await section.remove(note, permanently: true) }
                    catch { section.lastError = "Could not delete “\(note.title)”: \(error.localizedDescription)" }
                }
            }
        } message: { Text("This cannot be undone.") }
        .sheet(item: compact ? $picking : .constant(nil)) { note in
            CoverPicker(section: section, note: note)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: "\(section.pendingCoverPicker ?? "")|\(section.notes.count)", initial: true) {
            guard let title = section.pendingCoverPicker, let note = section.notes.first(where: { $0.title == title }) else { return }
            section.pendingCoverPicker = nil
            picking = note
        }
    }

    private var promptTitle: String {
        switch prompt {
        case .create: return "New Reference Note"
        case .rename(let note): return "Rename “\(note.title)”"
        case nil: return ""
        }
    }

    private func ask(_ p: TitlePrompt) {
        promptError = nil
        if case .rename(let note) = p { promptText = note.title } else { promptText = "" }
        prompt = p
    }

    private func commitPrompt() {
        guard let p = prompt else { return }
        let text = promptText
        prompt = nil
        Task {
            do {
                switch p {
                case .create: try await section.create(title: text)
                case .rename(let note): try await section.rename(note, to: text)
                }
            } catch {
                // Ask again, saying why.
                promptError = error.localizedDescription
                promptText = text
                prompt = p
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Reference").font(theme.type.heading.font).fontWeight(.bold)
                Text("\(section.notes.count)").font(theme.type.body.face(13 * scale)).foregroundStyle(theme.dimInk.color)
                Spacer()
                if !compact, !section.notes.isEmpty {
                    sortChips
                    filterField
                }
            }
            .clearOfTabChip()
            .frame(height: pitch * 1.5)
            if compact, !section.notes.isEmpty {
                HStack(spacing: 8) {
                    sortChips
                    filterField
                }
                .frame(height: pitch)
            }
            if let error = section.lastError {
                HStack(spacing: 6) {
                    Text(error)
                    Button { section.lastError = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
                .font(theme.type.body.face(12 * scale)).foregroundStyle(theme.accent.color)
                .frame(height: pitch)
            }
        }
    }

    @ViewBuilder private var sortChips: some View {
        ForEach(ReferenceSort.allCases, id: \.self) { sort in
            FilterChip(label: sort.label, isOn: section.sort == sort) { section.sort = sort }
        }
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.dimInk.color)
            TextField("Filter by title", text: $section.filter)
                .font(theme.type.body.face(13 * scale))
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onSubmit {
                    // Return opens the one note left.
                    if section.shelf.count == 1, let note = section.shelf.first { section.open(path: note.path) }
                }
            if !section.filter.isEmpty {
                Button { section.filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimInk.color)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(width: compact ? nil : 200)
        .frame(maxWidth: compact ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(filterFocused ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(filterFocused ? 0.22 : 0.12), lineWidth: 0.5))
        .colorScheme(theme.isDark ? .dark : .light)
    }

    // MARK: Grid

    static let cellWidth: CGFloat = 128
    static let spacing: CGFloat = 22

    /// Built once, not lazily, like the Highlights shelf: a few dozen cells cost nothing.
    private func grid(width: CGFloat) -> some View {
        // A phone's shelf holds two notes a row, each cell half the width.
        let cell = compact ? max(110, floor((width - Self.spacing) / 2)) : Self.cellWidth
        let columns = max(1, Int((width + Self.spacing) / (cell + Self.spacing)))
        let items: [ShelfSlot] = section.shelf.map { .note($0) } + (section.filter.isEmpty ? [.new] : [])
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        let coverWidth = compact ? min(160, cell - 12) : 112
        return VStack(alignment: .leading, spacing: 26) {
            ForEach(rows, id: \.first!.id) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row) { slot in
                        switch slot {
                        case .note(let note):
                            ShelfNote(section: section, note: note, cellWidth: cell, coverWidth: coverWidth, picking: $picking,
                                      onRename: { ask(.rename(note)) }, onTrash: { trashing = note })
                        case .new:
                            NewNoteCard(cellWidth: cell, coverWidth: coverWidth) { ask(.create) }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    enum ShelfSlot: Identifiable {
        case note(ReferenceNote)
        case new
        var id: String {
            switch self {
            case .note(let note): return note.path
            case .new: return "+new"
            }
        }
    }
}

/// One note on the shelf: its cover, then when it was last edited.
struct ShelfNote: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Bindable var section: ReferenceSection
    let note: ReferenceNote
    let cellWidth: CGFloat
    let coverWidth: CGFloat
    @Binding var picking: ReferenceNote?
    let onRename: () -> Void
    let onTrash: () -> Void
    @State private var hovering = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        Button { section.open(path: note.path) } label: {
            VStack(spacing: 8) {
                NoteCover(cover: section.cover(for: note), title: note.title, width: coverWidth)
                    .opacity(note.isPlaceholder ? 0.6 : 1)
                    .standingOnShelf(width: coverWidth, lifted: hovering, flattened: false)
                Text(note.isPlaceholder ? "In iCloud" : Self.edited(note.modified))
                    .font(theme.type.body.face(10.5 * scale)).foregroundStyle(theme.dimInk.color)
            }
            .frame(width: cellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(note.title)
        .popover(item: compact ? .constant(nil) : popoverBinding, arrowEdge: .trailing) { note in
            CoverPicker(section: section, note: note)
        }
        .contextMenu {
            Button("Open") { section.open(path: note.path) }
            Button("Change Cover…") { picking = note }
            Button("Rename…", action: onRename)
            #if canImport(AppKit)
            Button("Show in Finder") { section.revealInFinder(note) }
            #endif
            Divider()
            Button("Move to Trash", role: .destructive, action: onTrash)
        }
    }

    /// The shelf's popover belongs to the cover it was opened from.
    private var popoverBinding: Binding<ReferenceNote?> {
        Binding(get: { picking?.path == note.path ? picking : nil }, set: { if $0 == nil { picking = nil } })
    }

    static func edited(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Edited today" }
        if calendar.isDateInYesterday(date) { return "Edited yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return "Edited " + date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }
}

/// The last card on the shelf: a dashed outline that starts a new note.
struct NewNoteCard: View {
    @Environment(\.notebookTheme) private var theme
    let cellWidth: CGFloat
    let coverWidth: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: max(2, coverWidth / 40))
                    .strokeBorder(theme.ink.color.opacity(hovering ? 0.45 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: coverWidth, height: (coverWidth * 4 / 3).rounded())
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: coverWidth / 6, weight: .light))
                            Text("New note").font(theme.type.body.face(max(10, coverWidth / 10)))
                        }
                        .foregroundStyle(theme.ink.color.opacity(hovering ? 0.7 : 0.45))
                    }
                Text(" ").font(theme.type.body.face(10.5))
            }
            .frame(width: cellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start a new Reference note")
    }
}
