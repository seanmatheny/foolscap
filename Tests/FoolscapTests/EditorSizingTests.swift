import Testing
import AppKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapEditor

@Suite @MainActor struct EditorSizingTests {
    @Test func textViewGrowsBeyondTheVisibleHeight() {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText((1...120).map { "Line \($0)" }.joined(separator: "\n"))
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scroll.documentView = view
        view.minSize = NSSize(width: 0, height: 200)
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.sizeToFit()
        #expect(view.frame.height > 1000, "frame height was \(view.frame.height)")
    }
}
