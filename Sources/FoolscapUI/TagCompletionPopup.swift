import SwiftUI
import FoolscapCore

/// The `#tag` suggestions offered while a tag is typed: the list and its state
/// are shared; the Mac shows them in a child panel under the caret
/// (`TagCompletionPopup`), the phone will in a bar above the keyboard.
@MainActor @Observable
public final class TagCompletionModel {
    public var tags: [String] = []
    public var selection = 0
    public var theme: NotebookTheme = .classicBlack
    @ObservationIgnored public var pick: (String) -> Void = { _ in }

    public init() {}

    public var selectedTag: String? {
        tags.indices.contains(selection) ? tags[selection] : nil
    }

    /// Offer `tags`, keeping the highlighted one if it is still there.
    public func offer(_ tags: [String], theme: NotebookTheme, pick: @escaping (String) -> Void) {
        let previous = selectedTag
        self.tags = tags
        selection = previous.flatMap { tags.firstIndex(of: $0) } ?? 0
        self.theme = theme
        self.pick = pick
    }

    public func move(_ delta: Int) {
        let n = tags.count
        guard n > 0 else { return }
        selection = (selection + delta + n) % n
    }
}

public enum TagCompletionMetrics {
    public static let rowHeight: CGFloat = 24
    public static let width: CGFloat = 220
}

public struct TagCompletionList: View {
    @Bindable var model: TagCompletionModel

    public init(model: TagCompletionModel) { self.model = model }

    public var body: some View {
        let theme = model.theme
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.tags.enumerated()), id: \.element) { i, tag in
                let selected = i == model.selection
                Text("#" + tag)
                    .font(theme.type.body.face(13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? theme.ink.color : theme.accent.color)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: TagCompletionMetrics.rowHeight, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selected ? theme.accent.color.opacity(0.18) : .clear).padding(.horizontal, 4))
                    .contentShape(Rectangle())
                    .onTapGesture { model.pick(tag) }
            }
        }
        .padding(.vertical, 4)
        .frame(width: TagCompletionMetrics.width, alignment: .leading)
        .background(
            ZStack {
                theme.page.paperColor.color
                TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity, blend: theme.page.textureBlend)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.ink.color.opacity(0.2), lineWidth: 0.5))
        .environment(\.notebookTheme, theme)
        .colorScheme(theme.isDark ? .dark : .light)
    }
}

#if canImport(AppKit)
import AppKit

/// The suggestions shown under the caret, drawn on the theme's paper like the
/// search palette (the system completion list only follows the system
/// appearance). A borderless child window that never takes key status, so the
/// text keeps the caret; the owner forwards ↑/↓, Return, Tab and Escape to it.
@MainActor
public final class TagCompletionPopup {
    /// A panel that stays out of the key-window chain.
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static let rowHeight = TagCompletionMetrics.rowHeight
    static let width = TagCompletionMetrics.width

    private let model = TagCompletionModel()
    private var panel: Panel?

    public init() {}

    public var isVisible: Bool { panel?.isVisible == true }

    public var selectedTag: String? { model.selectedTag }

    /// Show `tags` under `anchor` (a screen rect, usually the typed `#tag`),
    /// keeping the highlighted tag if it is still offered.
    public func show(tags: [String], theme: NotebookTheme, below anchor: NSRect, in parent: NSWindow,
                     pick: @escaping (String) -> Void) {
        model.offer(tags, theme: theme, pick: pick)
        let panel = self.panel ?? makePanel()
        let size = NSSize(width: Self.width, height: CGFloat(tags.count) * Self.rowHeight + 8)
        // Under the tag, its text lined up with the list's; above it near the screen's foot.
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - size.height - 4)
        if let screen = parent.screen ?? NSScreen.main, origin.y < screen.visibleFrame.minY {
            origin.y = anchor.maxY + 4
        }
        panel.level = parent.level
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    public func move(_ delta: Int) { model.move(delta) }

    public func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.contentView = NSHostingView(rootView: TagCompletionList(model: model))
        self.panel = panel
        return panel
    }
}
#endif
