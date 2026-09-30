import Testing
import AppKit
import UniformTypeIdentifiers
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapEditor

@MainActor
private func makeView(_ text: String, caret: Int? = nil) -> (MarkdownTextView, NoteDocument) {
    let doc = NoteDocument(path: "Daily/2026-09-30.md", url: URL(fileURLWithPath: "/nonexistent/Daily/2026-09-30.md"), day: DayKey("2026-09-30"))
    doc.setText(text)
    // Folds are remembered per note: each test view gets a fresh, empty memory.
    FoldMemory.defaults = UserDefaults(suiteName: "foolscap-editor-tests-\(UUID().uuidString)")!
    let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    if let caret { view.setSelectedRange(NSRange(location: caret, length: 0)) }
    return (view, doc)
}

@Suite struct LinePrefixTests {
    @Test func parsesBulletsNumbersTasksAndQuotes() {
        #expect(LinePrefix.parse("- milk") == LinePrefix.Parsed(indent: "", kind: .bullet("-"), length: 2))
        #expect(LinePrefix.parse("  * milk") == LinePrefix.Parsed(indent: "  ", kind: .bullet("*"), length: 4))
        #expect(LinePrefix.parse("3. milk") == LinePrefix.Parsed(indent: "", kind: .numbered(3, "."), length: 3))
        #expect(LinePrefix.parse("- [ ] call Bob") == LinePrefix.Parsed(indent: "", kind: .task(bullet: "-", status: .notStarted), length: 6))
        #expect(LinePrefix.parse("- [x]") == LinePrefix.Parsed(indent: "", kind: .task(bullet: "-", status: .completed), length: 5))
        #expect(LinePrefix.parse("> quoted") == LinePrefix.Parsed(indent: "", kind: .quote, length: 2))
        #expect(LinePrefix.parse("plain") == nil)
        #expect(LinePrefix.parse("-milk") == nil)
        // `- [ ]foo` is a bullet whose text starts with brackets, as the block map reads it.
        #expect(LinePrefix.parse("- [ ]foo")?.kind == .bullet("-"))
    }

    @Test func continuationsAdvanceNumbersAndUntickTasks() {
        #expect(LinePrefix.continuation(of: LinePrefix.parse("3) x")!) == "4) ")
        #expect(LinePrefix.continuation(of: LinePrefix.parse("  - [x] x")!) == "  - [ ] ")
        #expect(LinePrefix.continuation(of: LinePrefix.parse("> x")!) == "> ")
        #expect(LinePrefix.outdented("    ") == "  ")
        #expect(LinePrefix.outdented("\t  ") == "  ")
        #expect(LinePrefix.outdented(" ") == "")
    }
}

@Suite @MainActor struct ListEditingTests {
    @Test func returnContinuesAList() {
        let (view, doc) = makeView("- one", caret: 5)
        view.insertNewline(nil)
        #expect(doc.text == "- one\n- ")
        #expect(view.selectedRange().location == 8)
    }

    @Test func returnOnAnEmptyItemEndsTheList() {
        let (view, doc) = makeView("- one\n- ", caret: 8)
        view.insertNewline(nil)
        #expect(doc.text == "- one\n")
        #expect(view.selectedRange().location == 6)
    }

    @Test func returnOnAnEmptyNestedItemStepsOut() {
        let (view, doc) = makeView("- one\n  - ", caret: 10)
        view.insertNewline(nil)
        #expect(doc.text == "- one\n- ")
        #expect(view.selectedRange().location == 8)
    }

    @Test func returnContinuesNumbersTasksAndQuotes() {
        let (v1, d1) = makeView("1. a", caret: 4); v1.insertNewline(nil); #expect(d1.text == "1. a\n2. ")
        let (v2, d2) = makeView("- [x] a", caret: 7); v2.insertNewline(nil); #expect(d2.text == "- [x] a\n- [ ] ")
        let (v3, d3) = makeView("> a", caret: 3); v3.insertNewline(nil); #expect(d3.text == "> a\n> ")
    }

    @Test func returnInsideThePrefixOrMidLineBehavesNormally() {
        let (v1, d1) = makeView("- one two", caret: 0); v1.insertNewline(nil); #expect(d1.text == "\n- one two")
        let (v2, d2) = makeView("- one two", caret: 5); v2.insertNewline(nil); #expect(d2.text == "- one\n-  two")
    }

    @Test func tabIndentsAndOutdentsListLines() {
        let (view, doc) = makeView("- one\n- two\nplain", caret: 8)
        view.insertTab(nil)
        #expect(doc.text == "- one\n  - two\nplain")
        #expect(view.selectedRange().location == 10)
        view.insertBacktab(nil)
        #expect(doc.text == "- one\n- two\nplain")
        #expect(view.selectedRange().location == 8)
        // Plain lines still take a tab character.
        view.setSelectedRange(NSRange(location: 17, length: 0))
        view.insertTab(nil)
        #expect(doc.text == "- one\n- two\nplain\t")
    }
}

@Suite @MainActor struct FormatCommandTests {
    @Test func boldWrapsAndUnwrapsTheSelection() {
        let (view, doc) = makeView("hello world")
        view.setSelectedRange(NSRange(location: 6, length: 5))
        view.toggleBold(nil)
        #expect(doc.text == "hello **world**")
        #expect(view.selectedRange() == NSRange(location: 8, length: 5))
        view.toggleBold(nil)
        #expect(doc.text == "hello world")
        #expect(view.selectedRange() == NSRange(location: 6, length: 5))
    }

    @Test func boldOnACaretTakesTheWord() {
        let (view, doc) = makeView("hello world", caret: 8)
        view.toggleBold(nil)
        #expect(doc.text == "hello **world**")
        let (v2, d2) = makeView("hello ", caret: 6)
        v2.toggleItalic(nil)
        #expect(d2.text == "hello **")
        #expect(v2.selectedRange().location == 7)
    }

    @Test func headingsSetAndClear() {
        let (view, doc) = makeView("title\nbody", caret: 2)
        view.heading2(nil)
        #expect(doc.text == "## title\nbody")
        view.heading2(nil)
        #expect(doc.text == "title\nbody")
        view.heading1(nil)
        view.heading3(nil)
        #expect(doc.text == "### title\nbody")
    }

    @Test func listsToggleAcrossASelection() {
        let (view, doc) = makeView("a\nb\n\nc")
        view.setSelectedRange(NSRange(location: 0, length: 6))
        view.toggleBulletList(nil)
        #expect(doc.text == "- a\n- b\n\n- c")
        view.toggleNumberedList(nil)
        #expect(doc.text == "1. a\n2. b\n\n3. c")
        view.toggleTask(nil)
        #expect(doc.text == "- [ ] a\n- [ ] b\n\n- [ ] c")
        view.toggleTask(nil)
        #expect(doc.text == "a\nb\n\nc")
    }

    @Test func taskDoneTogglesOrMakesATask() {
        let (view, doc) = makeView("- [ ] call", caret: 8)
        view.toggleTaskDone(nil)
        #expect(doc.text == "- [x] call")
        view.toggleTaskDone(nil)
        #expect(doc.text == "- [ ] call")
        let (v2, d2) = makeView("call", caret: 2)
        v2.toggleTaskDone(nil)
        #expect(d2.text == "- [ ] call")
    }

    @Test func quoteAndCodeBlock() {
        let (view, doc) = makeView("a\nb")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.toggleQuote(nil)
        #expect(doc.text == "> a\n> b")
        view.toggleQuote(nil)
        #expect(doc.text == "a\nb")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.toggleCodeBlock(nil)
        #expect(doc.text == "```\na\nb\n```")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.toggleCodeBlock(nil)
        #expect(doc.text == "a\nb")
    }

    @Test func linkUsesAClipboardAddress() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("https://example.com/x", forType: .string)
        let (view, doc) = makeView("see docs", caret: 6)
        view.insertLink(nil)
        #expect(doc.text == "see [docs](https://example.com/x)")
    }
}

@Suite @MainActor struct FoldingTests {
    static let note = """
    # Day

    ## Morning
    - a
    - b

    ## Afternoon
    text
    ### Later
    more
    """

    @Test func sectionsRunToTheNextHeadingOfTheSameLevel() {
        let map = BlockMap.scan(Self.note)
        #expect(MarkdownStyler.sectionEnd(afterHeading: 0, in: map) == map.lines.count)
        #expect(MarkdownStyler.sectionEnd(afterHeading: 2, in: map) == 6)   // Morning: lines 3-5
        #expect(MarkdownStyler.sectionEnd(afterHeading: 6, in: map) == map.lines.count)
        #expect(MarkdownStyler.sectionEnd(afterHeading: 8, in: map) == map.lines.count)
    }

    @Test func foldingHidesLinesAndShrinksTheLayout() {
        let (view, _) = makeView(Self.note)
        let tlm = view.textLayoutManager!
        tlm.ensureLayout(for: tlm.documentRange)
        let open = tlm.usageBoundsForTextContainer.height
        view.styler.setFolded(true, heading: 2)
        #expect(view.styler.isFolded(heading: 2))
        #expect(view.styler.hiddenLines == [3, 4, 5])
        tlm.ensureLayout(for: tlm.documentRange)
        let folded = tlm.usageBoundsForTextContainer.height
        let pitch = view.palette.pitch
        // Three lines gone: the page is three ruled lines shorter, give or take a hair.
        #expect(abs((open - folded) - 3 * pitch) < 1, "open \(open) folded \(folded) pitch \(pitch)")
        view.styler.setFolded(false, heading: 2)
        #expect(view.styler.hiddenLines.isEmpty)
    }

    @Test func caretStepsOverAFoldedSection() {
        let (view, _) = makeView(Self.note)
        view.styler.setFolded(true, heading: 2)
        let lines = view.styler.blockMap.lines
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.setSelectedRange(NSRange(location: lines[4].range.location + 1, length: 0))   // into "- b", moving forward
        #expect(view.selectedRange().location == lines[6].range.location)                 // start of "## Afternoon"
        view.setSelectedRange(NSRange(location: lines[7].range.location, length: 0))
        view.setSelectedRange(NSRange(location: lines[3].range.location, length: 0))       // moving backward
        #expect(view.selectedRange().location == lines[2].range.location + lines[2].range.length)   // end of "## Morning"
    }

    @Test func foldsFollowEditsAboveThemAndRevealsOpenThem() {
        let (view, doc) = makeView(Self.note)
        view.styler.setFolded(true, heading: 2)
        // A line typed above: the same section stays hidden, one line down.
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertText("\nnew", replacementRange: NSRange(location: 5, length: 0))
        #expect(doc.text.hasPrefix("# Day\nnew\n"))
        #expect(view.styler.hiddenLines == [4, 5, 6])
        view.styler.unfold(toReveal: 5)
        #expect(view.styler.hiddenLines.isEmpty)
        #expect(!view.styler.isFolded(heading: 3))
    }

    @Test func returnOnAFoldedHeadingWritesBelowTheSection() {
        let (view, doc) = makeView(Self.note)
        view.styler.setFolded(true, heading: 2)
        let heading = view.styler.blockMap.lines[2].range
        view.setSelectedRange(NSRange(location: heading.location + heading.length, length: 0))
        view.insertNewline(nil)
        #expect(doc.text.contains("- b\n\n\n## Afternoon"))
        #expect(view.styler.isFolded(heading: 2))
    }

    @Test func foldStateIsRememberedPerNote() {
        let defaults = UserDefaults(suiteName: "foolscap-fold-tests-\(UUID().uuidString)")!
        FoldMemory.save(["## Morning"], for: "Daily/a.md", defaults: defaults)
        #expect(FoldMemory.folded(for: "Daily/a.md", defaults: defaults) == ["## Morning"])
        #expect(FoldMemory.folded(for: "Daily/b.md", defaults: defaults).isEmpty)
        FoldMemory.save([], for: "Daily/a.md", defaults: defaults)
        #expect(defaults.object(forKey: FoldMemory.key) == nil)
    }
}

@Suite @MainActor struct ImageCopyTests {
    @Test func copyingAPicturePutsItsFileOnTheClipboard() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let day = DayKey("2026-09-30")!
        let dir = folder.attachmentsDirectory(for: day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 6, height: 4), flipped: false) { r in NSColor.blue.setFill(); r.fill(); return true }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: dir.appendingPathComponent("pic.png"))

        let doc = NoteDocument(path: "Daily/2026-09-30.md", url: folder.url(for: day), day: day)
        doc.setText("# Day\n![pic](../Attachments/2026-09-30/pic.png)\n")
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        #expect(view.overlays.copyImage(path: "../Attachments/2026-09-30/pic.png"))

        let pb = NSPasteboard.general
        #expect(pb.data(forType: .png) == png)
        #expect(pb.data(forType: .tiff) != nil)
        let url = pb.string(forType: .fileURL).flatMap { URL(string: $0) }
        #expect(url?.lastPathComponent == "pic.png")
        #expect(!view.overlays.copyImage(path: "../Attachments/2026-09-30/missing.png"))
    }
}
