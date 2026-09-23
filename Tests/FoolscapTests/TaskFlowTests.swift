import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapSections

/// End to end: a note on disk → index → task provider → status change → file.
@Suite @MainActor struct TaskFlowTests {
    @Test func moveWritesBackToTheNote() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-flow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let day = DayKey("2026-09-20")!
        try "# Day\n\n- [ ] Ship it #work\n- [x] Old\n".write(to: folder.url(for: day), atomically: true, encoding: .utf8)

        let library = try NotebookLibrary(folder: folder)
        await library.rescan(full: true)
        let provider = DailyNotesTaskProvider(library: library)
        let tasks = try await provider.tasks()
        #expect(tasks.map(\.title) == ["Ship it #work", "Old"])

        let aggregator = TaskAggregator()
        aggregator.setProviders([provider])
        await aggregator.reload()
        #expect(aggregator.tags == ["work"])
        #expect(aggregator.tasks(status: .notStarted, tag: "work").count == 1)

        try await provider.setStatus(.inProgress, of: tasks[0])
        let text = try String(contentsOf: folder.url(for: day), encoding: .utf8)
        #expect(text == "# Day\n\n- [/] Ship it #work\n- [x] Old\n")
        #expect(try library.index.tasks().first?.status == .inProgress)

        // Appending a task from the Tasks tab lands in the note under ## Tasks.
        let doc = library.document(forDay: day)
        doc.appendTask("From the tab #life")
        library.flushAll()
        let text2 = try String(contentsOf: folder.url(for: day), encoding: .utf8)
        #expect(text2 == "# Day\n\n- [/] Ship it #work\n- [x] Old\n\n## Tasks\n- [ ] From the tab #life\n")
        #expect(try library.index.tasks().count == 3)
    }
}
