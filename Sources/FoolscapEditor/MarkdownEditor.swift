import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// SwiftUI wrapper: a scrolling MarkdownTextView bound to one document.
public struct MarkdownEditor: NSViewRepresentable {
    let document: NoteDocument
    let onEdit: () -> Void
    @Environment(\.notebookTheme) private var theme

    public init(document: NoteDocument, onEdit: @escaping () -> Void) {
        self.document = document
        self.onEdit = onEdit
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    public func makeNSView(context: Context) -> NSScrollView {
        let palette = EditorPalette(theme: theme)
        let textView = MarkdownTextView(document: document, palette: palette)
        textView.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
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
        if palette.body != textView.palette.body || palette.ink != textView.palette.ink || palette.ruling != textView.palette.ruling {
            textView.palette = palette
            textView.applyPalette()
            textView.restyleAll()
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
