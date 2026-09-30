import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// SwiftUI wrapper: a scrolling MarkdownTextView bound to one document.
public struct MarkdownEditor: NSViewRepresentable {
    let document: NoteDocument
    let revealLine: Int?
    /// Known tags, most used first, for `#` completion while typing.
    let tags: () -> [String]
    /// Laid under the note's opening heading, on the ruling (today's #today tasks).
    let header: AnyView?
    let onEdit: () -> Void
    @Environment(\.notebookTheme) private var theme

    public init(document: NoteDocument, revealLine: Int? = nil, tags: @escaping () -> [String] = { [] },
                header: AnyView? = nil, onEdit: @escaping () -> Void) {
        self.document = document
        self.revealLine = revealLine
        self.tags = tags
        self.header = header
        self.onEdit = onEdit
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    public func makeNSView(context: Context) -> NSScrollView {
        let palette = EditorPalette(theme: theme)
        let textView = MarkdownTextView(document: document, palette: palette)
        textView.knownTags = tags
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        // The hidden title bar reaches a couple of points past the leather onto the page;
        // left automatic, the inset it asks for drops the note's ruling below the other pages'.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        // The find bar (⌘F) lives under the page, away from the day navigator, in the theme's appearance.
        scroll.findBarPosition = .belowContent
        scroll.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.textView = textView
        updateHeader(textView)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let palette = EditorPalette(theme: theme)
        textView.knownTags = tags
        textView.palette.theme = theme
        updateHeader(textView)
        if palette.body != textView.palette.body || palette.ink != textView.palette.ink || palette.ruling != textView.palette.ruling
            || palette.showMarginRule != textView.palette.showMarginRule {
            textView.palette = palette
            textView.applyPalette()
            textView.restyleAll()
            // The header's room is counted in ruled lines, whose pitch may have changed.
            textView.refreshOverlays()
            scroll.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        }
        if let line = revealLine, context.coordinator.revealedLine != line {
            context.coordinator.revealedLine = line
            let map = textView.styler.blockMap
            if line < map.lines.count {
                let range = map.lines[line].range
                textView.styler.unfold(toReveal: line)
                DispatchQueue.main.async {
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
        // Keep the text view at least as tall as the visible page so ruling fills it.
        let visible = scroll.contentView.bounds.height
        if textView.minSize.height != visible {
            textView.minSize = NSSize(width: 0, height: visible)
            textView.needsLayout = true
        }
    }

    /// The header runs in a hosting view of its own, so it is handed the theme
    /// here; it reports its height, and the text view makes room for it.
    private func updateHeader(_ textView: MarkdownTextView) {
        guard let header else { textView.headerView = nil; textView.headerHeight = 0; return }
        let root = AnyView(header
            .environment(\.notebookTheme, theme)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak textView] height in
                // Not during the layout pass that measured it: reserving space restyles the text.
                DispatchQueue.main.async { textView?.headerHeight = height }
            }
            .frame(maxHeight: .infinity, alignment: .top))
        if let host = textView.headerView as? NSHostingView<AnyView> {
            host.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            textView.headerView = host
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var textView: MarkdownTextView?
        var revealedLine: Int?
        let onEdit: () -> Void
        init(onEdit: @escaping () -> Void) { self.onEdit = onEdit }

        public func textDidChange(_ notification: Notification) {
            onEdit()
        }

        public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let s = link as? String, let url = URL(string: s) { NSWorkspace.shared.open(url); return true }
            if let url = link as? URL { NSWorkspace.shared.open(url); return true }
            return false
        }
    }
}
