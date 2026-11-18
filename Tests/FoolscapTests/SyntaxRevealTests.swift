import Testing
import AppKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapEditor

/// Markdown syntax hides the moment a construct is complete and shows only while the caret
/// touches the markers themselves; a picture or card is a block the caret rests on; ⌫ after a
/// marker takes the marker off; an opening fence closes itself.
@Suite @MainActor struct SyntaxRevealTests {
    private func editor(_ text: String, caret: Int? = nil) -> (MarkdownTextView, NoteDocument) {
        let doc = NoteDocument(path: "Daily/2026-11-18.md", url: URL(fileURLWithPath: "/tmp/foolscap-unused.md"), day: DayKey("2026-11-18")!)
        doc.setText(text)
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        if let caret { view.setSelectedRange(NSRange(location: caret, length: 0)) }
        return (view, doc)
    }

    private func hidden(_ view: MarkdownTextView, at offset: Int) -> Bool {
        let font = view.textStorage?.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
        return font?.pointSize == 0.01
    }

    private func type(_ view: MarkdownTextView, _ text: String) {
        for ch in text { view.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    // MARK: Headings, quotes and rules

    @Test func headingHashesHideAsTheTitleIsTypedAndShowAtTheLineStart() {
        let (view, doc) = editor("", caret: 0)
        type(view, "## T")
        #expect(doc.text == "## T")
        #expect(hidden(view, at: 0))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!hidden(view, at: 0))
        view.setSelectedRange(NSRange(location: 3, length: 0))   // just after the marker
        #expect(!hidden(view, at: 0))
        view.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(hidden(view, at: 0))
    }

    @Test func aQuotesMarkHidesBehindItsText() {
        let (view, _) = editor("> quoted\n", caret: 8)
        #expect(hidden(view, at: 0))
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!hidden(view, at: 0))
    }

    @Test func aRuleDrawsAsSoonAsItIsTypedAndShowsItsDashesOnlyInsideThem() {
        let (view, doc) = editor("", caret: 0)
        type(view, "---")
        // The third dash completes the rule and puts the caret on a new line under it.
        #expect(doc.text == "---\n")
        #expect(view.selectedRange() == NSRange(location: 4, length: 0))
        #expect(hidden(view, at: 0))
        #expect(!view.styler.showsRuleMarks(line: 0))
        view.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!hidden(view, at: 0))
        #expect(view.styler.showsRuleMarks(line: 0))
    }

    @Test func aRuleTypedAboveTextGoesUnderItAndStarsDoNot() {
        let (view, doc) = editor("\nbelow", caret: 0)
        type(view, "---")
        #expect(doc.text == "---\n\nbelow")
        #expect(view.selectedRange() == NSRange(location: 4, length: 0))
        type(view, "-")   // a fourth dash on the new line is a plain dash
        #expect(doc.text == "---\n-\nbelow")
        let (v2, d2) = editor("", caret: 0)
        type(v2, "***")
        #expect(d2.text == "***")
        let (v3, d3) = editor("", caret: 0)
        type(v3, "- - -")
        #expect(d3.text == "- - -\n")
    }

    @Test func anEditNamesItsLinesForARedraw() {
        let (view, doc) = editor("- a\n  - ", caret: 8)
        _ = view.styler.takeEditedLines()
        view.insertNewline(nil)
        #expect(doc.text == "- a\n- ")
        // didChangeText took them for the redraw; a further edit names its line again.
        #expect(view.styler.takeEditedLines().isEmpty)
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.styler.takeEditedLines().isEmpty)
    }

    // MARK: Inline spans

    @Test func boldFoldsUpOnTheKeystrokeThatCompletesIt() {
        let (view, doc) = editor("", caret: 0)
        type(view, "**bold*")
        #expect(!hidden(view, at: 0))
        type(view, "*")
        #expect(doc.text == "**bold**")
        #expect(hidden(view, at: 0) && hidden(view, at: 6))
        let font = view.textStorage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        // Stepping into the word brings the asterisks back; at either edge they stay hidden.
        view.setSelectedRange(NSRange(location: 4, length: 0))
        #expect(!hidden(view, at: 0) && !hidden(view, at: 6))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(hidden(view, at: 0))
    }

    @Test func italicCodeAndLinksBehaveTheSame() {
        let (view, _) = editor("*it* and `code` and [docs](https://x.y)\n", caret: 40)
        #expect(hidden(view, at: 0) && hidden(view, at: 3))
        #expect(hidden(view, at: 9) && hidden(view, at: 14))
        #expect(hidden(view, at: 20) && hidden(view, at: 25))
        view.setSelectedRange(NSRange(location: 22, length: 0))   // inside "docs"
        #expect(!hidden(view, at: 20) && !hidden(view, at: 25))
        #expect(hidden(view, at: 0))
    }

    @Test func aSelectionAcrossASpanRevealsIt() {
        let (view, _) = editor("a **b** c\n")
        view.setSelectedRange(NSRange(location: 0, length: 9))
        #expect(!hidden(view, at: 2))
    }

    @Test func highlightIsASpan() {
        let kinds = InlineTokenizer.tokenize("a ==marked== b and a == b").map(\.kind)
        #expect(kinds == [.highlight])
        let (view, _) = editor("==marked==\n", caret: 11)
        #expect(hidden(view, at: 0))
        let bg = view.textStorage?.attribute(.backgroundColor, at: 3, effectiveRange: nil) as? NSColor
        #expect(bg != nil && bg != .clear)
        view.setSelectedRange(NSRange(location: 4, length: 0))
        view.toggleHighlight(nil)
        #expect(view.string == "marked\n")
    }

    // MARK: Backspace on a marker

    @Test(arguments: [
        ("- item", 2, "item", 0),
        ("1. item", 3, "item", 0),
        ("- [ ] item", 6, "item", 0),
        ("> item", 2, "item", 0),
        ("## Title", 3, "Title", 0),
        ("  - item", 4, "- item", 2),
    ])
    func backspaceJustAfterAMarkerTakesItOff(text: String, caret: Int, expected: String, caretAfter: Int) {
        let (view, doc) = editor(text, caret: caret)
        view.deleteBackward(nil)
        #expect(doc.text == expected)
        #expect(view.selectedRange() == NSRange(location: caretAfter, length: 0))
    }

    @Test func backspaceElsewhereOnAnItemIsOrdinary() {
        let (view, doc) = editor("- item", caret: 3)
        view.deleteBackward(nil)
        #expect(doc.text == "- tem")
        let (v2, d2) = editor("- item", caret: 1)
        v2.deleteBackward(nil)
        #expect(d2.text == " item")
    }

    // MARK: Lists

    @Test func returnOnAnEmptyNestedTaskOrTabbedItemStepsOut() {
        let (v1, d1) = editor("- [ ] a\n  - [ ] ", caret: 16)
        v1.insertNewline(nil)
        #expect(d1.text == "- [ ] a\n- [ ] ")
        let (v2, d2) = editor("- a\n\t- ", caret: 7)
        v2.insertNewline(nil)
        #expect(d2.text == "- a\n- ")
        let (v3, d3) = editor("1. a\n  1. ", caret: 10)
        v3.insertNewline(nil)
        #expect(d3.text == "1. a\n2. ")
    }

    @Test func returnBeforeASpaceSplitsAnItemCleanly() {
        let (view, doc) = editor("- one two", caret: 5)
        view.insertNewline(nil)
        #expect(doc.text == "- one\n- two")
        #expect(view.selectedRange() == NSRange(location: 8, length: 0))
    }

    // MARK: Code blocks

    @Test func returnOnAFreshFenceClosesTheBlock() {
        let (view, doc) = editor("```swift", caret: 8)
        view.insertNewline(nil)
        #expect(doc.text == "```swift\n\n```\n")
        #expect(view.selectedRange() == NSRange(location: 9, length: 0))
        #expect(view.styler.blockMap.lines.map(\.kind) == [.fenceOpen(language: "swift"), .fenceInside, .fenceClose, .blank])
    }

    @Test func aFreshFenceAboveAnotherBlockClosesItself() {
        let (view, doc) = editor("```\ntext\n```\ncode\n```\n", caret: 3)
        view.insertNewline(nil)
        #expect(doc.text == "```\n\n```\ntext\n```\ncode\n```\n")
    }

    @Test func returnOnAnOpeningFenceOfAClosedBlockIsAPlainNewline() {
        let (view, doc) = editor("```\ncode\n```\n", caret: 3)
        view.insertNewline(nil)
        #expect(doc.text == "```\n\ncode\n```\n")
    }

    // MARK: Pictures and cards as blocks

    static let cards = "A\nhttps://x.example\nhttps://y.example\nC"
    // Line ends: A 1, x 19, y 37, C 39.

    @Test func theCaretStopsAtTheEndOfEachCard() {
        let (view, _) = editor(Self.cards, caret: 1)
        view.setSelectedRange(NSRange(location: 2, length: 0))    // onto the first card from above
        #expect(view.selectedRange().location == 19)
        #expect(view.blockUnderCaret?.index == 1)
        #expect(view.overlays.selectedOverlay?.lineIndex == 1)
        view.setSelectedRange(NSRange(location: 20, length: 0))   // down onto the second
        #expect(view.selectedRange().location == 37)
        view.setSelectedRange(NSRange(location: 36, length: 0))   // ← from the second card's end
        #expect(view.selectedRange().location == 19)
        view.setSelectedRange(NSRange(location: 18, length: 0))   // ← again: the line above the cards
        #expect(view.selectedRange().location == 1)
        view.setSelectedRange(NSRange(location: 38, length: 0))
        view.setSelectedRange(NSRange(location: 25, length: 0))   // up from C onto the second card
        #expect(view.selectedRange().location == 37)
        view.setSelectedRange(NSRange(location: 38, length: 0))
        #expect(view.overlays.selectedOverlay == nil)
    }

    @Test func returnAndTypingOnACardGoUnderIt() {
        let (view, doc) = editor(Self.cards, caret: 1)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.insertNewline(nil)
        #expect(doc.text == "A\nhttps://x.example\n\nhttps://y.example\nC")
        #expect(view.selectedRange() == NSRange(location: 20, length: 0))
        view.setSelectedRange(NSRange(location: 21, length: 0))   // onto the second card
        #expect(view.selectedRange().location == 38)
        type(view, "hi")
        #expect(doc.text == "A\nhttps://x.example\n\nhttps://y.example\nhi\nC")
        #expect(view.selectedRange() == NSRange(location: 41, length: 0))
    }

    @Test func deleteOnACardRemovesItAndLandsOnTheNext() {
        let (view, doc) = editor(Self.cards, caret: 1)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.deleteBackward(nil)
        #expect(doc.text == "A\nhttps://y.example\nC")
        #expect(view.selectedRange().location == 19)   // the next card, now selected
        view.deleteForward(nil)
        #expect(doc.text == "A\nC")
        #expect(view.selectedRange().location == 2)
    }

    @Test func aNoteEndingOnACardTakesReturnAfterIt() {
        let (view, doc) = editor("A\nhttps://x.example", caret: 1)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(view.selectedRange().location == 19)
        view.insertNewline(nil)
        #expect(doc.text == "A\nhttps://x.example\n")
        #expect(view.selectedRange().location == 20)
    }
}
