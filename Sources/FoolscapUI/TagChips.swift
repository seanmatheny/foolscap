import SwiftUI
import FoolscapCore

/// A tag on a row. Clicking it takes the tag off; hovering strikes it through
/// to say so.
public struct TagChip: View {
    @Environment(\.notebookTheme) private var theme
    let tag: String
    let scale: CGFloat
    let removable: Bool
    let onRemove: () -> Void
    @State private var hovering = false

    public init(tag: String, scale: CGFloat = 1, removable: Bool = true, onRemove: @escaping () -> Void) {
        self.tag = tag; self.scale = scale; self.removable = removable; self.onRemove = onRemove
    }

    public var body: some View {
        let armed = removable && hovering
        Button(action: onRemove) {
            Text("#" + tag)
                .font(.system(size: 11 * scale, design: .serif))
                .strikethrough(armed, color: theme.accent.color)
                .foregroundStyle(theme.accent.color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(theme.accent.color.opacity(armed ? 0.22 : 0.12)))
        }
        .buttonStyle(.plain)
        .disabled(!removable)
        .onHover { hovering = $0 }
        .help(removable ? "Remove #\(tag)" : "")
    }
}

/// A filter capsule ("All", "#tag", "Today"): accent when on, swelling while
/// something is dragged over it.
public struct FilterChip: View {
    @Environment(\.notebookTheme) private var theme
    let label: String
    let isOn: Bool
    let isTargeted: Bool
    let action: () -> Void

    public init(label: String, isOn: Bool, isTargeted: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.isOn = isOn; self.isTargeted = isTargeted; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: isOn || isTargeted ? .semibold : .regular, design: .serif))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(isOn || isTargeted ? theme.accent.color.opacity(isTargeted ? 0.32 : 0.2) : theme.ink.color.opacity(0.06)))
                .overlay(Capsule().stroke(isTargeted ? theme.accent.color : theme.ink.color.opacity(isOn ? 0.25 : 0.1),
                                          lineWidth: isTargeted ? 1.2 : 0.5))
                .scaleEffect(isTargeted ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

/// Pick or type a tag to add.
public struct TagPopover: View {
    let allTags: [String]
    let existing: [String]
    let onPick: (String) -> Void
    @State private var newTag = ""
    @FocusState private var focused: Bool

    @Environment(\.notebookTheme) private var theme

    public init(allTags: [String], existing: [String], onPick: @escaping (String) -> Void) {
        self.allTags = allTags; self.existing = existing; self.onPick = onPick
    }

    public var body: some View {
        PaperPopover {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Tag", text: $newTag)
                    .font(.system(size: 13, design: .serif))
                    .paperField().frame(width: 200)
                    .focused($focused)
                    .onSubmit { onPick(choices.first ?? newTag) }
                    .onKeyPress(.tab) {
                        guard let first = choices.first, first != typed else { return .ignored }
                        newTag = first; return .handled
                    }
                if !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(choices, id: \.self) { tag in
                            Button("#" + tag) { onPick(tag) }
                                .buttonStyle(.plain).font(.system(size: 12.5, design: .serif))
                                .foregroundStyle(theme.accent.color)
                        }
                    }
                } else if !typed.isEmpty {
                    Text("New tag #\(typed)").font(.system(size: 11, design: .serif)).foregroundStyle(theme.dimInk.color)
                }
            }
        }
        .onAppear { focused = true }
    }

    /// What has been typed, as a tag: no `#`, lowercased.
    private var typed: String {
        newTag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
    }

    /// Known tags starting with what was typed (all of them before typing), minus the row's own.
    private var choices: [String] {
        let t = typed
        return allTags.filter { !existing.contains($0) && (t.isEmpty || $0.hasPrefix(t)) }.prefix(8).map { $0 }
    }
}

/// Chips for the `#tag` being typed at the end of a field; click one to complete it.
public struct TagCompletionRow: View {
    @Environment(\.notebookTheme) private var theme
    @Binding var text: String
    let known: [String]

    public init(text: Binding<String>, known: [String]) {
        self._text = text; self.known = known
    }

    public var body: some View {
        if let partial = TagCompletion.partial(in: text) {
            let matches = TagCompletion.matches(for: partial.text, in: known)
            if !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { tag in
                        Button("#" + tag) { text = TagCompletion.completing(text, partial: partial, with: tag) }
                            .buttonStyle(.plain).font(.system(size: 11, design: .serif))
                            .foregroundStyle(theme.accent.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent.color.opacity(0.12)))
                    }
                    Text("⇥").font(.system(size: 10)).foregroundStyle(theme.dimInk.color)
                }
            }
        }
    }
}

public extension View {
    /// Tab completes the `#tag` being typed at the end of the field with the best match.
    func completesTags(in text: Binding<String>, known: [String]) -> some View {
        onKeyPress(.tab) {
            guard let partial = TagCompletion.partial(in: text.wrappedValue),
                  let first = TagCompletion.matches(for: partial.text, in: known).first else { return .ignored }
            text.wrappedValue = TagCompletion.completing(text.wrappedValue, partial: partial, with: first)
            return .handled
        }
    }
}

/// Wraps children onto new rows.
public struct FlowLayout: Layout {
    public var spacing: CGFloat

    public init(spacing: CGFloat = 6) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
