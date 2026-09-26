import Foundation

/// What the Kindle app stores for a book: the pieces the importer needs.
public enum KindleFormat: Equatable, Sendable {
    case mobi, kfx, pdf
    case other(String)

    init(mimeType: String) {
        switch mimeType {
        case "application/x-mobipocket-ebook": self = .mobi
        case "application/x-kfx-ebook": self = .kfx
        case "application/pdf": self = .pdf
        default: self = .other(mimeType)
        }
    }
}

public struct KindleBook: Identifiable, Equatable, Sendable {
    /// The Kindle's book id (`ZBOOKID` without its `A:`/`-0` wrapping); the
    /// first part of every annotation's `dataset_id`.
    public var id: String
    public var title: String
    public var author: String
    public var format: KindleFormat
    /// The `.azw` file (MOBI) or the book's directory (KFX).
    public var fileURL: URL
    /// The app's own idea of the last position: must equal what the file decodes to.
    public var maxPosition: Int?
    public var isDictionary: Bool
    public var isDownloaded: Bool

    public init(id: String, title: String, author: String, format: KindleFormat, fileURL: URL,
                maxPosition: Int?, isDictionary: Bool = false, isDownloaded: Bool = true) {
        self.id = id; self.title = title; self.author = author; self.format = format; self.fileURL = fileURL
        self.maxPosition = maxPosition; self.isDictionary = isDictionary; self.isDownloaded = isDownloaded
    }
}

public struct KindleAnnotation: Equatable, Sendable {
    public enum Kind: String, Sendable { case highlight, underline }
    /// The Kindle's `annotation_id` ("kindle.highlight-<start>").
    public var id: String
    public var kind: Kind
    /// Inclusive positions: byte offsets into the MOBI text, or KFX pids.
    public var start: Int
    public var end: Int
    public var created: Date?
    public var modified: Date?
    public var color: String?
    /// A typed note the Kindle placed inside this highlight.
    public var note: String?

    public init(id: String, kind: Kind, start: Int, end: Int, created: Date?, modified: Date?, color: String? = nil, note: String? = nil) {
        self.id = id; self.kind = kind; self.start = start; self.end = end
        self.created = created; self.modified = modified; self.color = color; self.note = note
    }
}

/// Everything the Kindle app knows, read in one go.
public struct KindleListing: Sendable {
    public var books: [KindleBook]
    /// Annotations by book id, in position order.
    public var annotations: [String: [KindleAnnotation]]
    public init(books: [KindleBook], annotations: [String: [KindleAnnotation]]) {
        self.books = books; self.annotations = annotations
    }
}

public enum ExtractionFailure: Error, Equatable, Sendable {
    /// The Kindle app's container could not be read (Full Disk Access).
    case accessDenied(String)
    case notDownloaded
    case unsupportedFormat(String)
    case encrypted
    case huffCompression
    /// The file decodes to a different length than the app's max position: positions would not line up.
    case positionMismatch(book: Int, file: Int)
    /// Calibre or its KFX Input plugin is missing.
    case kfxUnavailable(String)
    case kfxFailed(String)
    case unreadable(String)

    public var message: String {
        switch self {
        case .accessDenied(let why): return "Can't read the Kindle app's files: \(why)"
        case .notDownloaded: return "not downloaded in the Kindle app"
        case .unsupportedFormat(let f): return "unsupported format (\(f))"
        case .encrypted: return "the book file is encrypted"
        case .huffCompression: return "HUFF/CDIC compression is not supported"
        case .positionMismatch(let book, let file): return "positions don't line up (app \(book), file \(file))"
        case .kfxUnavailable(let why): return why
        case .kfxFailed(let why): return "KFX decoding failed: \(why)"
        case .unreadable(let why): return why
        }
    }
}

public struct ExtractedHighlight: Equatable, Sendable {
    public var annotationID: String
    public var paragraphs: [String]
    public var note: String?
    public var position: Int
    public var created: Date?
    public var modified: Date?

    public init(annotationID: String, paragraphs: [String], note: String?, position: Int, created: Date?, modified: Date?) {
        self.annotationID = annotationID; self.paragraphs = paragraphs; self.note = note
        self.position = position; self.created = created; self.modified = modified
    }
}

public struct ExtractedBook: Sendable {
    public var book: KindleBook
    public var coverJPEG: Data?
    public var highlights: [ExtractedHighlight]
    /// Annotations whose range held no text (images, empty selections).
    public var emptyCount: Int

    public init(book: KindleBook, coverJPEG: Data?, highlights: [ExtractedHighlight], emptyCount: Int) {
        self.book = book; self.coverJPEG = coverJPEG; self.highlights = highlights; self.emptyCount = emptyCount
    }
}

/// Where highlights come from. The native reader is the only implementation;
/// the boundary lets tests (or another tool) stand in for the Kindle app.
public protocol KindleExtracting: Sendable {
    func listing() async throws -> KindleListing
    /// Decode ahead of time whatever needs one expensive pass for several
    /// books (the KFX helper); `extract` then reads from the cache.
    func prepare(_ books: [KindleBook], progress: @Sendable @escaping (String) -> Void) async
    func extract(_ book: KindleBook, annotations: [KindleAnnotation], wantsCover: Bool) async throws -> ExtractedBook
}
