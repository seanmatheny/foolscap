import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Turns Amazon's page PNGs into the notebook PDF, one image per page at the
/// PNG's own resolution (the Scribe renders at 96 dpi).
public enum PDFBuilder {
    public enum BuildError: Error { case badImage(Int), contextFailed }

    /// Sort key for page images: the first run of digits in the name (tar member
    /// order is arbitrary).
    public static func pageIndex(_ name: String) -> Int {
        let base = (name as NSString).lastPathComponent
        guard let r = base.range(of: #"\d+"#, options: .regularExpression) else { return 0 }
        return Int(base[r]) ?? 0
    }

    public static func orderedPages(_ members: [TarReader.Member]) -> [Data] {
        members.filter { $0.name.hasSuffix(".png") }
            .enumerated()
            .sorted { (pageIndex($0.element.name), $0.offset) < (pageIndex($1.element.name), $1.offset) }
            .map(\.element.data)
    }

    /// Fingerprint a notebook's page images, in page order. Amazon returns
    /// identical bytes for an unchanged page, so this tells a stale render from a
    /// fresh one.
    public static func contentHash(_ pages: [Data]) -> String {
        var hasher = SHA256()
        for page in pages { hasher.update(data: page) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func makePDF(pages: [Data]) throws -> Data {
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output) else { throw BuildError.contextFailed }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw BuildError.contextFailed }
        for (index, png) in pages.enumerated() {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BuildError.badImage(index) }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let dpiX = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 96
            let dpiY = (props[kCGImagePropertyDPIHeight] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? dpiX
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpiX, height: Double(image.height) * 72 / dpiY)
            let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }
}
