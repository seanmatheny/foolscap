import Testing
import Foundation
import AppKit
import FoolscapCore
import FoolscapStore
@testable import FoolscapSections
@testable import FoolscapScribe
@testable import FoolscapEditor

@Suite struct DayPageMarkdownTests {
    let page = DayPage(id: "scribe:Scribe/Work/Notes.md#4", sectionID: "scribe", title: "Daily Work Notes", subtitle: "Page 1",
                       headline: "July 24th #meeting", text: "July 24th #meeting\n- Setting up lab\n\nKatrina - platform",
                       route: SectionRoute(path: "Scribe/Work/Notes.md", line: 4))

    @Test func blockIsAHeadingAndAQuoteWithEscapedText() {
        #expect(DayPageMarkdown.block(for: page) == "## July 24th \\#meeting\n> July 24th \\#meeting\n> - Setting up lab\n>\n> Katrina - platform")
    }

    @Test func presenceIsTheHeadingLine() {
        let note = "# Friday\n\ntyped notes\n\n" + DayPageMarkdown.block(for: page) + "\n"
        #expect(DayPageMarkdown.isPresent(in: note, page: page))
        #expect(!DayPageMarkdown.isPresent(in: "# Friday\n\nJuly 24th #meeting\n", page: page))
    }
}

@Suite struct ScribeSpreadTests {
    @Test func spreadNeedsRoomForTwoLeaves() {
        #expect(ScribeNotebookView.columns(for: 759) == nil)
        let narrow = ScribeNotebookView.columns(for: 760)!
        #expect(narrow.verso == 351 && narrow.recto == 381)
        let wide = ScribeNotebookView.columns(for: 1400)!
        #expect(wide.verso == 480 && wide.recto == 892)
    }
}

@Suite @MainActor struct ScribeDayPagesProviderTests {
    @Test func listsThePagesWrittenOnADayWithRoutesToTheirHeadings() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-daypages-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        let section = ScribeSection(library: library, stateURL: tmp.appendingPathComponent("state.json"),
                                    cacheDirectory: tmp.appendingPathComponent("OCR"), defaults: UserDefaults(suiteName: "foolscap-daypages-\(UUID().uuidString)")!)
        var item = ScribeItem(id: "n1", name: "Work Notes", path: "Work/Work Notes", isFolder: false, parentID: nil, order: 0)
        item.transcribedHash = "k1"
        let day = DayKey("2026-07-24")!
        let ref = ScribeNotebookRef(id: "n1", name: "Work Notes", path: "Work/Work Notes")
        let transcript = ScribeTranscript.render(notebook: ref, title: "Work Notes",
                                                 pages: [pageOf("July 24th", "- lab"), pageOf("more"), pageOf("17/6/26 eRGG")],
                                                 days: [day, day, DayKey("2026-06-17")], modified: Date(timeIntervalSince1970: 0))
        let md = folder.url(forRelativePath: item.transcriptRelativePath)
        try FileManager.default.createDirectory(at: md.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(transcript.utf8).write(to: md)
        var state = ScribeState()
        state.items["n1"] = item
        section.replaceStateForTesting(state)

        let provider = try #require(section.dayPagesProvider)
        let pages = await provider.pages(on: day)
        #expect(pages.map(\.subtitle) == ["Page 1", "Page 2"])
        #expect(pages[0].title == "Work Notes" && pages[0].headline == "July 24th" && pages[0].text == "July 24th\n- lab")
        #expect(pages[0].route.path == "Scribe/Work/Work Notes.md")
        let parsed = ScribeTranscript.parse(transcript)
        #expect(ScribeTranscript.pageNumber(forLine: pages[1].route.line!, in: parsed) == 2)
        #expect(await provider.pages(on: DayKey("2026-06-17")!).map(\.subtitle) == ["Page 3"])
        #expect(await provider.pages(on: DayKey("2026-01-01")!).isEmpty)
    }
}

@Suite @MainActor struct EditorFooterTests {
    @Test func footerSitsBelowTheTextAndExtendsTheView() {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("# Friday\n\none\ntwo\n")
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.documentView = view
        view.visibleHeight = 300
        view.textLayoutManager?.ensureLayout(for: view.textLayoutManager!.documentRange)
        view.sizeToFit()
        let before = view.frame.height
        #expect(before == 300)
        let footer = NSView(frame: .zero)
        view.footerView = footer
        view.footerHeight = 500
        view.layoutSubtreeIfNeeded()
        view.layout()
        #expect(view.frame.height >= view.textBottom + 500, "frame \(view.frame.height), text bottom \(view.textBottom)")
        #expect(footer.frame.minY > view.textBottom && footer.frame.height == 500)
        // Gone again: back to the page's height.
        view.footerView = nil
        view.footerHeight = 0
        view.layout()
        #expect(view.minSize.height == 300)
    }

    @Test func appendedBlockLandsAfterABlankLineAndCanBeUndone() {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("# Friday\n\ntyped")
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        view.appendMarkdownBlock("## Meeting\n> notes")
        #expect(doc.text == "# Friday\n\ntyped\n\n## Meeting\n> notes\n")
        view.appendMarkdownBlock("## Second")
        #expect(doc.text.hasSuffix("> notes\n\n## Second\n"))
    }
}
