import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapScribe

/// Remembers what it was given; refuses an exact repeat, like Tasks.md would.
final class MemorySink: TaskSink, @unchecked Sendable {
    var lines: [String] = []
    func add(_ todo: Todo, source: String) async -> Bool {
        let line = "- [ ] \(todo.text) — \(source), p. \(todo.page)"
        if lines.contains(line) { return false }
        lines.append(line)
        return true
    }
}

@Suite struct ScribeLedgerTests {
    func sync(_ sink: MemorySink, known: inout [String: TodoRecord], _ lines: String...) async -> Int {
        let page = [lines.enumerated().map { TextLine($1, x: 0.05, y: 0.1 + 0.045 * Double($0), w: 0.3, h: 0.04) }]
        let outcome = await TodoLedger.sync(found: ScribeTodos.extractTodos([page]), known: known, source: "Work/todo", sink: sink)
        known = outcome.known
        return outcome.added
    }

    @Test func aTaskIsAddedOnce() async {
        let sink = MemorySink(); var known: [String: TodoRecord] = [:]
        #expect(await sync(sink, known: &known, "TODO: Wash the car") == 1)
        #expect(await sync(sink, known: &known, "TODO: Wash the car") == 0)
        #expect(sink.lines == ["- [ ] Wash the car — Work/todo, p. 1"])
        #expect(known["wash the car"]?.page == 1)
    }

    @Test func newTaskJoinsExistingOnes() async {
        let sink = MemorySink(); var known: [String: TodoRecord] = [:]
        _ = await sync(sink, known: &known, "TODO: Wash the car")
        #expect(await sync(sink, known: &known, "TODO: Wash the car", "TODO: Buy milk") == 1)
    }

    @Test func sameHandwritingReadDifferentlyIsNotANewTask() async {
        let sink = MemorySink(); var known: [String: TodoRecord] = [:]
        _ = await sync(sink, known: &known, "TODO: Wash the car today")
        #expect(await sync(sink, known: &known, "TODO: Wash the cor today") == 0)
        #expect(known.keys.sorted() == ["wash the cor today"])
        #expect(await sync(sink, known: &known, "TODO: Wash the car today") == 0)
        #expect(sink.lines.count == 1)
    }

    @Test func similarTasksSideBySideAreBothKept() async {
        let sink = MemorySink(); var known: [String: TodoRecord] = [:]
        #expect(await sync(sink, known: &known, "TODO: Book flight 1", "TODO: Book flight 2") == 2)
    }

    @Test func taskWrittenTwiceIsAddedOnce() async {
        let sink = MemorySink(); var known: [String: TodoRecord] = [:]
        #expect(await sync(sink, known: &known, "TODO: Wash the car", "TODO: wash the car!") == 1)
    }

    @Test func lostStateDoesNotDuplicateTasks() async {
        let sink = MemorySink(); var known: [String: TodoRecord] = [:]
        _ = await sync(sink, known: &known, "TODO: Wash the car")
        known = [:]
        #expect(await sync(sink, known: &known, "TODO: Wash the car") == 0)
        #expect(sink.lines.count == 1)
        #expect(known.count == 1)   // recorded anyway, so the next pass is quiet
    }

    @Test func stateRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-state-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent()) }
        var state = ScribeState()
        var folder = ScribeItem(id: "f1", name: "Work", path: "Work", isFolder: true, parentID: nil)
        folder.order = 1
        var nb = ScribeItem(id: "n1", name: "todo", path: "Work/todo", isFolder: false, parentID: "f1")
        nb.todos["wash the car"] = TodoRecord(text: "Wash the car", page: 2, addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        nb.contentHash = "abc"; nb.totalPages = 3; nb.updateTime = 42
        state.items = [folder.id: folder, nb.id: nb]
        try state.save(to: tmp)
        let back = ScribeState.load(from: tmp)
        #expect(back == state)
        #expect(back.rootItems.map(\.id) == ["f1"])
        #expect(back.notebooks(under: "f1").map(\.id) == ["n1"])
        #expect(back.item(atTranscriptPath: "Scribe/Work/todo.md")?.id == "n1")
        #expect(ScribeState.load(from: tmp.appendingPathExtension("missing")) == ScribeState())
    }

    @Test @MainActor func librarySinkAppendsTaggedTasksWithNotes() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-sink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder)
        let sink = LibraryTaskSink(library: library)
        #expect(await sink.add(Todo("Wash the car", page: 2), source: "Work/todo"))
        #expect(!(await sink.add(Todo("wash the car", page: 5), source: "Work/todo")))
        let text = try String(contentsOf: folder.tasksFile, encoding: .utf8)
        #expect(text == NotesFolder.tasksTemplate + "- [ ] Wash the car #scribe\n  From Work/todo, p. 2\n")
        await library.rescan(full: true)
        let task = try #require(try library.index.tasks().first)
        #expect(task.tags == ["scribe"] && task.notes == "From Work/todo, p. 2" && task.providerID == "daily")
    }
}

@Suite @MainActor struct ScribeSectionTests {
    @Test func searchHitsRouteToTheNotebookPage() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-section-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder)
        library.indexesScribe = true
        // A daily note and a transcript that both mention the budget.
        let day = DayKey("2026-09-24")!
        try "# Day\n\nBudget meeting\n".write(to: folder.url(for: day), atomically: true, encoding: .utf8)
        let notebook = ScribeNotebookRef(id: "n1", name: "todo", path: "Work/todo")
        let pages: [[[TextLine]]] = [pageOf("nothing"), pageOf("TODO: send budget")]
        let transcript = ScribeTranscript.render(notebook: notebook, title: "todo", pages: pages, modified: Date(timeIntervalSince1970: 0))
        let mdURL = folder.scribeDirectory.appendingPathComponent("Work/todo.md")
        try FileManager.default.createDirectory(at: mdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try transcript.write(to: mdURL, atomically: true, encoding: .utf8)
        await library.rescan(full: true)

        var state = ScribeState()
        state.items["f1"] = ScribeItem(id: "f1", name: "Work", path: "Work", isFolder: true, parentID: nil)
        state.items["n1"] = ScribeItem(id: "n1", name: "todo", path: "Work/todo", isFolder: false, parentID: "f1")
        state.items["n2"] = ScribeItem(id: "n2", name: "Loose", path: "Loose", isFolder: false, parentID: nil)
        let stateURL = tmp.appendingPathComponent("state.json")
        try state.save(to: stateURL)

        let section = ScribeSection(library: library, stateURL: stateURL)
        #expect(section.folderTabs.map(\.name) == ["Work", "Notebooks"])
        #expect(section.selectedFolderID == "f1" && section.selectedNotebookID == "n1")
        section.select(folder: ScribeSection.looseFolderID)
        #expect(section.selectedNotebookID == "n2")

        let provider = try #require(section.searchProvider)
        let hits = try await provider.search("budget", limit: 10)
        #expect(hits.map(\.sectionID) == ["scribe"])
        #expect(hits[0].route.path == "Scribe/Work/todo.md")
        // FTS marks the match with \u{1}…\u{2}; the markdown escapes and ** must be gone.
        let plain = hits[0].snippet.replacingOccurrences(of: "\u{1}", with: "").replacingOccurrences(of: "\u{2}", with: "")
        #expect(plain.contains("TODO: send budget") && !plain.contains("**"))
        let daily = try library.index.searchNotes("budget", scope: .notUnder("Scribe/"))
        #expect(daily.map(\.path) == ["Daily/2026-09-24.md"])

        section.navigate(to: hits[0].route)
        #expect(section.selectedFolderID == "f1" && section.selectedNotebookID == "n1" && section.pendingPage == 2)
        #expect(section.contents.map(\.group) == [""] && section.contents[0].notebooks.map(\.id) == ["n1"])
    }
}
