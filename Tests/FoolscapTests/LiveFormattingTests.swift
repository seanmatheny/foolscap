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
}
