import AppKit
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A rendered page bitmap. NSImage is not marked Sendable, but nothing
/// mutates one after it leaves the renderer.
struct RenderedPage: @unchecked Sendable {
    let image: NSImage
}

/// Draws notebook pages at the width the page view needs, one document open
/// at a time. PDFKit is not safe to use from several threads at once, so all
/// drawing is serialised here; the memory cache is bounded by memory cost.
///
/// Page sizes and bitmaps are also kept on disk: iCloud Drive evicts the PDFs
/// to save space, and opening an evicted one waits seconds for the download,
/// so after a relaunch the pages are shown from the cache without the PDF.
actor ScribePageRenderer {
    /// Open documents by notebook id, with the version they were opened at: a
    /// sync that rebuilds the PDF changes the version, and the file is reopened.
    private var documents: [String: (version: String, document: PDFDocument)] = [:]
    private let cache: NSCache<NSString, RenderedPageBox> = {
        let c = NSCache<NSString, RenderedPageBox>()
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()
    private let diskDirectory: URL?

    init(diskDirectory: URL? = ScribePaths.pageCacheDirectory) {
        self.diskDirectory = diskDirectory
    }

    private final class RenderedPageBox {
        let page: RenderedPage
        init(_ page: RenderedPage) { self.page = page }
    }

    private func document(id: String, url: URL, version: String) -> PDFDocument? {
        if let open = documents[id], open.version == version { return open.document }
        guard let d = PDFDocument(url: url) else { return nil }
        documents[id] = (version, d)
        return d
    }

    // MARK: Disk cache

    /// One folder per notebook (Amazon ids are not file names); files are named
    /// by version, so a rebuilt PDF's pages never match the old ones.
    private func diskFolder(id: String) -> URL? {
        let name = SHA256.hash(data: Data(id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return diskDirectory?.appendingPathComponent(name, isDirectory: true)
    }

    private func sizesURL(id: String, version: String) -> URL? {
        diskFolder(id: id)?.appendingPathComponent("\(version).sizes.json")
    }

    private func bitmapURL(id: String, version: String, page index: Int, pixelWidth: Int) -> URL? {
        diskFolder(id: id)?.appendingPathComponent("\(version)-\(index)-\(pixelWidth).png")
    }

    /// Record the sizes of a newly opened version and drop the notebook's
    /// files from earlier versions.
    private func storeSizes(_ sizes: [CGSize], id: String, version: String) {
        guard let folder = diskFolder(id: id), let url = sizesURL(id: id, version: version),
              let data = try? JSONEncoder().encode(sizes) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        where !name.hasPrefix(version + ".") && !name.hasPrefix(version + "-") {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
        try? data.write(to: url, options: .atomic)
    }

    private func loadBitmap(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Decoded here rather than lazily on the main thread at first draw.
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Written off the actor (PNG encoding takes a while), to a temporary name
    /// first so a half-written file is never read back as a page.
    private nonisolated func saveBitmap(_ image: CGImage, to url: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
            guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { try? FileManager.default.removeItem(at: temp); return }
            if (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) == nil {
                try? FileManager.default.removeItem(at: temp)
            }
        }
    }

    // MARK: Pages

    /// Sizes recorded when this version of the PDF was last opened, without
    /// touching the PDF; nil if it never was.
    func cachedPageSizes(id: String, version: String) -> [CGSize]? {
        guard let url = sizesURL(id: id, version: version), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CGSize].self, from: data)
    }

    /// Media-box sizes in points, so the view can reserve space before drawing.
    func pageSizes(id: String, url: URL, version: String) -> [CGSize] {
        if let cached = cachedPageSizes(id: id, version: version) { return cached }
        guard let doc = document(id: id, url: url, version: version) else { return [] }
        let sizes = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).size }
        if !sizes.isEmpty { storeSizes(sizes, id: id, version: version) }
        return sizes
    }

    private func page(from image: CGImage, backingScale: CGFloat) -> RenderedPage {
        RenderedPage(image: NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / backingScale,
                                                                 height: CGFloat(image.height) / backingScale)))
    }

    /// A page already drawn at this width, from memory or disk; never opens the PDF.
    func cachedImage(id: String, version: String, page index: Int, width displayWidth: CGFloat, backingScale: CGFloat) -> RenderedPage? {
        let pixelWidth = Int(displayWidth * backingScale)
        let key = "\(id)|\(version)|\(index)|\(pixelWidth)" as NSString
        if let hit = cache.object(forKey: key) { return hit.page }
        guard let url = bitmapURL(id: id, version: version, page: index, pixelWidth: pixelWidth),
              let cg = loadBitmap(url) else { return nil }
        let rendered = page(from: cg, backingScale: backingScale)
        cache.setObject(RenderedPageBox(rendered), forKey: key, cost: cg.width * cg.height * 4)
        return rendered
    }

    /// `width` is the display width in points. The bitmap is drawn at that
    /// width times the backing scale and sized in points to match, so SwiftUI
    /// shows it 1:1 instead of resampling it on every display.
    func image(id: String, url: URL, version: String, page index: Int, width displayWidth: CGFloat, backingScale: CGFloat) -> RenderedPage? {
        if let hit = cachedImage(id: id, version: version, page: index, width: displayWidth, backingScale: backingScale) { return hit }
        // Requests queue up here; one whose page has scrolled away or whose
        // notebook was closed is dropped rather than drawn.
        guard !Task.isCancelled else { return nil }
        guard let doc = document(id: id, url: url, version: version), let page = doc.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let pixelWidth = displayWidth * backingScale
        let scale = pixelWidth / bounds.width
        let width = Int(pixelWidth.rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let rendered = self.page(from: cg, backingScale: backingScale)
        cache.setObject(RenderedPageBox(rendered), forKey: "\(id)|\(version)|\(index)|\(Int(pixelWidth))" as NSString,
                        cost: width * height * 4)
        if let file = bitmapURL(id: id, version: version, page: index, pixelWidth: Int(pixelWidth)) { saveBitmap(cg, to: file) }
        return rendered
    }

    /// Drop open documents other than the one being read.
    func release(except id: String?) {
        documents = documents.filter { $0.key == id }
    }

    func releaseAll() {
        documents.removeAll()
        cache.removeAllObjects()
    }
}
