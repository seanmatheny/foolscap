import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapHighlights

/// A Kindle library in memory: books, their annotations and the text each range yields.
final class FakeExtractor: KindleExtracting, @unchecked Sendable {
    var books: [KindleBook] = []
    var annotations: [String: [KindleAnnotation]] = [:]
    /// Book id → position → paragraphs.
    var texts: [String: [Int: [String]]] = [:]
    var covers: [String: Data] = [:]
    var failures: [String: ExtractionFailure] = [:]
    var listingError: ExtractionFailure?
    var extractCalls: [String] = []
    var preparedBooks: [String] = []

    func listing() async throws -> KindleListing {
        if let listingError { throw listingError }
        return KindleListing(books: books, annotations: annotations)
    }

    func prepare(_ books: [KindleBook], progress: @Sendable @escaping (String) -> Void) async {
        preparedBooks += books.map(\.id)
    }

    func extract(_ book: KindleBook, annotations: [KindleAnnotation], wantsCover: Bool) async throws -> ExtractedBook {
        extractCalls.append(book.id)
        if let failure = failures[book.id] { throw failure }
        var highlights: [ExtractedHighlight] = []
        var empty = 0
        for a in annotations {
            guard let paragraphs = texts[book.id]?[a.start], !paragraphs.isEmpty else { empty += 1; continue }
            highlights.append(ExtractedHighlight(annotationID: a.id, paragraphs: paragraphs, note: a.note, position: a.start,
                                                 created: a.created, modified: a.modified))
        }
        return ExtractedBook(book: book, coverJPEG: wantsCover ? covers[book.id] : nil, highlights: highlights, emptyCount: empty)
    }
}

@Suite @MainActor struct HighlightsImporterTests {
    static func book(_ id: String, _ title: String, format: KindleFormat = .kfx, downloaded: Bool = true) -> KindleBook {
        KindleBook(id: id, title: title, author: "Author \(id)", format: format, fileURL: URL(fileURLWithPath: "/tmp/\(id)"),
                   maxPosition: nil, isDictionary: false, isDownloaded: downloaded)
    }
    static func annotation(_ start: Int, note: String? = nil, modified: Double = 1) -> KindleAnnotation {
        KindleAnnotation(id: "kindle.highlight-\(start)", kind: .highlight, start: start, end: start + 10,
                         created: Date(timeIntervalSince1970: 1_700_000_000), modified: Date(timeIntervalSince1970: modified), note: note)
    }

    struct Env {
        let tmp: URL
        let folder: NotesFolder
        let library: NotebookLibrary
        let extractor: FakeExtractor
        let importer: HighlightsImporter
        var stateURL: URL { tmp.appendingPathComponent("state.json") }
        func text(_ path: String) throws -> String { try String(contentsOf: folder.url(forRelativePath: path), encoding: .utf8) }
    }

    static func env() throws -> Env {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-import-\(UUID().uuidString)")
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        library.indexesHighlights = true
        let extractor = FakeExtractor()
        let importer = HighlightsImporter(extractor: extractor, library: library, stateURL: tmp.appendingPathComponent("state.json"))
        return Env(tmp: tmp, folder: folder, library: library, extractor: extractor, importer: importer)
    }

    @Test func firstRunWritesFilesCoversAndLedger() async throws {
        let env = try Self.env()
        defer { try? FileManager.default.removeItem(at: env.tmp) }
        let x = env.extractor
        x.books = [Self.book("B1", "Moby Dick"), Self.book("B2", "Cloud Only", downloaded: false), Self.book("B3", "A PDF", format: .pdf),
                   Self.book("B4", "No highlights"), Self.book("B5", "Broken")]
        x.annotations = ["B1": [Self.annotation(200, note: "why"), Self.annotation(100)], "B2": [Self.annotation(1)],
                         "B3": [Self.annotation(1)], "B5": [Self.annotation(1), Self.annotation(2)]]
        x.texts = ["B1": [100: ["Call me Ishmael."], 200: ["Some years ago", "never mind how long."]]]
        x.covers = ["B1": Data([0xFF, 0xD8, 0xFF, 0])]
        x.failures = ["B5": .positionMismatch(book: 5, file: 6)]

        let report = try await env.importer.run { _ in }
        #expect(report.booksSeen == 4 && report.booksWritten == 1 && report.highlightsAdded == 2 && report.coversWritten == 1)
        // Unreadable books are noted up front; failures during reading come after, in title order.
        #expect(report.skipped.map(\.title) == ["A PDF", "Cloud Only", "Broken"])
        #expect(report.skipped.map(\.reason) == ["unsupported format (PDF)", "not downloaded in the Kindle app", "positions don't line up (app 5, file 6)"])
        #expect(x.preparedBooks == ["B5", "B1"])
        let text = try env.text("Highlights/Moby Dick.md")
        #expect(text == """
            # Moby Dick
            Author B1
            #kindle

            > Call me Ishmael.
            > — pos 100 · \(HighlightMarkdown.dateFormatter.string(from: Date(timeIntervalSince1970: 1_700_000_000)))

            > Some years ago
            > never mind how long.
            > *Note:* why
            > — pos 200 · \(HighlightMarkdown.dateFormatter.string(from: Date(timeIntervalSince1970: 1_700_000_000)))

            """)
        #expect(FileManager.default.fileExists(atPath: env.folder.url(forRelativePath: "Highlights/Moby Dick.jpg").path))
        #expect(try env.library.index.highlights().count == 2)
        #expect(try env.library.index.highlightBooks().map(\.title) == ["Moby Dick"])
        let state = HighlightsState.load(from: env.stateURL)
        #expect(state.books["B1"]?.path == "Highlights/Moby Dick.md" && state.books["B1"]?.coverDone == true)
        #expect(state.annotations.count == 2 && state.lastRun != nil)

        // A second run finds nothing to do; only the book that failed is tried again.
        x.extractCalls = []
        let again = try await env.importer.run { _ in }
        #expect(again.highlightsAdded == 0 && again.booksWritten == 0 && x.extractCalls == ["B5"])
        #expect(try env.text("Highlights/Moby Dick.md") == text)
    }

    @Test func newerKindleEditsReplaceInPlaceAndKeepTags() async throws {
        let env = try Self.env()
        defer { try? FileManager.default.removeItem(at: env.tmp) }
        let x = env.extractor
        x.books = [Self.book("B1", "Moby Dick")]
        x.annotations = ["B1": [Self.annotation(100)]]
        x.texts = ["B1": [100: ["Call me Ishmael."]]]
        _ = try await env.importer.run { _ in }
        // The user tags and hearts it.
        let doc = await env.library.loadedDocument(atRelativePath: "Highlights/Moby Dick.md")
        try doc.replaceHighlightMeta(line: 4, expectedKey: HighlightItem.contentKey(for: ["Call me Ishmael."]),
                                     with: HighlightMeta(position: 100, tags: ["sea"], isFavourite: true))
        await env.library.save()
        // The Kindle extends the highlight (same annotation, newer modified time, new text) and adds one.
        x.annotations = ["B1": [Self.annotation(100, modified: 50), Self.annotation(300)]]
        x.texts = ["B1": [100: ["Call me Ishmael. Some years ago."], 300: ["Later."]]]
        let report = try await env.importer.run { _ in }
        #expect(report.highlightsUpdated == 1 && report.highlightsAdded == 1)
        let parsed = HighlightParser.parse(try env.text("Highlights/Moby Dick.md"), path: "Highlights/Moby Dick.md")
        #expect(parsed.items.map(\.text) == ["Call me Ishmael. Some years ago.", "Later."])
        #expect(parsed.items[0].meta.tags == ["sea"] && parsed.items[0].isFavourite)
        // A highlight whose start moved (a new Kindle id over the same passage) replaces the old block, keeping its tags.
        x.annotations = ["B1": [Self.annotation(95), Self.annotation(300)]]
        x.texts = ["B1": [95: ["Ishmael, some years ago."], 300: ["Later."]]]
        let moved = try await env.importer.run { _ in }
        #expect(moved.highlightsUpdated == 1 && moved.highlightsAdded == 0)
        let p3 = HighlightParser.parse(try env.text("Highlights/Moby Dick.md"), path: "p")
        #expect(p3.items.map(\.text) == ["Ishmael, some years ago.", "Later."])
        #expect(p3.items[0].meta.tags == ["sea"] && p3.items[0].isFavourite && p3.items[0].meta.position == 95)
        // A highlight deleted on the Kindle stays in the file, hidden from the day's draw.
        x.annotations = ["B1": [Self.annotation(300)]]
        let deleted = try await env.importer.run { _ in }
        #expect(deleted.highlightsHidden == 1 && deleted.booksWritten == 1)
        let p4 = HighlightParser.parse(try env.text("Highlights/Moby Dick.md"), path: "p")
        #expect(p4.items.count == 2 && p4.items[0].isHidden && p4.items[0].meta.tags == ["sea"] && !p4.items[1].isHidden)
        // Nothing further to do once it is hidden.
        let quiet = try await env.importer.run { _ in }
        #expect(quiet.highlightsHidden == 0 && quiet.booksWritten == 0)
        // A lost ledger does not duplicate what the file already holds.
        try? FileManager.default.removeItem(at: env.stateURL)
        let fresh = HighlightsImporter(extractor: x, library: env.library, stateURL: env.stateURL)
        _ = try await fresh.run { _ in }
        #expect(HighlightParser.parse(try env.text("Highlights/Moby Dick.md"), path: "p").items.map(\.text) == ["Ishmael, some years ago.", "Later."])
    }

    @Test func titleCollisionsEmptiesAndAccessErrors() async throws {
        let env = try Self.env()
        defer { try? FileManager.default.removeItem(at: env.tmp) }
        let x = env.extractor
        x.books = [Self.book("B1", "Same: Title"), Self.book("B2", "Same: Title")]
        x.annotations = ["B1": [Self.annotation(1), Self.annotation(2)], "B2": [Self.annotation(1)]]
        x.texts = ["B1": [1: ["One"]], "B2": [1: ["Two"]]]
        let report = try await env.importer.run { _ in }
        #expect(report.empties == 1)
        let state = HighlightsState.load(from: env.stateURL)
        #expect(Set(state.books.values.map(\.path)) == ["Highlights/Same_ Title.md", "Highlights/Same_ Title (2).md"])
        #expect(state.annotations["B1/kindle.highlight-2"]?.empty == true)
        x.extractCalls = []
        _ = try await env.importer.run { _ in }
        #expect(x.extractCalls.isEmpty)   // the empty range is not retried

        x.listingError = .accessDenied("blocked")
        await #expect(throws: ExtractionFailure.accessDenied("blocked")) { try await env.importer.run { _ in } }
    }
}

@Suite struct DailyPicksTests {
    static func items(_ n: Int, favourites: Set<Int> = [], hidden: Set<Int> = []) -> [HighlightItem] {
        (0..<n).map { i in
            HighlightItem(path: "Highlights/b\(i % 5).md", line: i, metaLine: i + 1, bookTitle: "B", bookAuthor: "",
                          paragraphs: ["Quote \(i)"], note: nil,
                          meta: HighlightMeta(position: i, isFavourite: favourites.contains(i), isHidden: hidden.contains(i)))
        }
    }

    @Test func sameDaySamePicksDifferentDaysDiffer() {
        let items = Self.items(200, hidden: [3, 4])
        var h1 = DailyPickHistory(), h2 = DailyPickHistory()
        let a = DailyPicks.picks(items, day: "2026-09-26", history: &h1)
        let b = DailyPicks.picks(items, day: "2026-09-26", history: &h2)
        #expect(a.count == 3 && a == b)
        #expect(Set(a.map(\.contentKey)).count == 3)
        #expect(Set(a.map(\.path)).count == 3)   // three different books when there are enough
        #expect(h1.days["2026-09-26"] == a.map(\.contentKey))
        let c = DailyPicks.picks(items, day: "2026-09-27", history: &h1)
        #expect(c != a)
        #expect(!a.contains { $0.isHidden } && !c.contains { $0.isHidden })
        // Fewer eligible items than picks.
        var h3 = DailyPickHistory()
        #expect(DailyPicks.picks(Self.items(2), day: "2026-09-26", history: &h3).count == 2)
        #expect(DailyPicks.picks([], day: "2026-09-26", history: &h3).isEmpty)
    }

    @Test func favouritesComeUpMoreAndRecentOnesLess() {
        let items = Self.items(100, favourites: Set(0..<10))
        var favouriteHits = 0
        for day in 0..<500 {
            var h = DailyPickHistory()
            let picks = DailyPicks.picks(items, day: String(format: "2026-%02d-%02d", day % 12 + 1, day % 28 + 1) + "-\(day)", history: &h)
            favouriteHits += picks.filter(\.isFavourite).count
        }
        // 10% of items carry 3× weight: about a quarter of picks, well above the 10% of an unweighted draw.
        #expect(favouriteHits > 500 * 3 / 6 && favouriteHits < 500 * 3 / 2)

        let plain = Self.items(100)
        let shown = Set(plain.prefix(50).map(\.contentKey))
        var count = 0
        for day in 0..<300 {
            let ranked = DailyPicks.ranked(plain, day: "d\(day)", recent: shown)
            count += ranked.prefix(3).filter { shown.contains($0.contentKey) }.count
        }
        // Half the items are recent at a quarter of the weight: about a fifth of the picks, never none.
        #expect(count > 900 / 12 && count < 900 / 3)
    }

    @Test func pinnedPicksSurviveAndHidingPromotesTheNext() {
        let items = Self.items(50)
        var history = DailyPickHistory()
        let first = DailyPicks.picks(items, day: "2026-09-26", history: &history)
        // More items arrive; the day's picks stay.
        let more = items + Self.items(80).map { var i = $0; i.path = "Highlights/other.md"; i.line += 1000; i.paragraphs = ["Other \(i.line)"]; return i }
            .map { HighlightItem(path: $0.path, line: $0.line, metaLine: $0.line + 1, bookTitle: "B", bookAuthor: "", paragraphs: $0.paragraphs, note: nil, meta: $0.meta) }
        #expect(DailyPicks.picks(more, day: "2026-09-26", history: &history) == first)
        // Hiding one replaces just that slot.
        var hidden = more
        if let i = hidden.firstIndex(where: { $0.id == first[1].id }) { hidden[i].meta.isHidden = true }
        let after = DailyPicks.picks(hidden, day: "2026-09-26", history: &history)
        #expect(after.count == 3 && after[0] == first[0] && after[1] == first[2] && !first.contains(after[2]))
        #expect(history.days["2026-09-26"] == after.map(\.contentKey))
        // Recent keys come from earlier days within the window only.
        history.days["2026-09-01"] = ["old"]; history.days["2026-06-01"] = ["ancient"]
        #expect(DailyPicks.recentKeys(history, before: "2026-09-26") == ["old"])
        history.prune(keeping: 2)
        #expect(history.days.keys.sorted() == ["2026-09-01", "2026-09-26"])
    }
}
