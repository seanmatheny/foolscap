import Testing
import AppKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapEditor

/// Markdown that takes effect while it is typed, before Return: bullets turn into dots at once,
/// a `---` line is drawn as a rule once the caret leaves it, and `[] ` makes a task.
@Suite @MainActor struct LiveFormattingTests {
    private func editor(_ text: String, caret: Int? = nil) -> (MarkdownTextView, NoteDocument) {
        let doc = NoteDocument(path: "Daily/2026-11-02.md", url: URL(fileURLWithPath: "/tmp/foolscap-unused.md"), day: DayKey("2026-11-02")!)
        doc.setText(text)
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        if let caret { view.setSelectedRange(NSRange(location: caret, length: 0)) }
        return (view, doc)
    }

    private func typeSpace(_ view: MarkdownTextView) {
        view.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: Bullets

    @Test func theDotShowsOnTheCaretsLineUnlessTheCaretTouchesTheDash() {
        let (view, _) = editor("- item\n", caret: 6)
        #expect(!view.styler.showsBulletMarker(line: 0))
        view.setSelectedRange(NSRange(location: 1, length: 0))   // between the dash and the space
        #expect(view.styler.showsBulletMarker(line: 0))
        view.setSelectedRange(NSRange(location: 0, length: 0))   // before the dash
        #expect(view.styler.showsBulletMarker(line: 0))
        view.setSelectedRange(NSRange(location: 2, length: 0))   // after the space
        #expect(!view.styler.showsBulletMarker(line: 0))
    }

    @Test func anIndentedBulletsDashIsNotTouchedFromTheLineStart() {
        let (view, _) = editor("  - item\n", caret: 0)
        #expect(!view.styler.showsBulletMarker(line: 0))
    }

    @Test func aTypedBulletIsADotAsSoonAsItsSpaceIsIn() {
        let (view, doc) = editor("", caret: 0)
        view.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        typeSpace(view)
        #expect(doc.text == "- ")
        guard case .listItem = view.styler.blockMap.lines[0].kind else { Issue.record("not a list item"); return }
        #expect(!view.styler.showsBulletMarker(line: 0))
        // The dash itself is clear, so only the drawn dot shows.
        let colour = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(colour?.alphaComponent == 0)
    }

    // MARK: Rules

    @Test func aRuleHidesItsDashesOffTheCaretAndShowsThemOnIt() {
        let (view, _) = editor("above\n---\nbelow\n", caret: 0)
        let hidden = view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect(hidden?.pointSize == 0.01)
        view.setSelectedRange(NSRange(location: 8, length: 0))
        let shown = view.textStorage?.attribute(.font, at: 7, effectiveRange: nil) as? NSFont
        #expect((shown?.pointSize ?? 0) > 1)
    }

    // MARK: Task shorthand

    @Test(arguments: [
        ("[]", "- [ ] "),
        ("[ ]", "- [ ] "),
        ("  []", "  - [ ] "),
        ("- []", "- [ ] "),
        ("* []", "* [ ] "),
        ("1. []", "1. [ ] "),
    ])
    func aSpaceAfterBracketsMakesATask(typed: String, expected: String) {
        let (view, doc) = editor(typed, caret: (typed as NSString).length)
        typeSpace(view)
        #expect(doc.text == expected)
        #expect(view.selectedRange() == NSRange(location: (expected as NSString).length, length: 0))
        // No title yet, so not a task to the index; the prefix is a task's and is styled as one.
        guard case .task(_, .notStarted)? = LinePrefix.parse(view.styler.blockMap.lines[0].text)?.kind else { Issue.record("not a task prefix"); return }
        let font = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.isFixedPitch == true)
    }

    @Test func bracketsTypedBeforeALineMakeItATask() {
        let (view, doc) = editor("[]buy milk\n", caret: 2)
        typeSpace(view)
        #expect(doc.text == "- [ ] buy milk\n")
        #expect(view.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test(arguments: ["- [ ]", "x []", "[x]", "a [] b"])
    func otherTextTakesAPlainSpace(typed: String) {
        let (view, doc) = editor(typed, caret: (typed as NSString).length)
        typeSpace(view)
        #expect(doc.text == typed + " ")
    }

    @Test func bracketsInACodeBlockStayAsTyped() {
        let text = "```\n[]\n```\n"
        let (view, doc) = editor(text, caret: 6)
        typeSpace(view)
        #expect(doc.text == "```\n[] \n```\n")
    }

    @Test func undoGivesBackTheBracketsAsTyped() {
        let (view, doc) = editor("[]", caret: 2)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.allowsUndo = true
        typeSpace(view)
        #expect(doc.text == "- [ ] ")
        view.undoManager?.undo()
        #expect(doc.text == "[]")
    }

    // MARK: Leaving a code block

    private func typeMark(_ view: MarkdownTextView, _ mark: String = "`") {
        view.insertText(mark, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func theClosingFenceTypedAtTheNotesEndLeavesTheBlock() {
        let (view, doc) = editor("```\nlet a = 1\n``", caret: 16)
        typeMark(view)
        #expect(doc.text == "```\nlet a = 1\n```\n")
        #expect(view.selectedRange() == NSRange(location: 18, length: 0))
        #expect(view.styler.blockMap.lines.map(\.kind) == [.fenceOpen(language: ""), .fenceInside, .fenceClose, .blank])
    }

    @Test func theClosingFenceLandsOnTheBlankLineAlreadyUnderIt() {
        let (view, doc) = editor("```\ncode\n``\n\nafter", caret: 11)
        typeMark(view)
        #expect(doc.text == "```\ncode\n```\n\nafter")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
    }

    @Test func theClosingFenceMakesALineAboveTextThatFollows() {
        let (view, doc) = editor("```\ncode\n``\nafter", caret: 11)
        typeMark(view)
        #expect(doc.text == "```\ncode\n```\n\nafter")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
    }

    /// The Format command writes both fences; the lower one is hidden, so it gets typed again.
    @Test func aClosingFenceTypedOverTheBlocksOwnIsTakenBack() {
        let (view, doc) = editor("```\ncode\n\n```", caret: 9)
        typeMark(view); typeMark(view)
        #expect(doc.text == "```\ncode\n``\n```")
        typeMark(view)
        #expect(doc.text == "```\ncode\n```\n")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
        #expect(view.styler.blockMap.lines.map(\.kind) == [.fenceOpen(language: ""), .fenceInside, .fenceClose, .blank])
    }

    @Test func anOpeningFenceAndBackticksInCodeStayAsTyped() {
        let (v1, d1) = editor("``", caret: 2)
        typeMark(v1)
        #expect(d1.text == "```")
        #expect(v1.selectedRange() == NSRange(location: 3, length: 0))
        // Not at the line's end, and not the fence's own mark.
        let (v2, d2) = editor("```\n``x\n```\n", caret: 6)
        typeMark(v2)
        #expect(d2.text == "```\n```x\n```\n")
        let (v3, d3) = editor("```\n~~\n", caret: 6)
        typeMark(v3, "~")
        #expect(d3.text == "```\n~~~\n")
    }

    @Test func aTildeFenceClosesWithTildes() {
        let (view, doc) = editor("~~~\ncode\n~~", caret: 11)
        typeMark(view, "~")
        #expect(doc.text == "~~~\ncode\n~~~\n")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
    }

    @Test func returnOnTheClosingFenceOpensALineUnderIt() {
        let (view, doc) = editor("```\ncode\n```\nafter", caret: 9)   // at the fence's start
        view.insertNewline(nil)
        #expect(doc.text == "```\ncode\n```\n\nafter")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
    }

    @Test func downOnAClosingFenceThatEndsTheNoteMakesALine() {
        let (view, doc) = editor("```\ncode\n```", caret: 10)
        view.moveDown(nil)
        #expect(doc.text == "```\ncode\n```\n")
        #expect(view.selectedRange() == NSRange(location: 13, length: 0))
        // With a line there already, nothing is added.
        view.setSelectedRange(NSRange(location: 12, length: 0))
        view.moveRight(nil)
        #expect(doc.text == "```\ncode\n```\n")
    }

    @Test func theFormatCommandsBlockAtTheNotesEndHasALineAfterIt() {
        let (view, doc) = editor("", caret: 0)
        view.toggleCodeBlock(nil)
        #expect(doc.text == "```\n\n```\n")
        #expect(view.selectedRange() == NSRange(location: 4, length: 0))
    }
}
