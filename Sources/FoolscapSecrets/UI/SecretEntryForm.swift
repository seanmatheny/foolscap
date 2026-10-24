import SwiftUI
import FoolscapCore
import FoolscapUI

/// A card being edited as a form: the title, its tags, one row per field (label, value,
/// hide/show, remove), long secrets and notes. Plain text fields throughout, so a paste
/// lands where it is put; the markdown is written on Done.
struct SecretEntryForm: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Bindable var section: SecretsSection
    @State private var revealed: Set<UUID> = []
    @State private var newTag = ""
    @FocusState private var focus: Focus?

    enum Focus: Hashable { case title, tag, label(UUID), value(UUID), block(UUID), notes }

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    private var isNew: Bool { section.editingID == SecretsSection.newEntryID }
    private var labelWidth: CGFloat { compact ? 78 : 110 }

    private var form: Binding<SecretForm> {
        Binding(get: { section.form ?? .blank() }, set: { section.form = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            titleField
            tagRow
            Rectangle().fill(theme.accent.color.opacity(0.35)).frame(height: 0.8)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(form.fields) { $field in fieldRow($field) }
            }
            ForEach(form.blocks) { $block in blockRow($block) }
            HStack(spacing: 14) {
                addButton("Field", systemImage: "plus") {
                    let field = SecretForm.Field(label: "", isSecret: false)
                    section.form?.fields.append(field)
                    focus = .label(field.id)
                }
                addButton("Long secret", systemImage: "text.alignleft") {
                    let block = SecretForm.Block()
                    section.form?.blocks.append(block)
                    revealed.insert(block.id)
                    focus = .block(block.id)
                }
                .help("A multi-line secret, such as a private key or recovery codes")
            }
            notesField
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .font(theme.type.body.face(13 * scale))
        .foregroundStyle(theme.ink.color)
        .tint(theme.accent.color)
        .colorScheme(theme.isDark ? .dark : .light)
        .background(RoundedRectangle(cornerRadius: 3).fill(theme.secretEditingFill))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(theme.accent.color.opacity(0.45), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.12), radius: 1.2, y: 1)
        .onAppear {
            // The new card's caret belongs in the title.
            if isNew { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .title } }
        }
    }

    // MARK: Rows

    private var header: some View {
        HStack(spacing: 10) {
            Text(isNew ? "New secret" : "Editing")
                .font(theme.type.body.face(11 * scale))
                .foregroundStyle(theme.dimInk.color)
            Spacer()
            Button("Edit as Text") { section.editAsText() }
                .buttonStyle(.plain)
                .font(theme.type.body.face(11 * scale))
                .foregroundStyle(theme.dimInk.color)
                .help(isNew ? "Type or paste the markdown instead (a list with a heading per entry makes several cards)" : "Edit the entry's markdown")
            Button { section.commitEdit() } label: {
                Text("Done")
                    .font(theme.type.body.face(11.5, weight: .semibold))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                    .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(!form.wrappedValue.hasTitle)
            .opacity(form.wrappedValue.hasTitle ? 1 : 0.45)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help(form.wrappedValue.hasTitle ? "Done (⇧⌘↩)" : "Give the entry a title first")
            Button("Cancel") { section.cancelEdit() }
                .buttonStyle(.plain)
                .font(theme.type.body.face(11.5))
                .foregroundStyle(theme.dimInk.color)
        }
    }

    private var titleField: some View {
        TextField("Title", text: form.title)
            .font(theme.type.heading.face(17 * scale, weight: .bold))
            .focused($focus, equals: .title)
            .onSubmit { focus = form.wrappedValue.fields.first.map { .value($0.id) } }
            .inset(theme)
    }

    private var tagRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(form.wrappedValue.tags, id: \.self) { tag in
                TagChip(tag: tag, scale: scale) { section.form?.tags.removeAll { $0 == tag } }
            }
            TextField(form.wrappedValue.tags.isEmpty ? "Add tags" : "Add tag", text: $newTag)
                .font(theme.type.body.face(12 * scale))
                .textFieldStyle(.plain)
                .frame(width: 110)
                .focused($focus, equals: .tag)
                .onSubmit { addTypedTags(); focus = .tag }
                .onKeyPress(.tab) {
                    guard let first = tagSuggestions.first else { return .ignored }
                    addTag(first)
                    return .handled
                }
                .onChange(of: newTag) { _, typed in
                    // A space or comma ends a tag.
                    if typed.last == " " || typed.last == "," { addTypedTags() }
                }
            ForEach(tagSuggestions, id: \.self) { tag in
                Button("#" + tag) { addTag(tag) }
                    .buttonStyle(.plain)
                    .font(theme.type.body.face(11 * scale))
                    .foregroundStyle(theme.accent.color.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().stroke(theme.accent.color.opacity(0.3), lineWidth: 0.5))
            }
        }
    }

    /// Known tags starting with what is typed (only while typing), minus the entry's own.
    private var tagSuggestions: [String] {
        let typed = newTag.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "#" }).lowercased()
        guard !typed.isEmpty else { return [] }
        let own = Set(form.wrappedValue.tags)
        return section.knownTags.filter { !own.contains($0) && $0.lowercased().hasPrefix(typed) }.prefix(4).map { $0 }
    }

    private func addTag(_ tag: String) {
        if section.form?.tags.contains(tag) == false { section.form?.tags.append(tag) }
        newTag = ""
    }

    private func addTypedTags() {
        for tag in SecretForm.tags(from: newTag) { addTag(tag) }
        newTag = ""
    }

    private func fieldRow(_ field: Binding<SecretForm.Field>) -> some View {
        let id = field.wrappedValue.id
        let secret = field.wrappedValue.isSecret
        let shown = !secret || revealed.contains(id)
        return HStack(spacing: 8) {
            TextField("Label", text: field.label)
                .font(theme.type.body.face(12.5 * scale))
                .foregroundStyle(theme.dimInk.color)
                .focused($focus, equals: .label(id))
                .onSubmit {
                    // A label such as "password" hides its value by default.
                    if field.wrappedValue.value.isEmpty, SecretForm.labelSuggestsSecret(field.wrappedValue.label) { field.wrappedValue.isSecret = true }
                    focus = .value(id)
                }
                .inset(theme)
                .frame(width: labelWidth)
            Group {
                if shown {
                    TextField(secret ? "Hidden value" : "Value", text: field.value)
                } else {
                    SecureField("Hidden value", text: field.value)
                }
            }
            .font(theme.monoFont(13 * scale))
            .focused($focus, equals: .value(id))
            .inset(theme)
            if secret {
                iconButton(shown ? "eye.slash" : "eye", help: shown ? "Hide while editing" : "Show while editing", on: shown) {
                    if shown { revealed.remove(id) } else { revealed.insert(id) }
                }
            }
            iconButton(secret ? "lock.fill" : "lock.open", help: secret ? "Hidden on the card: click to show it plainly" : "Shown on the card: click to hide it behind dots", on: secret) {
                field.wrappedValue.isSecret.toggle()
                if field.wrappedValue.isSecret { revealed.insert(id) }
            }
            iconButton("minus.circle", help: "Remove this field", on: false) {
                section.form?.fields.removeAll { $0.id == id }
            }
        }
    }

    private func blockRow(_ block: Binding<SecretForm.Block>) -> some View {
        let id = block.wrappedValue.id
        let shown = revealed.contains(id)
        let lines = block.wrappedValue.body.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Long secret")
                    .font(theme.type.body.face(12.5 * scale))
                    .foregroundStyle(theme.dimInk.color)
                if !block.wrappedValue.info.isEmpty {
                    Text(block.wrappedValue.info).font(theme.type.mono.face(10, weight: .medium)).foregroundStyle(theme.dimInk.color)
                }
                Spacer()
                iconButton(shown ? "eye.slash" : "eye", help: shown ? "Hide while editing" : "Show to edit", on: shown) {
                    if shown { revealed.remove(id) } else { revealed.insert(id) }
                }
                iconButton("minus.circle", help: "Remove this long secret", on: false) {
                    section.form?.blocks.removeAll { $0.id == id }
                }
            }
            if shown {
                TextEditor(text: block.body)
                    .font(theme.monoFont(12 * scale))
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .block(id))
                    .frame(height: CGFloat(min(12, max(3, lines + 1))) * 16 * scale)
                    .inset(theme)
            } else {
                Button { revealed.insert(id) } label: {
                    Text(block.wrappedValue.body.isEmpty ? "Empty: click to type" : String(repeating: "•", count: compact ? 20 : 40) + "  \(lines) line\(lines == 1 ? "" : "s")")
                        .font(theme.monoFont(12 * scale))
                        .foregroundStyle(theme.ink.color.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .inset(theme)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var notesField: some View {
        let lines = form.wrappedValue.notes.split(separator: "\n", omittingEmptySubsequences: false).count
        return ZStack(alignment: .topLeading) {
            TextEditor(text: form.notes)
                .font(theme.type.body.face(13 * scale))
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .notes)
                .frame(height: CGFloat(min(8, max(2, lines + 1))) * 18 * scale)
            if form.wrappedValue.notes.isEmpty {
                Text("Notes")
                    .font(theme.type.body.face(13 * scale)).italic()
                    .foregroundStyle(theme.dimInk.color.opacity(0.8))
                    .padding(.leading, 5).padding(.top, 1)
                    .allowsHitTesting(false)
            }
        }
        .inset(theme)
    }

    // MARK: Pieces

    private func iconButton(_ name: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? theme.accent.color : theme.ink.color.opacity(0.5))
        .help(help)
    }

    private func addButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(theme.type.body.face(11.5 * scale, weight: .semibold))
                .foregroundStyle(theme.accent.color)
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// A soft inset on the card, like the search field's.
    func inset(_ theme: NotebookTheme) -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.ink.color.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.ink.color.opacity(0.13), lineWidth: 0.5))
    }
}
