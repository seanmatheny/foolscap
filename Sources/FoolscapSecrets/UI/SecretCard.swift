import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

extension NotebookTheme {
    /// Index cards sit a shade lighter than the page (on dark paper, a shade up).
    var secretCardFill: Color {
        let p = page.paperColor
        let f = isDark ? 0.06 : 0.35
        return Color(.sRGB, red: p.r + (1 - p.r) * f, green: p.g + (1 - p.g) * f, blue: p.b + (1 - p.b) * f, opacity: 1)
    }
    /// A card being edited drops a shade instead.
    var secretEditingFill: Color {
        let p = page.paperColor
        return isDark ? Color(.sRGB, red: p.r + 0.04, green: p.g + 0.04, blue: p.b + 0.04, opacity: 1)
            : Color(.sRGB, red: p.r * 0.985, green: p.g * 0.985, blue: p.b * 0.975, opacity: 1)
    }
    func monoFont(_ size: CGFloat) -> Font {
        type.mono.family.map { .custom($0, size: size) } ?? .system(size: size, design: .monospaced)
    }
}

/// One entry as an index card: the title row (tags, hover controls, chevron),
/// then a row per field with secrets masked, any fenced blocks, and the notes.
/// Collapsed, it is the title row alone with a muted summary.
struct SecretCardView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: SecretsSection
    let entry: SecretEntry
    @State private var hovering = false
    @State private var confirmDelete = false

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    private var collapsed: Bool { section.collapsed.contains(entry.title) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow.frame(height: pitch)
            if !collapsed {
                Rectangle().fill(theme.accent.color.opacity(0.35)).frame(height: 0.8)
                ForEach(Array(entry.fields.enumerated()), id: \.offset) { i, field in
                    FieldRow(section: section, entry: entry, field: field)
                        .frame(height: pitch)
                    if i < entry.fields.count - 1 || !entry.blocks.isEmpty || !entry.notes.isEmpty {
                        Rectangle().fill(theme.ink.color.opacity(0.06)).frame(height: 0.5)
                    }
                }
                ForEach(Array(entry.blocks.enumerated()), id: \.offset) { i, block in
                    BlockView(section: section, entry: entry, block: block, index: i)
                        .padding(.vertical, 6)
                }
                ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.system(size: 13 * scale, design: .serif)).italic()
                        .foregroundStyle(theme.ink.color.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(minHeight: pitch, alignment: .leading)
                        .padding(.horizontal, 14)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(theme.secretCardFill))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.ink.color.opacity(hovering ? 0.22 : 0.13), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.12), radius: 1.2, y: 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .alert("Delete “\(entry.title)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { section.delete(entry) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The entry and everything in it leave the vault.")
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Button { section.toggleCollapsed(entry) } label: {
                Text(entry.title)
                    .font(.system(size: (collapsed ? 15.5 : 17) * scale, weight: .bold, design: .serif))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            if collapsed {
                Text(entry.summary)
                    .font(theme.monoFont(12 * scale))
                    .foregroundStyle(theme.dimInk.color)
                    .lineLimit(1)
            } else {
                ForEach(entry.tags, id: \.self) { tag in
                    TagChip(tag: tag, scale: scale) { section.removeTag(tag, from: entry) }
                }
            }
            Spacer()
            if !collapsed, let changed = entry.changed {
                Text("changed " + changed.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.system(size: 11 * scale, design: .serif))
                    .foregroundStyle(theme.dimInk.color)
            }
            if hovering {
                Button { section.beginEdit(entry) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("Edit as text")
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete")
            }
            Button { section.toggleCollapsed(entry) } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand" : "Collapse")
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.ink.color.opacity(0.55))
        .padding(.horizontal, 14)
    }
}

/// `label  value`, with the eye and the copy button for a secret, a link for a URL.
struct FieldRow: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: SecretsSection
    let entry: SecretEntry
    let field: SecretField
    @State private var hovering = false

    private var scale: CGFloat { theme.type.body.size / 15 }
    private var key: String { "\(entry.id)/\(field.label)" }
    private var shown: Bool { !field.isSecret || section.revealed.contains(key) }

    var body: some View {
        HStack(spacing: 8) {
            Text(field.label)
                .font(.system(size: 12.5 * scale, design: .serif))
                .foregroundStyle(theme.dimInk.color)
                .frame(width: 96, alignment: .leading)
                .lineLimit(1)
            if field.isSecret {
                Text(shown ? field.value : String(repeating: "•", count: min(14, max(8, field.value.count))))
                    .font(theme.monoFont(13 * scale))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button { section.toggleRevealed(key) } label: { Image(systemName: shown ? "eye.slash" : "eye") }
                    .buttonStyle(.plain).help(shown ? "Hide" : "Reveal")
                    .foregroundStyle(shown ? theme.accent.color : theme.ink.color.opacity(0.55))
                copyButton
            } else if field.isURL, let url = URL(string: field.value.hasPrefix("www.") ? "https://" + field.value : field.value) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text(field.value)
                        .font(theme.monoFont(13 * scale))
                        .foregroundStyle(theme.accent.color)
                        .underline(hovering)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Open \(field.value)")
                if hovering { copyButton }
            } else {
                Text(field.value)
                    .font(theme.monoFont(13 * scale))
                    .textSelection(.enabled)
                    .lineLimit(1)
                if hovering { copyButton }
            }
            if section.copiedKey == key { CopiedBadge() }
            Spacer()
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var copyButton: some View {
        Button { section.copy(field.value, key: key) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain)
            .foregroundStyle(theme.ink.color.opacity(0.55))
            .help("Copy (the clipboard clears after 30 s)")
    }
}

struct CopiedBadge: View {
    @Environment(\.notebookTheme) private var theme
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
            Text("Copied · clears in 30 s").font(.system(size: 11, design: .serif))
        }
        .foregroundStyle(theme.page.paperColor.color)
        .padding(.horizontal, 9).padding(.vertical, 2)
        .background(Capsule().fill(theme.ink.color.opacity(0.82)))
        .transition(.opacity)
    }
}

/// A fenced block: the editor's code backdrop with its lines hidden behind dots
/// until revealed, and Reveal / Copy capsules in its corner.
struct BlockView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: SecretsSection
    let entry: SecretEntry
    let block: SecretBlock
    let index: Int

    private var scale: CGFloat { theme.type.body.size / 15 }
    private var key: String { "\(entry.id)/block/\(index)" }
    private var shown: Bool { section.revealed.contains(key) }

    var body: some View {
        let palette = EditorPalette(theme: theme)
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 3) {
                if shown {
                    Text(block.body)
                        .font(theme.monoFont(12 * scale))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(0..<min(3, max(1, block.lineCount)), id: \.self) { _ in
                        Text(String(repeating: "•", count: 48))
                            .font(theme.monoFont(12 * scale))
                            .foregroundStyle(theme.ink.color.opacity(0.55))
                    }
                    if block.lineCount > 3 {
                        Text("\(block.lineCount - 3) more line\(block.lineCount - 3 == 1 ? "" : "s")")
                            .font(.system(size: 11 * scale, design: .serif)).italic()
                            .foregroundStyle(theme.dimInk.color)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .padding(.trailing, 150)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if let info = block.info {
                    Text(info).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.dimInk.color)
                }
                capsule(shown ? "Hide" : "Reveal") { section.toggleRevealed(key) }
                capsule("Copy") { section.copy(block.body, key: key) }
                if section.copiedKey == key { CopiedBadge() }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: palette.codeBlockBackground)))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.dimInk.color.opacity(0.18), lineWidth: 0.5))
        .padding(.horizontal, 10)
    }

    private func capsule(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .serif))
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(Capsule().fill(theme.accent.color.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

/// A card flipped over: the entry's markdown in the editor, with nothing of it
/// written anywhere (no attachments, link cards, fold memory or spell checker).
struct SecretEntryEditor: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: SecretsSection
    let document: NoteDocument

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        let _ = document.editCount
        let lines = document.text.split(separator: "\n", omittingEmptySubsequences: false).count
        let rows = CGFloat(min(16, max(5, lines + 1)))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(section.editingID == SecretsSection.newEntryID ? "New secret, as text" : "Editing as text")
                    .font(.system(size: 11 * scale, design: .serif))
                    .foregroundStyle(theme.dimInk.color)
                Text("## Title #tags · - label: value · a value in `backticks` is hidden · a ``` block is a long secret")
                    .font(.system(size: 10.5 * scale, design: .serif))
                    .foregroundStyle(theme.dimInk.color.opacity(0.8))
                    .lineLimit(1)
                Spacer()
                Button { section.commitEdit() } label: {
                    Text("Done")
                        .font(.system(size: 11.5, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 10).padding(.vertical, 2)
                        .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                        .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Done (⇧⌘↩)")
                Button("Cancel") { section.cancelEdit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, design: .serif))
                    .foregroundStyle(theme.dimInk.color)
            }
            .padding(.horizontal, 14)
            .frame(height: pitch)
            MarkdownEditor(document: document, tags: { [section] in section.knownTags }, features: []) {}
                .frame(height: rows * pitch)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .background(RoundedRectangle(cornerRadius: 3).fill(theme.secretEditingFill))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent.color.opacity(0.45), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.12), radius: 1.2, y: 1)
        .onAppear {
            // A new card's caret belongs after "## ", where the title goes.
            guard section.editingID == SecretsSection.newEntryID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let view = NSApp.keyWindow?.firstResponder as? MarkdownTextView, view.string.hasPrefix("## ") {
                    view.setSelectedRange(NSRange(location: 3, length: 0))
                }
            }
        }
    }
}
