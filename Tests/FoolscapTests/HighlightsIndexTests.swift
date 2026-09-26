import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore

@Suite @MainActor struct HighlightsIndexTests {
    static let book = """
        # Moby Dick
        Herman Melville
        #kindle

        > Call me Ishmael.
        > — pos 100 · 12 Mar 2026 · #sea ♥

        > It is a way I have of driving off the spleen.
        > *Note:* mood
        > — pos 200 · #sea #mood hidden

        """

    @Test func indexesBooksAndHighlights() throws {
        let index = try SearchIndex(inMemory: ())
        try index.index(path: "Highlights/Moby Dick.md", day: nil, text: Self.book, stat: FileIO.Stat(mtime: 1, size: 1), hash: "a")
        let items = try index.highlights()
        #expect(items.count == 2)
        #expect(items[0].bookTitle == "Moby Dick" && items[0].bookAuthor == "Herman Melville")
        #expect(items[0].text == "Call me Ishmael." && items[0].tags == ["sea"] && items[0].isFavourite && !items[0].isHidden)
        #expect(items[0].meta.added == HighlightMarkdown.dateFormatter.date(from: "12 Mar 2026"))
        #expect(items[1].note == "mood" && items[1].isHidden && items[1].tags == ["sea", "mood"])
        #expect(items[1].id == "Highlights/Moby Dick.md#L7" && items[1].metaLine == 9)
        #expect(items[0].contentKey == HighlightItem.contentKey(for: ["Call me Ishmael."]))
        let books = try index.highlightBooks()
        #expect(books.map(\.title) == ["Moby Dick"])
        #expect(books[0].count == 2 && books[0].hiddenCount == 1 && books[0].author == "Herman Melville")
        #expect(try index.highlights(inBook: "Highlights/Moby Dick.md").count == 2)
        #expect(try index.highlights(inBook: "Highlights/Other.md").isEmpty)
        // Meta tags are note tags (shared with tasks and daily notes); quotes made no tasks.
        #expect(try index.allTags() == ["kindle", "mood", "sea"])
        #expect(try index.tasks().isEmpty)

        // Re-indexing replaces; removing cascades to tags and the book row.
        try index.index(path: "Highlights/Moby Dick.md", day: nil, text: "# Moby Dick\n#kindle\n\n> Only\n> — pos 1\n",
                        stat: FileIO.Stat(mtime: 2, size: 1), hash: "b")
        #expect(try index.highlights().map(\.text) == ["Only"])
        try index.remove(path: "Highlights/Moby Dick.md")
        #expect(try index.highlights().isEmpty && index.highlightBooks().isEmpty)
        #expect(try index.allTags().isEmpty)
        // Daily notes never populate the highlight tables even with blockquotes.
        try index.index(path: "Daily/2026-09-21.md", day: DayKey("2026-09-21"), text: "# D\n\n> quoted\n> — pos 3\n",
                        stat: FileIO.Stat(mtime: 1, size: 1), hash: "c")
        #expect(try index.highlights().isEmpty)
        try index.index(path: "Highlights/Moby Dick.md", day: nil, text: Self.book, stat: FileIO.Stat(mtime: 1, size: 1), hash: "a")
        try index.removeAll()
        #expect(try index.highlights().isEmpty && index.highlightBooks().isEmpty)
    }

    @Test func dailyScopeLeavesOutHighlightsAndScribe() throws {
        let index = try SearchIndex(inMemory: ())
        try index.index(path: "Daily/2026-09-21.md", day: DayKey("2026-09-21"), text: "# A\n\nIshmael went to sea #sea\n",
                        stat: FileIO.Stat(mtime: 1, size: 1), hash: "a")
        try index.index(path: "Highlights/Moby Dick.md", day: nil, text: Self.book, stat: FileIO.Stat(mtime: 1, size: 1), hash: "b")
        try index.index(path: "Scribe/Work/todo.md", day: nil, text: "# todo\n#scribe\n\nIshmael\n", stat: FileIO.Stat(mtime: 1, size: 1), hash: "c")
        let daily = SearchIndex.PathScope.notUnderAny(["Scribe/", "Highlights/"])
        #expect(try index.searchNotes("ishmael").count == 3)
        #expect(try index.searchNotes("ishmael", scope: daily).map(\.path) == ["Daily/2026-09-21.md"])
        #expect(try index.searchNotes("ishmael", scope: .under("Highlights/")).map(\.path) == ["Highlights/Moby Dick.md"])
        #expect(try index.searchNotes("#sea ", scope: daily).map(\.path) == ["Daily/2026-09-21.md"])
        #expect(daily.includes("Daily/x.md") && !daily.includes("Highlights/x.md") && !daily.includes("Scribe/x.md"))
        #expect(SearchIndex.PathScope.notUnderAny([]).includes("Highlights/x.md"))
        #expect(try index.searchNotes("ishmael", scope: .notUnderAny([])).count == 3)
    }

    @Test func booksAreListedOnlyWhenEnabled() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-highlights-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        try FileManager.default.createDirectory(at: folder.highlightsDirectory, withIntermediateDirectories: true)
        try Self.book.write(to: folder.highlightsDirectory.appendingPathComponent("Moby Dick.md"), atomically: true, encoding: .utf8)
        try Data([1]).write(to: folder.highlightsDirectory.appendingPathComponent("Moby Dick.jpg"))
        try "".write(to: folder.highlightsDirectory.appendingPathComponent(".Other.md.icloud"), atomically: true, encoding: .utf8)
        #expect(folder.listHighlightNotes().map { folder.relativePath(of: $0) } == ["Highlights/Moby Dick.md"])
        #expect(folder.listIndexableNotes().isEmpty)
        #expect(folder.listIndexableNotes(includingHighlights: true).count == 1)
        #expect(NotesFolder.notebookFiles(under: tmp).map(\.relativePath) == ["Highlights/Moby Dick.jpg", "Highlights/Moby Dick.md"])

        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        #expect(try library.index.allNoteRecords().isEmpty)
        library.indexesHighlights = true
        await library.rescan(full: true)
        #expect(try library.index.allNoteRecords().map(\.path) == ["Highlights/Moby Dick.md"])
        #expect(try library.index.highlights().count == 2)
        library.indexesHighlights = false
        await library.rescan()
        #expect(try library.index.highlights().isEmpty)
    }
}

@Suite @MainActor struct HighlightDocumentTests {
    @Test func metaWriteBackVerifiesContent() throws {
        let doc = NoteDocument(path: "Highlights/x.md", url: URL(fileURLWithPath: "/nonexistent/x.md"), day: nil)
        doc.setText(HighlightsIndexTests.book)
        let key = HighlightItem.contentKey(for: ["Call me Ishmael."])
        try doc.replaceHighlightMeta(line: 4, expectedKey: key, with: HighlightMeta(position: 100, tags: ["sea", "whale"], isFavourite: false))
        #expect(doc.text.contains("> Call me Ishmael.\n> — pos 100 · #sea #whale\n"))
        #expect(!doc.text.contains("♥"))
        #expect(doc.isDirty)
        // Moved: found by key. Ambiguous: refused.
        doc.setText("# T\n\n> Filler\n> — pos 1\n\n> Call me Ishmael.\n> — pos 100\n")
        try doc.replaceHighlightMeta(line: 4, expectedKey: key, with: HighlightMeta(position: 100, isHidden: true))
        #expect(doc.text.hasSuffix("> Call me Ishmael.\n> — pos 100 · hidden\n"))
        doc.setText("# T\n\n> Same\n> — pos 1\n\n> Same\n> — pos 2\n")
        #expect(throws: TaskWriteError.self) {
            try doc.replaceHighlightMeta(line: 9, expectedKey: HighlightItem.contentKey(for: ["Same"]), with: HighlightMeta(position: 1))
        }
        doc.setText("x")
        doc.replaceWholeText("y")
        #expect(doc.text == "y" && doc.isDirty)
    }
}

@Suite @MainActor struct PathNormalisationTests {
    @Test func rescanReplacesAnEquivalentSpelling() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-nfc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        try FileManager.default.createDirectory(at: folder.highlightsDirectory, withIntermediateDirectories: true)
        let decomposed = "Highlights/Sho\u{0304}gun.md", precomposed = "Highlights/Sh\u{014D}gun.md"
        try HighlightsIndexTests.book.write(to: folder.url(forRelativePath: decomposed), atomically: true, encoding: .utf8)
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        library.indexesHighlights = true
        await library.rescan(full: true)
        // An index built before paths were normalised holds the decomposed spelling.
        let stat = FileIO.stat(folder.url(forRelativePath: decomposed))!
        try library.index.index(path: decomposed, day: nil, text: HighlightsIndexTests.book, stat: stat, hash: FileIO.hash(Data(HighlightsIndexTests.book.utf8)))
        #expect(try library.index.highlightBooks().count == 2)
        await library.rescan()
        let paths = try library.index.allNoteRecords().map(\.path)
        #expect(paths.count == 1 && paths[0].utf8.elementsEqual(precomposed.utf8))
        #expect(try library.index.highlightBooks().count == 1)
    }

    @Test func relativePathsAndFileNamesArePrecomposed() {
        let folder = NotesFolder(root: URL(fileURLWithPath: "/tmp/notes"))
        let decomposed = "Sho\u{0304}gun"
        let precomposed = "Sh\u{014D}gun"
        #expect(folder.relativePath(of: URL(fileURLWithPath: "/tmp/notes/Highlights/\(decomposed).md")) == "Highlights/\(precomposed).md")
        #expect(FileNames.sanitize(decomposed + ": x") == precomposed + "_ x")
    }
}
