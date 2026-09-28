import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapSections

/// The #today list at the head of today's daily note.
@Suite @MainActor struct TodayTasksTests {
    private func task(_ title: String, status: TaskStatus = .notStarted, path: String, line: Int, day: String? = nil) -> TaskItem {
        TaskItem(providerID: "daily", title: title, status: status, tags: TaskLineParser.tags(in: title), indent: 0,
                 source: TaskSource(path: path, line: line, day: day))
    }

    @Test func picksOpenTodayTasksFromOtherNotes() {
        let today = DayKey("2026-09-28")!
        let tasks = [
            task("On the page already #today", path: "Daily/2026-09-28.md", line: 3, day: "2026-09-28"),
            task("Yesterday's #today", path: "Daily/2026-09-27.md", line: 3, day: "2026-09-27"),
            task("!! Urgent #today", path: "Daily/2026-09-20.md", line: 4, day: "2026-09-20"),
            task("Standalone #today", path: "Tasks.md", line: 2),
            task("Done #today", status: .completed, path: "Daily/2026-09-25.md", line: 2, day: "2026-09-25"),
            task("Not for today #work", path: "Daily/2026-09-26.md", line: 2, day: "2026-09-26"),
        ]
        let picked = TodayTasks.select(from: tasks, today: today)
        #expect(picked.map(\.title) == ["!! Urgent #today", "Yesterday's #today", "Standalone #today"])
        // A ticked task the page has shown stays, struck through, at the end.
        let kept = TodayTasks.select(from: tasks, today: today, keep: [tasks[4].id])
        #expect(kept.map(\.title) == ["!! Urgent #today", "Yesterday's #today", "Standalone #today", "Done #today"])
    }

    @Test func tickingFromTodaysPageWritesBackToTheNote() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-today-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let today = DayKey.today, yesterday = today.adding(days: -1)
        try "# Yesterday\n\n- [ ] Ring the bank #today\n- [ ] Later #work\n".write(to: folder.url(for: yesterday), atomically: true, encoding: .utf8)
        try "# Today\n\n- [ ] Here already #today\n".write(to: folder.url(for: today), atomically: true, encoding: .utf8)

        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        let aggregator = TaskAggregator()
        aggregator.setProviders([DailyNotesTaskProvider(library: library)])
        await aggregator.reload()

        let heading = TodayTasks.select(from: aggregator.tasks, today: today)
        #expect(heading.map(\.title) == ["Ring the bank #today"])

        aggregator.move(heading[0], to: .completed)
        for _ in 0..<50 {
            if try String(contentsOf: folder.url(for: yesterday), encoding: .utf8).contains("[x] Ring") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try String(contentsOf: folder.url(for: yesterday), encoding: .utf8)
        #expect(text == "# Yesterday\n\n- [x] Ring the bank #today\n- [ ] Later #work\n")
        // Gone from the head of the page once done, unless the page is still showing it.
        #expect(TodayTasks.select(from: aggregator.tasks, today: today).isEmpty)
        #expect(TodayTasks.select(from: aggregator.tasks, today: today, keep: [heading[0].id]).count == 1)
    }
}
