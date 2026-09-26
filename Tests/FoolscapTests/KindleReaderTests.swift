import Testing
import Foundation
import GRDB
@testable import FoolscapCore
@testable import FoolscapHighlights

/// Builds a tiny PalmDB/MOBI file in memory: one text record (PalmDOC or
/// uncompressed) and an image record reachable through EXTH 201.
enum MOBIFixture {
    static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// A hand-made PalmDOC stream: literal bytes, one back-reference and one space+char byte.
    static let palmDocText = "<p>Call me Ishmael.</p><p>Some years ago&mdash;never mind how long&nbsp;precisely.</p>"
    static func palmDocCompressed() -> [UInt8] {
        // "<p>Call me " literally (each byte < 0x80 is itself), then "me " again via a back-reference
        // (distance 3, length 3), then "Ish" as a literal run (0x03 + 3 bytes), then " m" as 0xC0|'m'.
        var out: [UInt8] = Array("<p>Call me ".utf8)
        out.append(0x80 | UInt8((3 << 3) >> 8)); out.append(UInt8(((3 << 3) | 0) & 0xFF))   // distance 3, length 3 -> "me "
        out += [0x03] + Array("Ish".utf8)
        out.append(0xC0 | UInt8(ascii: "m"))
        return out
    }
    static let palmDocExpanded = "<p>Call me me Ish m"

    static func file(text: [UInt8], compression: Int, textLength: Int, encryption: Int = 0, encoding: Int = 65001,
                     extraFlags: Int = 0, trailing: [UInt8] = [], image: [UInt8]? = nil) -> [UInt8] {
        // Record 0: PalmDOC header (16 bytes) + MOBI header.
        let headerLength = 0xE8
        var rec0: [UInt8] = be16(compression) + be16(0) + be32(textLength) + be16(1) + be16(4096) + be16(encryption) + be16(0)
        var mobi = Array("MOBI".utf8) + be32(headerLength) + be32(2) + be32(encoding)
        while mobi.count < headerLength { mobi.append(0) }
        let firstImage = 2
        mobi.replaceSubrange(0x6C - 16..<0x70 - 16, with: be32(firstImage))
        if image != nil { mobi.replaceSubrange(0x80 - 16..<0x84 - 16, with: be32(0x40)) }
        mobi.replaceSubrange(0xF2 - 16..<0xF4 - 16, with: be16(extraFlags))
        rec0 += mobi
        if image != nil {
            let entry = be32(201) + be32(12) + be32(0)
            rec0 += Array("EXTH".utf8) + be32(12 + entry.count) + be32(1) + entry
        }
        var records: [[UInt8]] = [rec0, text + trailing]
        if let image { records.append(image) }
        var header: [UInt8] = Array(repeating: 0, count: 60) + Array("BOOKMOBI".utf8) + Array(repeating: 0, count: 8) + be16(records.count)
        var offset = 78 + 8 * records.count
        for (i, r) in records.enumerated() {
            header += be32(offset) + [0, 0, 0, UInt8(i)]
            offset += r.count
        }
        return header + records.flatMap { $0 }
    }
}

@Suite struct MOBIBookTests {
    @Test func readsUncompressedTextAndCover() throws {
        let text = Array(MOBIFixture.palmDocText.utf8)
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF] + Array(repeating: 0, count: 80)
        let book = try MOBIBook(bytes: MOBIFixture.file(text: text, compression: 1, textLength: text.count, image: jpeg))
        #expect(book.textLength == text.count)
        #expect(book.paragraphs(from: 0, to: text.count - 1) == ["Call me Ishmael.", "Some years ago—never mind how long precisely."])
        #expect(book.paragraphs(from: 3, to: 9) == ["Call me"])
        #expect(book.paragraphs(from: 500, to: 900).isEmpty)
        #expect(book.coverImage() == Data(jpeg))
    }

    @Test func decompressesPalmDocAndTrimsTrailingEntries() throws {
        let compressed = MOBIFixture.palmDocCompressed()
        #expect(String(decoding: MOBIBook.palmDocDecompress(compressed), as: UTF8.self) == MOBIFixture.palmDocExpanded)
        // extra_flags bit 1: one trailing entry of 3 bytes (its size byte counts itself).
        let trailing: [UInt8] = [0xAA, 0xBB, 0x83]
        let book = try MOBIBook(bytes: MOBIFixture.file(text: compressed, compression: 2, textLength: MOBIFixture.palmDocExpanded.utf8.count,
                                                        extraFlags: 0b10, trailing: trailing))
        #expect(book.paragraphs(from: 0, to: 100) == ["Call me me Ish m"])
        #expect(book.coverImage() == nil)
    }

    @Test func refusesEncryptedAndHuff() {
        let text = Array("<p>x</p>".utf8)
        #expect(throws: ExtractionFailure.encrypted) {
            try MOBIBook(bytes: MOBIFixture.file(text: text, compression: 1, textLength: text.count, encryption: 2))
        }
        #expect(throws: ExtractionFailure.huffCompression) {
            try MOBIBook(bytes: MOBIFixture.file(text: text, compression: 17480, textLength: text.count))
        }
        #expect(throws: ExtractionFailure.self) { try MOBIBook(bytes: [1, 2, 3]) }
    }

    @Test func stripsEntitiesAndCp1252() throws {
        let html = "<html><body><h1>Title</h1>Caf\u{E9} &amp; &#8220;quotes&#x201D; &shy;hy&unknown; <i>in</i>line<br/>next</body></html>"
        var bytes: [UInt8] = []
        for scalar in html.unicodeScalars { bytes.append(scalar.value < 0x80 ? UInt8(scalar.value) : 0xE9) }
        let book = try MOBIBook(bytes: MOBIFixture.file(text: bytes, compression: 1, textLength: bytes.count, encoding: 1252))
        #expect(book.paragraphs(from: 0, to: bytes.count - 1) == ["Title", "Café & “quotes” hy&unknown; inline", "next"])
    }
}

@Suite struct KFXTextTests {
    @Test func mapsPidsToText() throws {
        let json = #"{"max_position": 30, "chunks": [[10, "Hello\nworld 😀 end"], [0, "First"], [5, "Para"]]}"#
        let text = try KFXText(chunksJSON: Data(json.utf8))
        #expect(text.maxPosition == 30)
        #expect(text.paragraphs(from: 0, to: 4) == ["First"])
        #expect(text.paragraphs(from: 10, to: 14) == ["Hello"])
        // Each chunk is a paragraph: a range across chunks splits there; a gap between chunks yields nothing.
        #expect(text.paragraphs(from: 0, to: 12) == ["First", "Para", "Hel"])
        #expect(text.paragraphs(from: 9, to: 9).isEmpty)
        #expect(text.paragraphs(from: 12, to: 20) == ["llo", "world"])
        // The emoji is one position (one scalar), like Python's len().
        #expect(text.paragraphs(from: 22, to: 22) == ["😀"])
        #expect(text.paragraphs(from: 24, to: 26) == ["end"])
    }

    @Test func cacheKeyFollowsSizeAndMtime() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-kfx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let container = tmp.appendingPathComponent("CR!X.azw8")
        try Data("CONT12345".utf8).write(to: container)
        try Data("BOOK".utf8).write(to: tmp.appendingPathComponent("BookManifest.kfx"))
        #expect(KFXExtractor.container(in: tmp) == container)
        let key = try #require(KFXExtractor.cacheKey(for: container))
        #expect(key.count == 16)
        try Data("CONT1234567".utf8).write(to: container)
        #expect(KFXExtractor.cacheKey(for: container) != key)
        // Nothing decoded: loading reports the helper state rather than crashing.
        let extractor = KFXExtractor(cacheDirectory: tmp.appendingPathComponent("cache"))
        #expect(!extractor.isDecoded(tmp))
        #expect(throws: ExtractionFailure.self) { try extractor.load(tmp) }
    }
}

/// Stands in for the Kindle app's `SyncMetadataAttributes` when building a fixture archive.
@objc(FoolscapTestSyncMetadataAttributes)
final class FakeSyncMetadataAttributes: NSObject, NSCoding {
    let attributes: [String: Any]
    init(_ a: [String: Any]) { attributes = a }
    required init?(coder: NSCoder) { attributes = [:] }
    func encode(with coder: NSCoder) { coder.encode(attributes as NSDictionary, forKey: "attributes") }
}

@Suite struct KindleDBTests {
    /// A container laid out like the Kindle app's, with both databases.
    static func makeContainer() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-kindle-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: tmp.appendingPathComponent("Library/Protected"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("Library/KSDK/amzn1.account.TEST"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tmp.appendingPathComponent("Library/eBooks/B1"), withIntermediateDirectories: true)
        try Data([1]).write(to: tmp.appendingPathComponent("Library/eBooks/B1/book.azw"))

        let books = try DatabaseQueue(path: tmp.appendingPathComponent("Library/Protected/BookData.sqlite").path)
        try books.write { db in
            try db.execute(sql: """
                CREATE TABLE ZBOOK (ZBOOKID TEXT, ZDISPLAYTITLE TEXT, ZPATH TEXT, ZMIMETYPE TEXT, ZRAWMAXPOSITION INTEGER,
                                    ZRAWISDICTIONARY INTEGER, ZRAWBOOKSTATE INTEGER, ZSYNCMETADATAATTRIBUTES BLOB)
                """)
            let archive = try Self.archive(title: "Moby Dick", authors: ["author": "Herman Melville"])
            try db.execute(sql: "INSERT INTO ZBOOK VALUES (?,?,?,?,?,?,?,?)",
                           arguments: ["A:B1-0", "Moby Dick -- Herman Melville -- 2020 -- Anna's Archive", "Library/eBooks/B1/book.azw",
                                       "application/x-mobipocket-ebook", 1000, 0, 3, archive])
            try db.execute(sql: "INSERT INTO ZBOOK VALUES (?,?,?,?,?,?,?,?)",
                           arguments: ["A:B2-0", "Cloud Only -- Someone", "Library/eBooks/B2/x", "application/x-kfx-ebook", 5, 0, 0, nil])
            try db.execute(sql: "INSERT INTO ZBOOK VALUES (?,?,?,?,?,?,?,?)",
                           arguments: ["A:D1-0", "Dictionary", "Library/eBooks/D1/x.azw", "application/x-mobipocket-ebook", 5, 1, 3, Data([0, 1])])
        }
        try books.close()

        let annotations = try DatabaseQueue(path: tmp.appendingPathComponent("Library/KSDK/amzn1.account.TEST/ksdk_annotation_v1.db").path)
        try annotations.write { db in
            try db.execute(sql: """
                CREATE TABLE server_view (dataset INTEGER NOT NULL, dataset_id TEXT NOT NULL, annotation_id TEXT NOT NULL,
                    serialized_payload TEXT NOT NULL, created_time INTEGER NOT NULL, modified_time INTEGER NOT NULL,
                    PRIMARY KEY (annotation_id, dataset_id))
                """)
            func payload(_ start: Int, _ end: Int, type: String, meta: String = "{}") -> String {
                """
                {"book_data":{"asin":"B1"},"created_time":1700000000000,"end_position":{"longPosition":"","shortPosition":\(end)},
                 "json_metadata":"\(meta.replacingOccurrences(of: "\"", with: "\\\""))","last_modified":1700000001000,"position_type":0,
                 "start_position":{"longPosition":"","shortPosition":\(start)},"type":"\(type)"}
                """
            }
            let rows: [(Int, String, String)] = [
                (1, "kindle.highlight-100", payload(100, 200, type: "HIGHLIGHT", meta: #"{"mchl_color":"pink"}"#)),
                (12, "kindle.underline-300", payload(300, 350, type: "UNDERLINE")),
                (3, "kindle.note-150", payload(150, 150, type: "NOTE", meta: #"{"note_text":"inside"}"#)),
                (3, "kindle.note-350", payload(350, 350, type: "NOTE", meta: #"{"note_text":"at the end"}"#)),
                (3, "kindle.note-900", payload(900, 900, type: "NOTE", meta: #"{"note_text":"orphan"}"#)),
                (1, "kindle.highlight-bad", "not json"),
                (2, "kindle.bookmark-5", payload(5, 5, type: "BOOKMARK")),
            ]
            for (dataset, id, p) in rows {
                try db.execute(sql: "INSERT INTO server_view VALUES (?,?,?,?,?,?)", arguments: [dataset, "B1-PDOC-GUID-1", id, p, 1700000000000, 1700000001000])
            }
        }
        try annotations.close()
        return tmp
    }

    /// The Kindle's `SyncMetadataAttributes` archive, as NSKeyedArchiver writes it.
    static func archive(title: String, authors: Any) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("SyncMetadataAttributes", for: FakeSyncMetadataAttributes.self)
        archiver.encode(FakeSyncMetadataAttributes(["title": title, "authors": authors, "ASIN": "B1"]), forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    @Test func readsBooksAndAnnotations() throws {
        let container = try Self.makeContainer()
        defer { try? FileManager.default.removeItem(at: container) }
        let books = try KindleLibrary.books(dataDirectory: container)
        #expect(books.map(\.id) == ["B1", "B2", "D1"])
        let moby = books[0]
        #expect(moby.title == "Moby Dick" && moby.author == "Herman Melville")
        #expect(moby.format == .mobi && moby.isDownloaded && moby.maxPosition == 1000 && !moby.isDictionary)
        #expect(moby.fileURL.path.hasSuffix("Library/eBooks/B1/book.azw"))
        #expect(books[1].title == "Cloud Only" && books[1].author == "" && !books[1].isDownloaded && books[1].format == .kfx)
        #expect(books[2].isDictionary)

        let annotations = try KindleAnnotations.annotations(dataDirectory: container)
        let b1 = try #require(annotations["B1"])
        #expect(b1.map(\.id) == ["kindle.highlight-100", "kindle.underline-300"])
        #expect(b1[0].kind == .highlight && b1[0].start == 100 && b1[0].end == 200 && b1[0].color == "pink")
        #expect(b1[0].note == "inside")
        #expect(b1[1].kind == .underline && b1[1].note == "at the end")
        #expect(b1[0].created == Date(timeIntervalSince1970: 1700000000) && b1[0].modified == Date(timeIntervalSince1970: 1700000001))
        #expect(KindleLibrary.cleanTitle("Plain Title") == "Plain Title")
        typealias Clean = (title: String, author: String)
        func clean(_ t: String, _ a: String) -> Clean { KindleLibrary.cleanTitleAndAuthor(t, a, user: "Sean Matheny") }
        #expect(clean("Demon_Copperhead_-_Barbara_Kingsolver", "Sean Matheny") == Clean("Demon Copperhead", "Barbara Kingsolver"))
        #expect(clean("Stalin_ The Court of the Red Tsar", "Simon Sebag Montefiore") == Clean("Stalin: The Court of the Red Tsar", "Simon Sebag Montefiore"))
        #expect(clean("Capital And Ideology - Thomas Piketty", "Thomas Piketty") == Clean("Capital And Ideology", "Thomas Piketty"))
        #expect(clean("Stella Maris - Cormac McCarthy", "Sean Matheny") == Clean("Stella Maris", "Cormac McCarthy"))
        #expect(clean("Founding Brothers -  The  Revolutionary Generation", "Joseph J. Ellis") == Clean("Founding Brothers - The Revolutionary Generation", "Joseph J. Ellis"))
        #expect(clean("Dark Sun: The Making of the Hydrogen Bomb", "Sean Matheny") == Clean("Dark Sun: The Making of the Hydrogen Bomb", ""))
        #expect(clean("Moby Dick -- Herman Melville -- 1851 -- Anna's Archive", "Herman Melville") == Clean("Moby Dick", "Herman Melville"))
        #expect(KindleLibrary.bookID("A:XYZ-0") == "XYZ" && KindleLibrary.bookID("XYZ") == "XYZ")
    }

    @Test func missingDatabasesAreReported() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-nokindle-\(UUID().uuidString)")
        #expect(throws: ExtractionFailure.self) { try KindleLibrary.books(dataDirectory: tmp) }
        #expect(throws: ExtractionFailure.self) { try KindleAnnotations.annotations(dataDirectory: tmp) }
        #expect(!KindleLibrary.isInstalled(dataDirectory: tmp))
    }
}
