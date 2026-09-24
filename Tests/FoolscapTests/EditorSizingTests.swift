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

@Suite @MainActor struct RulingDrawTests {
    /// A scroll bouncing past the top asks for a rect wholly above the first rule;
    /// the ruling loop used to build `0...-3` there and trap.
    @Test func drawingAboveTheFirstRuleDoesNotTrap() throws {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("one\ntwo\n")
        for ruling in [Ruling.lined, .grid, .dotted] {
            let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: NotebookTheme.classicBlack.ruled(ruling, marginRule: true)))
            view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            view.draw(NSRect(x: 0, y: -400, width: 600, height: 20))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

@Suite @MainActor struct CaretSkipTests {
    @Test func caretStepsOverCollapsedImageLines() {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("one\n![pic](a.png)\nthree\n")          // lines at 0, 4, 18
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: 8, length: 0))   // click inside the image line, moving forward
        #expect(view.selectedRange().location == 18)             // start of "three"
        view.setSelectedRange(NSRange(location: 21, length: 0))
        view.setSelectedRange(NSRange(location: 10, length: 0))  // moving backward
        #expect(view.selectedRange().location == 3)              // end of "one"
        // Revealed from the badge: the caret may sit there.
        view.styler.forceReveal(line: 1)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        #expect(view.selectedRange().location == 8)
        // Leaving the line collapses it again.
        view.setSelectedRange(NSRange(location: 21, length: 0))
        #expect(view.styler.isCollapsed(line: 1))
    }
}
