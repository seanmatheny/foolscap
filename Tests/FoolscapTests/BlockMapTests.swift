import Testing
import Foundation
@testable import FoolscapCore

@Suite struct BlockMapTests {
    @Test func classifiesLines() {
        let text = """
        # Title

        Some text
        - [ ] a task #x
        - bullet
        > quote
        ```swift
        - [ ] not a task
        ```
        ![shot](../Attachments/a.png)
        https://example.com/page
        ---
        """
        let kinds = BlockMap.scan(text).lines.map(\.kind)
        #expect(kinds == [
            .heading(level: 1), .blank, .plain, .task(status: .notStarted), .listItem, .quote,
            .fenceOpen(language: "swift"), .fenceInside, .fenceClose,
            .imageLine(alt: "shot", path: "../Attachments/a.png"), .urlLine("https://example.com/page"), .rule,
        ])
    }

    @Test func rangesCoverTheDocument() {
        let text = "ab\ncd\n\nef"
        let lines = BlockMap.scan(text).lines
        #expect(lines.map { $0.range.location } == [0, 3, 6, 7])
        #expect(lines.map { $0.text } == ["ab", "cd", "", "ef"])
        #expect(BlockMap.scan("").lines.count == 1)
        #expect(BlockMap.scan("x\n").lines.map(\.text) == ["x", ""])
    }

    @Test func lineLookup() {
        let map = BlockMap.scan("one\ntwo\nthree")
        #expect(map.line(at: 0)?.index == 0)
        #expect(map.line(at: 3)?.index == 0)   // end of "one"
        #expect(map.line(at: 4)?.index == 1)
        #expect(map.line(at: 12)?.index == 2)
    }

    @Test func unclosedFenceRunsToEnd() {
        let kinds = BlockMap.scan("```\ncode\nmore").lines.map(\.kind)
        #expect(kinds == [.fenceOpen(language: ""), .fenceInside, .fenceInside])
    }
}

@Suite struct NoteParserTests {
    @Test func extractsTitleAndTasks() {
        let text = "# Tuesday\n\n- [ ] Buy milk #errands\n- [/] Draft plan #work\n```\n- [ ] ignored\n```\n- [x] Done\n"
        let note = NoteParser.parse(text, path: "Daily/2026-09-23.md", day: DayKey("2026-09-23"))
        #expect(note.title == "Tuesday")
        #expect(note.tasks.map(\.title) == ["Buy milk #errands", "Draft plan #work", "Done"])
        #expect(note.tasks.map(\.source.line) == [2, 3, 7])
        #expect(note.tasks[1].category == "work")
        #expect(note.tasks[0].id == "daily:Daily/2026-09-23.md#L2")
    }

    @Test func dayKeys() {
        let d = DayKey("2026-09-23")!
        #expect(d.adding(days: 8).string == "2026-10-01")
        #expect(DayKey("2026-02-30") == nil)
        #expect(DayKey.fromFileName("2026-09-23.md") == d)
        #expect(DayKey.fromFileName("notes.md") == nil)
    }
}
