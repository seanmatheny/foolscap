import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads the Kindle app's own files: its two databases, MOBI books directly,
/// KFX books through the cached Calibre decode.
public struct NativeKindleExtractor: KindleExtracting {
    public var dataDirectory: URL
    public var kfx: KFXExtractor

    public init(dataDirectory: URL = KindleLibrary.defaultDataDirectory, kfx: KFXExtractor = KFXExtractor()) {
        self.dataDirectory = dataDirectory
        self.kfx = kfx
    }

    public func listing() async throws -> KindleListing {
        let dir = dataDirectory
        return try await Task.detached(priority: .utility) {
            KindleListing(books: try KindleLibrary.books(dataDirectory: dir), annotations: try KindleAnnotations.annotations(dataDirectory: dir))
        }.value
    }

    public func prepare(_ books: [KindleBook], progress: @Sendable @escaping (String) -> Void) async {
        let directories = books.filter { $0.format == .kfx && $0.isDownloaded }.map(\.fileURL)
        guard !directories.isEmpty else { return }
        // Failures surface per book from `extract`, with the helper's reason or the availability message.
        _ = try? await kfx.prewarm(directories, progress: progress)
    }

    public func extract(_ book: KindleBook, annotations: [KindleAnnotation], wantsCover: Bool) async throws -> ExtractedBook {
        guard book.isDownloaded else { throw ExtractionFailure.notDownloaded }
        let kfx = self.kfx
        return try await Task.detached(priority: .utility) {
            switch book.format {
            case .mobi:
                let mobi = try MOBIBook(contentsOf: book.fileURL)
                return try Self.build(book: book, annotations: annotations, maxPosition: mobi.textLength,
                                      cover: wantsCover ? mobi.coverImage() : nil) { mobi.paragraphs(from: $0, to: $1) }
            case .kfx:
                let text = try kfx.load(book.fileURL)
                return try Self.build(book: book, annotations: annotations, maxPosition: text.maxPosition,
                                      cover: wantsCover ? kfx.cover(for: book.fileURL) : nil) { text.paragraphs(from: $0, to: $1) }
            case .pdf:
                throw ExtractionFailure.unsupportedFormat("PDF")
            case .other(let mime):
                throw ExtractionFailure.unsupportedFormat(mime)
            }
        }.value
    }

    private static func build(book: KindleBook, annotations: [KindleAnnotation], maxPosition: Int, cover: Data?,
                              paragraphs: (Int, Int) -> [String]) throws -> ExtractedBook {
        if let expected = book.maxPosition, expected != maxPosition {
            throw ExtractionFailure.positionMismatch(book: expected, file: maxPosition)
        }
        var highlights: [ExtractedHighlight] = []
        var empty = 0
        for a in annotations {
            let text = paragraphs(a.start, a.end)
            if text.isEmpty { empty += 1; continue }
            highlights.append(ExtractedHighlight(annotationID: a.id, paragraphs: text, note: a.note, position: a.start,
                                                 created: a.created, modified: a.modified))
        }
        return ExtractedBook(book: book, coverJPEG: cover.flatMap { CoverImage.jpeg(from: $0) }, highlights: highlights, emptyCount: empty)
    }
}

/// Covers go into the synced notes folder, so they are kept small.
public enum CoverImage {
    public static let maxHeight = 600

    public static func jpeg(from data: Data, maxHeight: Int = maxHeight) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxHeight,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
