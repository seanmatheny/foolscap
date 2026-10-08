import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapSections

/// The Today list at the head of today's daily note.
@Suite @MainActor struct TodayTasksTests {
    private func task(_ title: String, status: TaskStatus = .notStarted, path: String, line: Int, day: String? = nil) -> TaskItem {
        TaskItem(providerID: "daily", title: title, status: status, tags: TaskLineParser.tags(in: title), indent: 0,
                 source: TaskSource(path: path, line: line, day: day))
    }

    @Test func picksTodayStatusTasksFromOtherNotes() {
        let today = DayKey("2026-09-28")!
        let tasks = [
            task("On the page already", status: .today, path: "Daily/2026-09-28.md", line: 3, day: "2026-09-28"),
            task("Yesterday's", status: .today, path: "Daily/2026-09-27.md", line: 3, day: "2026-09-27"),
            task("!! Urgent", status: .today, path: "Daily/2026-09-20.md", line: 4, day: "2026-09-20"),
            task("Standalone", status: .today, path: "Tasks.md", line: 2),
            task("Done", status: .completed, path: "Daily/2026-09-25.md", line: 2, day: "2026-09-25"),
            task("Not for today #today", path: "Daily/2026-09-26.md", line: 2, day: "2026-09-26"),
            task("Parked", status: .someday, path: "Daily/2026-09-26.md", line: 3, day: "2026-09-26"),
        ]
        let picked = TodayTasks.select(from: tasks, today: today)
        // The status decides, not the old #today tag; to do and someday stay off the page.
        #expect(picked.map(\.title) == ["!! Urgent", "Yesterday's", "Standalone"])
        // A ticked task the page has shown stays, struck through, at the end.
        let kept = TodayTasks.select(from: tasks, today: today, keep: [tasks[4].id])
        #expect(kept.map(\.title) == ["!! Urgent", "Yesterday's", "Standalone", "Done"])
    }

    @Test func tickingFromTodaysPageWritesBackToTheNote() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-today-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let today = DayKey.today, yesterday = today.adding(days: -1)
        try "# Yesterday\n\n- [/] Ring the bank\n- [ ] Later #work\n".write(to: folder.url(for: yesterday), atomically: true, encoding: .utf8)
        try "# Today\n\n- [/] Here already\n".write(to: folder.url(for: today), atomically: true, encoding: .utf8)

        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        let aggregator = TaskAggregator()
        aggregator.setProviders([DailyNotesTaskProvider(library: library)])
        await aggregator.reload()

        let heading = TodayTasks.select(from: aggregator.tasks, today: today)
        #expect(heading.map(\.title) == ["Ring the bank"])

        aggregator.move(heading[0], to: .completed)
        for _ in 0..<50 {
            if try String(contentsOf: folder.url(for: yesterday), encoding: .utf8).contains("[x] Ring") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try String(contentsOf: folder.url(for: yesterday), encoding: .utf8)
        #expect(text == "# Yesterday\n\n- [x] Ring the bank\n- [ ] Later #work\n")
        // Gone from the head of the page once done, unless the page is still showing it.
        #expect(TodayTasks.select(from: aggregator.tasks, today: today).isEmpty)
        #expect(TodayTasks.select(from: aggregator.tasks, today: today, keep: [heading[0].id]).count == 1)
    }

    /// The one-off conversion from the #today tag: open tasks take the mark and
    /// lose the tag, done ones are left as history, a second run finds nothing.
    @Test func migratesTodayTagOnce() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-today-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let day = DayKey("2026-09-27")!
        try "# Day\n\n- [ ] Ring the bank #today\n- [x] Done #today\n- [ ] Only #TODAY\n- [ ] Keep #work\n"
            .write(to: folder.url(for: day), atomically: true, encoding: .utf8)
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)

        #expect(await library.migrateTodayTagToStatus() == 2)
        let text = try String(contentsOf: folder.url(for: day), encoding: .utf8)
        #expect(text == "# Day\n\n- [/] Ring the bank\n- [x] Done #today\n- [/] Only\n- [ ] Keep #work\n")
        #expect(await library.migrateTodayTagToStatus() == 0)
    }
}
