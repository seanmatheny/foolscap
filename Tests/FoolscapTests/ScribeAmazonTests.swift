import Testing
import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapScribe

// MARK: - Fixtures

/// A ustar archive built by hand, so the reader's edge cases can be exercised.
enum TarBuilder {
    static func header(name: String, prefix: String = "", size: Int, typeflag: UInt8 = UInt8(ascii: "0")) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, at: Int, length: Int) {
            for (i, b) in s.utf8.prefix(length).enumerated() { h[at + i] = b }
        }
        put(name, at: 0, length: 100)
        put("0000644", at: 100, length: 8)
        put("0000000", at: 108, length: 8)
        put("0000000", at: 116, length: 8)
        put(String(format: "%011o", size), at: 124, length: 12)
        put("00000000000", at: 136, length: 12)
        h[156] = typeflag
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        put(prefix, at: 345, length: 155)
        for i in 148..<156 { h[i] = 32 }
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), at: 148, length: 6)
        h[154] = 0; h[155] = 32
        return h
    }

    static func archive(_ members: [(name: String, data: Data, typeflag: UInt8, prefix: String)]) -> Data {
        var out = Data()
        for m in members {
            out.append(contentsOf: header(name: m.name, prefix: m.prefix, size: m.data.count, typeflag: m.typeflag))
            out.append(m.data)
            let pad = (512 - m.data.count % 512) % 512
            out.append(Data(repeating: 0, count: pad))
        }
        out.append(Data(repeating: 0, count: 1024))
        return out
    }

    static func simple(_ files: [(String, Data)]) -> Data {
        archive(files.map { (name: $0.0, data: $0.1, typeflag: UInt8(ascii: "0"), prefix: "") })
    }
}

/// A small PNG with a 96 dpi stamp and a single dark mark, as Amazon's page images have.
func makePNG(width: Int, height: Int, dpi: Double = 96, mark: Int = 0) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 2 + mark, y: 2, width: 4, height: 4))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// MARK: - Tests

@Suite struct TarReaderTests {
    @Test func readsMembersInOrderJoiningThePrefix() throws {
        let tar = TarBuilder.archive([
            (name: "img_2.png", data: Data("two".utf8), typeflag: UInt8(ascii: "0"), prefix: ""),
            (name: "PaxHeader/x", data: Data("path=whatever".utf8), typeflag: UInt8(ascii: "x"), prefix: ""),
            (name: "img_10.png", data: Data(repeating: 7, count: 600), typeflag: 0, prefix: "deep/dir"),
            (name: "notes", data: Data(), typeflag: UInt8(ascii: "5"), prefix: ""),
        ])
        let members = try TarReader.members(in: tar)
        #expect(members.map(\.name) == ["img_2.png", "deep/dir/img_10.png"])
        #expect(members[1].data.count == 600)
        #expect(PDFBuilder.orderedPages(members).map(\.count) == [3, 600])
    }

    @Test func rejectsThingsThatAreNotTars() {
        #expect(throws: TarReader.ReadError.notATar) { try TarReader.members(in: Data("<html><body>Sign in</body></html>".utf8)) }
        #expect(throws: TarReader.ReadError.notATar) { try TarReader.members(in: Data(repeating: 1, count: 2000)) }
        #expect(throws: TarReader.ReadError.gzipped) { try TarReader.members(in: Data([0x1f, 0x8b, 8, 0])) }
        var truncated = TarBuilder.simple([("a.png", Data(repeating: 1, count: 100))])
        truncated = truncated.prefix(560)
        #expect(throws: TarReader.ReadError.truncated) { try TarReader.members(in: truncated) }
        #expect(throws: TarReader.ReadError.notATar) { try TarReader.members(in: Data(repeating: 0, count: 1024)) }
    }

    @Test func pageOrderUsesTheFirstDigitRun() {
        #expect(["img_10.png", "img_2.png", "page1.png", "x.png"].map(PDFBuilder.pageIndex) == [10, 2, 1, 0])
        let pages = PDFBuilder.orderedPages([.init(name: "img_10.png", data: Data([10])), .init(name: "img_2.png", data: Data([2])), .init(name: "cover.txt", data: Data())])
        #expect(pages == [Data([2]), Data([10])])
    }
}

@Suite struct PDFBuilderTests {
    @Test func buildsOnePageAtThePngsResolution() throws {
        let pngs = [makePNG(width: 1860, height: 2480), makePNG(width: 96, height: 48, mark: 3)]
        let pdf = try PDFBuilder.makePDF(pages: pngs)
        let doc = try #require(PDFDocument(data: pdf))
        #expect(doc.pageCount == 2)
        let first = doc.page(at: 0)!.bounds(for: .mediaBox)
        #expect(abs(first.width - 1395) < 0.01 && abs(first.height - 1860) < 0.01)
        let second = doc.page(at: 1)!.bounds(for: .mediaBox)
        #expect(second.width == 72 && second.height == 36)
        #expect(PDFBuilder.contentHash(pngs) != PDFBuilder.contentHash(pngs.reversed()))
        #expect(PDFBuilder.contentHash(pngs).count == 64)
    }
}

@Suite struct ScribeClientParsingTests {
    @Test func decodesListingAndOpenedNotebook() throws {
        let listing = #"{"itemsList":[{"id":"f1","title":"Work","type":"folder","items":[{"id":"n1","title":"todo","type":"notebook","items":[]}]},{"id":"n2","title":"Loose","type":"notebook"}]}"#
        let items = try JSONDecoder().decode(RemoteListing.self, from: Data(listing.utf8)).itemsList
        #expect(items.map(\.id) == ["f1", "n2"])
        #expect(items[0].isFolder && items[0].items?.first?.isNotebook == true)
        let opened = try JSONDecoder().decode(OpenedNotebook.self, from: Data(#"{"renderingToken":"tok","metadata":{"modificationTime":1790057223,"totalPages":3,"other":1}}"#.utf8))
        #expect(opened.renderingToken == "tok" && opened.modificationTime == 1790057223 && opened.metadata.totalPages == 3)
        let millis = try JSONDecoder().decode(OpenedNotebook.self, from: Data(#"{"renderingToken":"t","metadata":{"modificationTime":1790057223000,"totalPages":1}}"#.utf8))
        #expect(millis.modificationTime == 1790057223)
    }

    @Test func ocrCacheKeysOnContentAndLanguages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-ocr-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OCRCache(directory: dir)
        let result = OCRResult(engine: "vision-text-accurate", languages: ["en-US"], pages: [OCRPage(page: 1, width: 10, height: 10, observations: [fragment("hi", 0.1, 0.1)])])
        let key = OCRCacheKey(contentHash: "abc", languages: ["en-US"])
        #expect(cache.load(id: "n/1", key: key) == nil)
        try cache.store(result, id: "n/1", key: key)
        #expect(cache.load(id: "n/1", key: key) == result)
        #expect(cache.load(id: "n/1", key: OCRCacheKey(contentHash: "abc", languages: ["en-GB"])) == nil)
        #expect(cache.load(id: "n/1", key: OCRCacheKey(contentHash: "abd", languages: ["en-US"])) == nil)
        cache.remove(id: "n/1")
        #expect(cache.load(id: "n/1", key: key) == nil)
    }

    @Test func helperIsLocatableAndRecognisesASyntheticPage() async throws {
        guard let helper = ProcessOCRRunner.locateHelper() else {
            Issue.record("scribe-ocr helper not built; run `make app-debug` first")
            return
        }
        let pdf = try PDFBuilder.makePDF(pages: [makePNG(width: 300, height: 200)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-ocr-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try pdf.write(to: url)
        let result = try await ProcessOCRRunner(helperURL: helper).recognise(pdf: url, languages: ["en-US"])
        #expect(result.pages.count == 1 && result.pages[0].width == 300)
    }
}

// MARK: - End to end with a fake Kindle

final class FakeScribeClient: ScribeClient, @unchecked Sendable {
    var listing: [RemoteItem] = []
    var opened: [String: OpenedNotebook] = [:]
    var pages: [String: [Data]] = [:]
    var renders = 0
    var signedOut = false
    var offline = false
    var badTarsFirst = 0

    func listNotebooks() async throws -> [RemoteItem] {
        if signedOut { throw ScribeClientError.signedOut }
        return listing
    }
    func openNotebook(id: String) async throws -> OpenedNotebook {
        if offline { throw URLError(.notConnectedToInternet) }
        guard let o = opened[id] else { throw ScribeClientError.http(404) }
        return o
    }
    func renderPages(token: String, pageCount: Int) async throws -> Data {
        renders += 1
        if badTarsFirst > 0 { badTarsFirst -= 1; return Data("<html>nope</html>".utf8) }
        let pngs = pages[token] ?? []
        return TarBuilder.simple(pngs.enumerated().map { ("img_\($0.offset).png", $0.element) })
    }
}

struct FakeOCR: OCRRunning {
    let observations: [[OCRObservation]]
    func recognise(pdf: URL, languages: [String]) async throws -> OCRResult {
        OCRResult(engine: "fake", languages: languages,
                  pages: observations.enumerated().map { OCRPage(page: $0.offset + 1, width: 10, height: 10, observations: $0.element) })
    }
}

/// A clock the tests can move between passes.
final class TestClock: @unchecked Sendable {
    var now: Double
    init(_ now: Double) { self.now = now }
}

/// One notebook, edited a minute ago, with a fake Kindle serving `pages`.
@MainActor
func makePacingEngine(in tmp: URL, clock: TestClock) -> (ScribeSyncEngine, FakeScribeClient) {
    let client = FakeScribeClient()
    client.listing = [RemoteItem(id: "n1", title: "Diary", type: "notebook")]
    client.opened["n1"] = OpenedNotebook(renderingToken: "t1", metadata: .init(modificationTime: clock.now - 60, totalPages: 1))
    client.pages["t1"] = [makePNG(width: 40, height: 40)]
    let engine = ScribeSyncEngine(client: client, ocr: FakeOCR(observations: [[]]),
                                  cache: OCRCache(directory: tmp.appendingPathComponent("OCR")),
                                  stateURL: tmp.appendingPathComponent("state.json"), sink: MemorySink(),
                                  now: { Date(timeIntervalSince1970: clock.now) }, sleep: { _ in })
    return (engine, client)
}

@Suite @MainActor struct ScribeSyncEngineTests {
    @Test func firstPassWritesFilesTranscriptAndTask() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        library.indexesScribe = true

        let client = FakeScribeClient()
        client.listing = [RemoteItem(id: "f1", title: "Work", type: "folder", items: [RemoteItem(id: "n1", title: "to/do", type: "notebook")])]
        client.opened["n1"] = OpenedNotebook(renderingToken: "tok1", metadata: .init(modificationTime: 1_700_000_000, totalPages: 2))
        client.pages["tok1"] = [makePNG(width: 60, height: 80), makePNG(width: 60, height: 80, mark: 5)]
        let ocr = FakeOCR(observations: [[fragment("TODO: Wash the car", 0.05, 0.1), fragment("#hashtag noise", 0.05, 0.2)], []])
        let engine = ScribeSyncEngine(client: client, ocr: ocr, cache: OCRCache(directory: tmp.appendingPathComponent("OCR")),
                                      stateURL: tmp.appendingPathComponent("state.json"), sink: LibraryTaskSink(library: library),
                                      now: { Date(timeIntervalSince1970: 1_700_000_100) }, sleep: { _ in })

        let report = try await engine.syncOnce(notesRoot: folder.root, languages: ["en-US"])
        #expect(report == { var r = SyncReport(); r.rendered = 1; r.transcribed = 1; r.tasksAdded = 1; return r }())
        let pdfURL = folder.scribeDirectory.appendingPathComponent("Work/to_do.pdf")
        let mdURL = folder.scribeDirectory.appendingPathComponent("Work/to_do.md")
        #expect(PDFDocument(url: pdfURL)?.pageCount == 2)
        let transcript = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(transcript.hasPrefix("# to/do\n#scribe\n\n## Page 1\n\n**TODO:** Wash the car\n\\#hashtag noise\n\n## Page 2\n\n*No handwriting"))
        #expect(try String(contentsOf: folder.tasksFile, encoding: .utf8).hasSuffix("- [ ] Wash the car #scribe\n  From Work/to_do, p. 1\n"))
        let state = await engine.state
        #expect(state.items["n1"]?.todos.keys.sorted() == ["wash the car"])
        #expect(state.items["n1"]?.totalPages == 2 && state.items["f1"]?.isFolder == true)

        await library.rescan()
        #expect(try library.index.allNoteRecords().map(\.path).contains("Scribe/Work/to_do.md"))
        #expect(try library.index.allTags().contains("scribe"))
        #expect(try library.index.searchNotes("wash", scope: .under("Scribe/")).count == 1)
        #expect(try library.index.tasks().map(\.source.path) == ["Tasks.md"])

        // Second pass: edited 100 s ago, so the pages are fetched again (72 h recheck) but
        // the pixels match: no rebuild, no transcript, no new task.
        let again = try await engine.syncOnce(notesRoot: folder.root, languages: ["en-US"])
        #expect(again == SyncReport())
        #expect(client.renders == 2)
    }

    @Test func recheckRenameAndPrune() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-sync2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Notes")
        let client = FakeScribeClient()
        let now = 1_700_000_000.0
        client.listing = [RemoteItem(id: "n1", title: "Diary", type: "notebook"), RemoteItem(id: "n2", title: "Old", type: "notebook")]
        client.opened["n1"] = OpenedNotebook(renderingToken: "t1", metadata: .init(modificationTime: now - 60, totalPages: 1))
        client.opened["n2"] = OpenedNotebook(renderingToken: "t2", metadata: .init(modificationTime: 1, totalPages: 1))
        client.pages["t1"] = [makePNG(width: 40, height: 40)]
        client.pages["t2"] = [makePNG(width: 40, height: 40)]
        let sink = MemorySink()
        let engine = ScribeSyncEngine(client: client, ocr: FakeOCR(observations: [[fragment("TODO: call Bob", 0.05, 0.1)]]),
                                      cache: OCRCache(directory: tmp.appendingPathComponent("OCR")),
                                      stateURL: tmp.appendingPathComponent("state.json"), sink: sink,
                                      now: { Date(timeIntervalSince1970: now) }, sleep: { _ in })
        let first = try await engine.syncOnce(notesRoot: root, languages: ["en-US"])
        #expect(first.rendered == 2 && first.tasksAdded == 2 && client.renders == 2)

        // Edited within 72 h: fetched again every pass, rebuilt only when the pixels differ.
        _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"])
        #expect(client.renders == 3)
        var state = await engine.state
        let hashBefore = state.items["n1"]?.contentHash
        client.pages["t1"] = [makePNG(width: 40, height: 40, mark: 9)]
        client.badTarsFirst = 1   // one bad response, then the tar: retried, not failed
        let third = try await engine.syncOnce(notesRoot: root, languages: ["en-US"])
        #expect(third.rendered == 1 && third.errors.isEmpty)
        state = await engine.state
        #expect(state.items["n1"]?.contentHash != hashBefore)
        #expect(sink.lines.count == 2)   // the same TODO was not added again

        // Renamed on the Kindle and moved into a folder: files move, nothing re-renders.
        client.listing = [RemoteItem(id: "f", title: "Personal", type: "folder", items: [RemoteItem(id: "n1", title: "Journal", type: "notebook")])]
        client.opened["n1"] = OpenedNotebook(renderingToken: "t1", metadata: .init(modificationTime: 1, totalPages: 1))
        let fourth = try await engine.syncOnce(notesRoot: root, languages: ["en-US"])
        #expect(fourth.rendered == 0 && fourth.pruned == 1)
        let scribe = root.appendingPathComponent("Scribe")
        #expect(FileManager.default.fileExists(atPath: scribe.appendingPathComponent("Personal/Journal.pdf").path))
        #expect(FileManager.default.fileExists(atPath: scribe.appendingPathComponent("Personal/Journal.md").path))
        #expect(!FileManager.default.fileExists(atPath: scribe.appendingPathComponent("Diary.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: scribe.appendingPathComponent("Old.pdf").path))
        state = await engine.state
        #expect(state.items["n2"] == nil && state.items["n1"]?.path == "Personal/Journal" && state.items["n1"]?.todos.count == 1)

        // A lapsed session aborts the pass and leaves state alone.
        client.signedOut = true
        await #expect(throws: ScribeClientError.signedOut) { try await engine.syncOnce(notesRoot: root, languages: ["en-US"]) }
        #expect(await engine.state == state)
    }

    @Test func syncNowFetchesPastThePacedRecheck() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-pacing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Notes")
        let clock = TestClock(1_700_000_000)
        let (engine, client) = makePacingEngine(in: tmp, clock: clock)

        // The first pass renders; the next two are the eager rechecks and find the same pixels.
        for _ in 0..<3 { _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"]) }
        #expect(client.renders == 3)
        #expect(await engine.state.items["n1"]?.unchangedFetches == 2)

        // Paced: a scheduled pass inside the recheck interval leaves the notebook alone…
        clock.now += 60
        _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"])
        #expect(client.renders == 3)

        // …but Sync Now fetches it and picks up the page Amazon finally serves.
        client.pages["t1"] = [makePNG(width: 40, height: 40, mark: 9)]
        let manual = try await engine.syncOnce(notesRoot: root, languages: ["en-US"], recheckAll: true)
        #expect(client.renders == 4 && manual.rendered == 1)

        // The rebuild starts the eager rechecks over; once used up, the schedule waits out the interval.
        for _ in 0..<3 { _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"]) }
        #expect(client.renders == 6)
        clock.now += ScribeSyncEngine.recheckInterval
        _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"])
        #expect(client.renders == 7)
    }

    @Test func keepsFetchingWhileAmazonServesOldImagesForAnEdit() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-lag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Notes")
        let clock = TestClock(1_700_000_000)
        let (engine, client) = makePacingEngine(in: tmp, clock: clock)
        for _ in 0..<4 { _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"]) }
        #expect(client.renders == 3)   // rendered, two eager rechecks, then paced

        // Amazon stamps a new edit but still serves the old page: every pass fetches
        // until the images change, instead of two passes and then a two-hour wait.
        client.opened["n1"] = OpenedNotebook(renderingToken: "t1", metadata: .init(modificationTime: clock.now + 10, totalPages: 1))
        clock.now += 20
        for _ in 0..<3 { _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"]) }
        #expect(client.renders == 6)
        #expect(await engine.state.items["n1"]?.awaitingImages == true)

        client.pages["t1"] = [makePNG(width: 40, height: 40, mark: 9)]
        let caughtUp = try await engine.syncOnce(notesRoot: root, languages: ["en-US"])
        #expect(caughtUp.rendered == 1 && client.renders == 7)
        #expect(await engine.state.items["n1"]?.awaitingImages == false)

        // Back to the pacing: two eager rechecks, then nothing until the interval passes.
        for _ in 0..<3 { _ = try await engine.syncOnce(notesRoot: root, languages: ["en-US"]) }
        #expect(client.renders == 9)
    }

    @Test func offlineAbortsThePassInsteadOfReportingEachNotebook() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let client = FakeScribeClient()
        client.listing = [RemoteItem(id: "n1", title: "A", type: "notebook"), RemoteItem(id: "n2", title: "B", type: "notebook")]
        client.offline = true
        let engine = ScribeSyncEngine(client: client, ocr: FakeOCR(observations: []),
                                      cache: OCRCache(directory: tmp.appendingPathComponent("OCR")),
                                      stateURL: tmp.appendingPathComponent("state.json"), sink: MemorySink(), sleep: { _ in })
        await #expect(throws: URLError.self) { try await engine.syncOnce(notesRoot: tmp.appendingPathComponent("Notes"), languages: ["en-US"]) }
        #expect(await engine.state.lastSync == nil)

        #expect(ScribeClientError.isOffline(URLError(.notConnectedToInternet)))
        #expect(ScribeClientError.isOffline(URLError(.networkConnectionLost)))
        #expect(!ScribeClientError.isOffline(URLError(.badServerResponse)))
        #expect(!ScribeClientError.isOffline(ScribeClientError.http(500)))
    }
}
