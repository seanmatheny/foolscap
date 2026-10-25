import Testing
import AppKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapEditor

/// A picture or link card line cannot hold the caret, so the delete keys beside it take the
/// whole line rather than joining it to its neighbour.
@Suite @MainActor struct PictureRemovalTests {
    private func editor(_ text: String) -> (MarkdownTextView, NoteDocument) {
        let day = DayKey("2026-09-22")!
        let doc = NoteDocument(path: "Daily/2026-09-22.md", url: URL(fileURLWithPath: "/tmp/foolscap-unused.md"), day: day)
        doc.setText(text)
        return (MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack)), doc)
    }

    @Test func backspaceUnderAPictureRemovesItsLine() {
        let image = "![pic](../Attachments/x.png)"
        let (view, doc) = editor("# Day\n\n\(image)\nafter\n")
        view.setSelectedRange(NSRange(location: 7 + image.count + 1, length: 0))   // the start of "after"
        view.deleteBackward(nil)
        #expect(doc.text == "# Day\n\nafter\n")
        #expect(view.selectedRange() == NSRange(location: 7, length: 0))
    }

    @Test func forwardDeleteAboveAPictureRemovesItsLine() {
        let (view, doc) = editor("# Day\n\n![pic](../Attachments/x.png)\nafter\n")
        view.setSelectedRange(NSRange(location: 6, length: 0))   // the end of the blank line
        view.deleteForward(nil)
        #expect(doc.text == "# Day\n\nafter\n")
        #expect(view.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test func aPictureEndingTheNoteGoesWithTheNewlineBeforeIt() {
        let (view, doc) = editor("# Day\n![pic](../Attachments/x.png)")
        view.setSelectedRange(NSRange(location: 5, length: 0))   // the end of the heading
        view.deleteForward(nil)
        #expect(doc.text == "# Day")
    }

    @Test func backspaceElsewhereIsOrdinary() {
        let (view, doc) = editor("# Day\n\n![pic](../Attachments/x.png)\nafter\n")
        view.setSelectedRange(NSRange(location: 5, length: 0))   // the end of the heading
        view.deleteBackward(nil)
        #expect(doc.text == "# Da\n\n![pic](../Attachments/x.png)\nafter\n")
    }
}
