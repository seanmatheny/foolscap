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

        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
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
        let doc = await library.loadedDocument(forDay: day)
        doc.appendTask("From the tab #life")
        await library.save()
        let text2 = try String(contentsOf: folder.url(for: day), encoding: .utf8)
        #expect(text2 == "# Day\n\n- [/] Ship it #work\n- [x] Old\n\n## Tasks\n- [ ] From the tab #life\n")
        #expect(try library.index.tasks().count == 3)
    }

    @Test func movingSeveralTasksFromOneNoteAndOpenTags() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-flow-many-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let day = DayKey("2026-09-21")!
        try "# Day\n\n- [ ] One #work\n- [ ] Two #home\n- [x] Done #old\n- [/] Three #work\n".write(to: folder.url(for: day), atomically: true, encoding: .utf8)

        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        let aggregator = TaskAggregator()
        aggregator.setProviders([DailyNotesTaskProvider(library: library)])
        await aggregator.reload()
        // #old is only on a completed task, so the filter strip leaves it out.
        #expect(aggregator.openTags == ["work", "home"])

        #expect(TaskStatus.notStarted.toggled == .completed)
        #expect(TaskStatus.inProgress.toggled == .completed)
        #expect(TaskStatus.completed.toggled == .notStarted)

        let open = aggregator.tasks.filter { $0.status != .completed }
        aggregator.move(open, to: .completed)
        #expect(aggregator.openTags.isEmpty)
        for _ in 0..<50 {
            if try String(contentsOf: folder.url(for: day), encoding: .utf8).contains("[x] Three") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try String(contentsOf: folder.url(for: day), encoding: .utf8)
        #expect(text == "# Day\n\n- [x] One #work\n- [x] Two #home\n- [x] Done #old\n- [x] Three #work\n")
    }

    @Test func droppingTasksOnATagTagsEachOnce() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-flow-tag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let day = DayKey("2026-09-22")!
        try "# Day\n\n- [ ] !! One\n- [ ] Two #home\n- [/] Three #work\n".write(to: folder.url(for: day), atomically: true, encoding: .utf8)

        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        let aggregator = TaskAggregator()
        aggregator.setProviders([DailyNotesTaskProvider(library: library)])
        await aggregator.reload()

        // All three dropped on #work: the third already has it and is left alone.
        aggregator.addTag("work", to: aggregator.tasks)
        #expect(aggregator.tasks(status: .notStarted, tag: "work").count == 2)
        for _ in 0..<50 {
            if try String(contentsOf: folder.url(for: day), encoding: .utf8).contains("Two #home #work") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let text = try String(contentsOf: folder.url(for: day), encoding: .utf8)
        #expect(text == "# Day\n\n- [ ] !! One #work\n- [ ] Two #home #work\n- [/] Three #work\n")
    }
}

@Suite @MainActor struct StandaloneTaskTests {
    @Test func quickTasksLandInTasksFile() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-standalone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.addStandaloneTask("Buy stamps #errands")
        await library.addStandaloneTask("Renew passport")
        let text = try String(contentsOf: folder.tasksFile, encoding: .utf8)
        #expect(text == NotesFolder.tasksTemplate + "- [ ] Buy stamps #errands\n- [ ] Renew passport\n")
        await library.rescan(full: true)
        let tasks = try library.index.tasks()
        #expect(tasks.map(\.title) == ["Buy stamps #errands", "Renew passport"])
        #expect(tasks.allSatisfy { $0.source.day == nil && $0.source.path == "Tasks.md" })
        // Status changes write back like any other note.
        let provider = DailyNotesTaskProvider(library: library)
        try await provider.setStatus(.completed, of: tasks[1])
        #expect(try String(contentsOf: folder.tasksFile, encoding: .utf8).contains("- [x] Renew passport"))
    }

    @Test func tasksWithNotesAndPresenceCheck() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        #expect(await library.addStandaloneTask("Call Bob #scribe", notes: "From Work/todo, p. 3", skipIfPresent: true))
        // Same text again (case and spacing differ): refused, file untouched.
        #expect(await !library.addStandaloneTask("call  Bob #scribe", notes: "From Work/todo, p. 4", skipIfPresent: true))
        let text = try String(contentsOf: folder.tasksFile, encoding: .utf8)
        #expect(text == NotesFolder.tasksTemplate + "- [ ] Call Bob #scribe\n  From Work/todo, p. 3\n")
        await library.rescan(full: true)
        let tasks = try library.index.tasks()
        #expect(tasks.count == 1)
        #expect(tasks[0].notes == "From Work/todo, p. 3")
        #expect(tasks[0].tags == ["scribe"])
        // Without the check, duplicates are the caller's business.
        #expect(await library.addStandaloneTask("Call Bob #scribe"))
    }
}
