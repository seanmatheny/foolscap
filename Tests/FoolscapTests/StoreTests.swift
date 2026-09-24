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

@Suite @MainActor struct TaskTitleTests {
    @Test func replacesTitleKeepingPrefix() throws {
        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText("  - [/] Old title #a\n- [ ] Other\n")
        try doc.replaceTaskTitle(line: 0, expectedKey: TaskItem.contentKey(for: "Old title #a"), with: "New title #a #b")
        #expect(doc.text == "  - [/] New title #a #b\n- [ ] Other\n")
    }
}

@Suite @MainActor struct TaskNotesTests {
    @Test func parsesAndRewritesNotes() throws {
        let text = "- [ ] Call Dave #work\n  Ask about https://example.com/quote\n  and the timeline\n- [ ] Other\n"
        let parsed = NoteParser.parse(text, path: "x.md", day: nil)
        #expect(parsed.tasks.count == 2)
        #expect(parsed.tasks[0].notes == "Ask about https://example.com/quote\nand the timeline")
        #expect(parsed.tasks[0].firstLink?.absoluteString == "https://example.com/quote")
        #expect(parsed.tasks[1].notes == nil)

        let doc = NoteDocument(path: "x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText(text)
        let key = TaskItem.contentKey(for: "Call Dave #work")
        try doc.replaceTaskNotes(line: 0, expectedKey: key, with: "Just one line")
        #expect(doc.text == "- [ ] Call Dave #work\n  Just one line\n- [ ] Other\n")
        try doc.replaceTaskNotes(line: 0, expectedKey: key, with: nil)
        #expect(doc.text == "- [ ] Call Dave #work\n- [ ] Other\n")
        try doc.replaceTaskNotes(line: 1, expectedKey: TaskItem.contentKey(for: "Other"), with: "a\nb")
        #expect(doc.text == "- [ ] Call Dave #work\n- [ ] Other\n  a\n  b\n")
    }
}

@Suite struct TagSearchTests {
    @Test func tagsFilterNotesAndTasks() throws {
        let index = try SearchIndex(inMemory: ())
        try index.index(path: "Daily/2026-09-21.md", day: DayKey("2026-09-21"), text: "# A\n\nCluster notes #hpc #work\n- [ ] Fix nodes\n",
                        stat: FileIO.Stat(mtime: 1, size: 1), hash: "a")
        try index.index(path: "Daily/2026-09-22.md", day: DayKey("2026-09-22"), text: "# B\n\nCluster again #home\n- [ ] Fix sink #home\n",
                        stat: FileIO.Stat(mtime: 1, size: 1), hash: "b")
        #expect(try index.allTags() == ["home", "hpc", "work"])
        #expect(try index.searchNotes("cluster").count == 2)
        #expect(try index.searchNotes("cluster #hpc").map(\.path) == ["Daily/2026-09-21.md"])
        #expect(try index.searchNotes("#work #hpc").map(\.path) == ["Daily/2026-09-21.md"])
        #expect(try index.searchNotes("#home").map(\.path) == ["Daily/2026-09-22.md"])
        #expect(try index.searchNotes("#nothing").isEmpty)
        #expect(try index.searchNotes("#h").map(\.path) == ["Daily/2026-09-22.md", "Daily/2026-09-21.md"])   // prefix while typing
        #expect(try index.searchTasks("fix #home").map(\.title) == ["Fix sink #home"])
        #expect(try index.searchTasks("fix #hpc").map(\.title) == ["Fix nodes"])   // note-level tag applies
        let q = SearchQuery("cluster #wo")
        #expect(q.words == ["cluster"] && q.tags.isEmpty && q.pendingTag == "wo")
        #expect(SearchQuery.completing("cluster #wo", with: "work") == "cluster #work ")
        #expect(SearchQuery("#work ").tags == ["work"])
    }
}

@Suite @MainActor struct ScribeIndexingTests {
    @Test func scopesKeepSectionsDisjoint() throws {
        let index = try SearchIndex(inMemory: ())
        try index.index(path: "Daily/2026-09-21.md", day: DayKey("2026-09-21"), text: "# A\n\nBudget meeting #work\n- [ ] Send budget\n",
                        stat: FileIO.Stat(mtime: 1, size: 1), hash: "a")
        let transcript = "# todo\n#scribe/work\n\n## Page 1\n\n**TODO:** Send budget\n\\#budget is \\*big\\*\n\n---\n*Sync ID abc*\n"
        try index.index(path: "Scribe/Work/todo.md", day: nil, text: transcript, stat: FileIO.Stat(mtime: 1, size: 1), hash: "s")
        #expect(try index.searchNotes("budget").count == 2)
        #expect(try index.searchNotes("budget", scope: .under("Scribe/")).map(\.path) == ["Scribe/Work/todo.md"])
        #expect(try index.searchNotes("budget", scope: .notUnder("Scribe/")).map(\.path) == ["Daily/2026-09-21.md"])
        // Tags-only branch honours the scope too, and escaped OCR text made no tags.
        #expect(try index.searchNotes("#scribe/work ", scope: .under("Scribe/")).map(\.title) == ["todo"])
        #expect(try index.searchNotes("#scribe/work ", scope: .notUnder("Scribe/")).isEmpty)
        #expect(try index.allTags() == ["scribe/work", "work"])
        // A transcript's **TODO:** lines are prose, not task rows.
        #expect(try index.tasks().map(\.source.path) == ["Daily/2026-09-21.md"])
        #expect(try index.searchTasks("budget", scope: .under("Scribe/")).isEmpty)
        #expect(try index.searchTasks("budget", scope: .notUnder("Scribe/")).count == 1)
    }

    @Test func transcriptsAreListedOnlyWhenEnabled() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let nested = folder.scribeDirectory.appendingPathComponent("Personal/book notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "# Notebook 1\n#scribe/personal/book-notes\n\n## Page 1\n\nhello\n".write(to: nested.appendingPathComponent("Notebook 1.md"), atomically: true, encoding: .utf8)
        try Data().write(to: nested.appendingPathComponent("Notebook 1.pdf"))
        try "".write(to: nested.appendingPathComponent(".Notebook 2.md.icloud"), atomically: true, encoding: .utf8)
        #expect(folder.listScribeNotes().map { folder.relativePath(of: $0) } == ["Scribe/Personal/book notes/Notebook 1.md"])
        #expect(folder.listIndexableNotes().isEmpty)
        #expect(folder.listIndexableNotes(includingScribe: true).count == 1)

        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        #expect(try library.index.allNoteRecords().isEmpty)
        library.indexesScribe = true
        await library.rescan(full: true)
        #expect(try library.index.allNoteRecords().map(\.path) == ["Scribe/Personal/book notes/Notebook 1.md"])
        #expect(try library.index.allTags() == ["scribe/personal/book-notes"])
        library.indexesScribe = false
        await library.rescan()
        #expect(try library.index.allNoteRecords().isEmpty)
    }
}
