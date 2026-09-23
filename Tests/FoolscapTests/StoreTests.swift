import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore

@Suite struct SearchIndexTests {
    @Test func indexesSearchesAndListsTasks() throws {
        let index = try SearchIndex(inMemory: ())
        let text = "# Monday\n\nMet with Dave about the cluster.\n- [ ] Email Dave #work\n- [x] Lunch #life\n"
        try index.index(path: "Daily/2026-09-21.md", day: DayKey("2026-09-21"), text: text,
                        stat: FileIO.Stat(mtime: 1, size: text.utf8.count), hash: "h1")
        let hits = try index.searchNotes("clust")
        #expect(hits.count == 1)
        #expect(hits[0].title == "Monday")
        #expect(hits[0].snippet.contains("cluster"))
        #expect(try index.searchNotes("nothinghere").isEmpty)
        #expect(try index.searchNotes("\"unbalanced").isEmpty)   // never throws on odd input

        let tasks = try index.tasks()
        #expect(tasks.map(\.title) == ["Email Dave #work", "Lunch #life"])
        #expect(tasks[0].tags == ["work"])
        #expect(try index.tags() == ["life", "work"])
        #expect(try index.searchTasks("dave").count == 1)

        // Re-indexing replaces, never duplicates.
        try index.index(path: "Daily/2026-09-21.md", day: DayKey("2026-09-21"), text: "# Monday\n- [ ] Only one\n",
                        stat: FileIO.Stat(mtime: 2, size: 10), hash: "h2")
        #expect(try index.tasks().count == 1)
        try index.remove(path: "Daily/2026-09-21.md")
        #expect(try index.tasks().isEmpty)
        #expect(try index.allNoteRecords().isEmpty)
    }
}

@Suite struct NotesFolderTests {
    @Test func pathsAndPlaceholders() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-test-\(UUID().uuidString)")
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let day = DayKey("2026-09-23")!
        #expect(folder.relativePath(of: folder.url(for: day)) == "Daily/2026-09-23.md")
        #expect(folder.day(forRelativePath: "Daily/2026-09-23.md") == day)
        try "hi".write(to: folder.url(for: day), atomically: true, encoding: .utf8)
        try "".write(to: folder.dailyDirectory.appendingPathComponent(".2026-09-22.md.icloud"), atomically: true, encoding: .utf8)
        let entries = folder.listDailyNotes()
        #expect(entries.map(\.day.string) == ["2026-09-22", "2026-09-23"])
        #expect(entries.map(\.isPlaceholder) == [true, false])
        #expect(ICloudPlaceholders.isPlaceholder(folder.url(for: DayKey("2026-09-22")!)))
    }
}

@Suite @MainActor struct DocumentTests {
    @Test func taskMarkWriteBackVerifiesContent() throws {
        let doc = NoteDocument(path: "Daily/x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("- [ ] Buy milk\n- [ ] Buy eggs\n")
        let key = TaskItem.contentKey(for: "Buy eggs")
        try doc.replaceTaskMark(line: 1, expectedKey: key, with: .inProgress)
        #expect(doc.text == "- [ ] Buy milk\n- [/] Buy eggs\n")
        #expect(doc.isDirty)
        // Line moved: found by content key.
        doc.setText("intro\n- [ ] Buy milk\n- [/] Buy eggs\n")
        try doc.replaceTaskMark(line: 1, expectedKey: key, with: .completed)
        #expect(doc.text == "intro\n- [ ] Buy milk\n- [x] Buy eggs\n")
        // Ambiguous: refuse.
        doc.setText("- [ ] Same\n- [ ] Same\n")
        #expect(throws: TaskWriteError.self) {
            try doc.replaceTaskMark(line: 5, expectedKey: TaskItem.contentKey(for: "Same"), with: .completed)
        }
    }

    @Test func appendTaskCreatesAndExtendsSection() {
        let doc = NoteDocument(path: "Daily/x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("# Day\n\nnotes\n")
        doc.appendTask("First #a")
        #expect(doc.text == "# Day\n\nnotes\n\n## Tasks\n- [ ] First #a\n")
        doc.appendTask("Second")
        #expect(doc.text == "# Day\n\nnotes\n\n## Tasks\n- [ ] First #a\n- [ ] Second\n")
    }

    @Test func saveAndReload() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-doc-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let doc = NoteDocument(path: "x.md", url: tmp, day: nil)
        doc.load(template: "# T\n")
        doc.textStorage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "x")
        doc.textStorage.replaceCharacters(in: NSRange(location: 4, length: 1), with: "")
        #expect(doc.isDirty)
        #expect(try doc.save() == false)          // edited back to the template: nothing to write
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        doc.textStorage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "hello")
        #expect(try doc.save())
        #expect(try String(contentsOf: tmp, encoding: .utf8) == "# T\nhello")
        #expect(try doc.save() == false)
        try "# T\nexternal\n".write(to: tmp, atomically: true, encoding: .utf8)
        #expect(doc.reloadIfChanged())
        #expect(doc.text == "# T\nexternal\n")
        #expect(!doc.isDirty)
        doc.textStorage.append(NSAttributedString(string: "local"))
        try "# T\nother\n".write(to: tmp, atomically: true, encoding: .utf8)
        #expect(doc.reloadIfChanged() == false)
        #expect(doc.externalChangePending)
    }
}
