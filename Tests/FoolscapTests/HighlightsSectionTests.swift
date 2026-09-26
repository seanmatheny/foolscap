import Testing
import Foundation
import AppKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapHighlights

@Suite struct ImportScheduleTests {
    @Test func startupImportFollowsTheSchedule() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        typealias S = HighlightsImportSchedule
        #expect(S.startupImportDue(.atLaunch, lastRun: now, now: now))
        #expect(S.startupImportDue(.hourly, lastRun: now, now: now))
        #expect(!S.startupImportDue(.manual, lastRun: nil, now: now))
        #expect(S.startupImportDue(.daily, lastRun: nil, now: now))
        #expect(!S.startupImportDue(.daily, lastRun: now.addingTimeInterval(-3600), now: now))
        #expect(S.startupImportDue(.daily, lastRun: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(S.daily.minutes == 1440 && S.atLaunch.minutes == nil)
    }
}

@Suite @MainActor struct CoverCacheTests {
    @Test func warmedCoversAreAvailableWithoutAHop() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-cover-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let image = NSImage(size: NSSize(width: 40, height: 60), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        try #require(CoverImage.jpeg(from: tiff)).write(to: tmp)
        let cache = CoverCache.shared
        #expect(cache.cached(for: tmp, maxPixels: 120) == nil)
        cache.warm([tmp], maxPixels: 120)
        for _ in 0..<50 where cache.cached(for: tmp, maxPixels: 120) == nil { try await Task.sleep(for: .milliseconds(40)) }
        let warmed = try #require(cache.cached(for: tmp, maxPixels: 120))
        #expect(warmed.size.height > 0 && warmed.size.height <= 120)
    }
}

@Suite @MainActor struct HighlightsSectionTests {
    static let book = """
        # Moby Dick
        Herman Melville
        #kindle

        > Call me Ishmael.
        > — pos 100 · #sea

        > It is a way I have of driving off the spleen.
        > — pos 200 · #sea #mood

        """

    func makeSection() throws -> (HighlightsSection, NotesFolder, URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-hsection-\(UUID().uuidString)")
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        try FileManager.default.createDirectory(at: folder.highlightsDirectory, withIntermediateDirectories: true)
        try Self.book.write(to: folder.highlightsDirectory.appendingPathComponent("Moby Dick.md"), atomically: true, encoding: .utf8)
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        library.indexesHighlights = true
        let defaults = UserDefaults(suiteName: "foolscap-tests-\(UUID().uuidString)")!
        defaults.set(HighlightsImportSchedule.manual.rawValue, forKey: HighlightsImportSchedule.key)
        let section = HighlightsSection(library: library, extractor: FakeExtractor(),
                                        stateURL: tmp.appendingPathComponent("state.json"), dailyURL: tmp.appendingPathComponent("daily.json"),
                                        defaults: defaults)
        return (section, folder, tmp)
    }

    @Test func loadsSearchesNavigatesAndEditsThroughTheFile() async throws {
        let (section, folder, tmp) = try makeSection()
        defer { try? FileManager.default.removeItem(at: tmp) }
        await section.library.rescan(full: true)
        await section.reload()
        #expect(section.items.count == 2 && section.books.map(\.title) == ["Moby Dick"])
        #expect(section.picks.count == 2)
        #expect(section.highlightTags == ["sea", "mood"])

        section.searchText = "spleen"
        #expect(section.searchResults.map(\.line) == [7])
        section.searchText = "#mood "
        #expect(section.searchResults.map(\.line) == [7])
        section.searchText = "ishmael #se"
        #expect(section.searchResults.map(\.line) == [4])
        section.searchText = "melville"
        #expect(section.searchResults.count == 2)
        let hits = try await section.searchProvider!.search("driving", limit: 10)
        #expect(hits.map(\.route.line) == [7] && hits[0].title == "Moby Dick · Herman Melville")

        section.navigate(to: SectionRoute(path: "Highlights/Moby Dick.md", line: 7))
        #expect(section.mode == .book("Highlights/Moby Dick.md") && section.searchText.isEmpty)
        #expect(section.pendingHighlightID == "Highlights/Moby Dick.md#L7")

        let item = section.items[0]
        section.toggleFavourite(item)
        section.addTag("Whale", to: item)
        #expect(section.items[0].isFavourite && section.items[0].tags == ["sea", "whale"])
        section.setHidden(section.items[1], true)
        #expect(section.picks.map(\.line) == [4])
        // The writes land one after another, then the index; wait for the last one.
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(50))
            if (try? section.library.index.highlights())?.last?.isHidden == true { break }
        }
        let text = try String(contentsOf: folder.url(forRelativePath: "Highlights/Moby Dick.md"), encoding: .utf8)
        #expect(text.contains("> Call me Ishmael.\n> — pos 100 · #sea #whale ♥\n"))
        #expect(text.contains("> — pos 200 · #sea #mood hidden\n"))
        let indexed = try section.library.index.highlights()
        #expect(indexed[0].isFavourite && indexed[0].tags == ["sea", "whale"] && indexed[1].isHidden)
        section.stop()
    }
}
