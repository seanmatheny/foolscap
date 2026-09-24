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
    let onEdit: () -> Void
    @Environment(\.notebookTheme) private var theme

    public init(document: NoteDocument, revealLine: Int? = nil, tags: @escaping () -> [String] = { [] }, onEdit: @escaping () -> Void) {
        self.document = document
        self.revealLine = revealLine
        self.tags = tags
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
        // The find bar (⌘F) lives under the page, away from the day navigator, in the theme's appearance.
        scroll.findBarPosition = .belowContent
        scroll.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        scroll.documentView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.textView = textView
        context.coordinator.scrollView = scroll
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    public func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let palette = EditorPalette(theme: theme)
        textView.knownTags = tags
        if palette.body != textView.palette.body || palette.ink != textView.palette.ink || palette.ruling != textView.palette.ruling
            || palette.showMarginRule != textView.palette.showMarginRule {
            textView.palette = palette
            textView.applyPalette()
            textView.restyleAll()
            scroll.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        }
        if let line = revealLine, context.coordinator.revealedLine != line {
            context.coordinator.revealedLine = line
            let map = textView.styler.blockMap
            if line < map.lines.count {
                let range = map.lines[line].range
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

    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        var textView: MarkdownTextView?
        var scrollView: NSScrollView?
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
