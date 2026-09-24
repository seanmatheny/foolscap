import AppKit
import PDFKit

/// A rendered page bitmap. NSImage is not marked Sendable, but nothing
/// mutates one after it leaves the renderer.
struct RenderedPage: @unchecked Sendable {
    let image: NSImage
}

/// Draws notebook pages at the width the page view needs, one document open
/// at a time. PDFKit is not safe to use from several threads at once, so all
/// drawing is serialised here; the cache is bounded by memory cost.
actor ScribePageRenderer {
    /// Open documents by notebook id, with the version they were opened at: a
    /// sync that rebuilds the PDF changes the version, and the file is reopened.
    private var documents: [String: (version: String, document: PDFDocument)] = [:]
    private let cache: NSCache<NSString, RenderedPageBox> = {
        let c = NSCache<NSString, RenderedPageBox>()
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

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

    /// Media-box sizes in points, so the view can reserve space before drawing.
    func pageSizes(id: String, url: URL, version: String) -> [CGSize] {
        guard let doc = document(id: id, url: url, version: version) else { return [] }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).size }
    }

    /// `width` is the display width in points. The bitmap is drawn at that
    /// width times the backing scale and sized in points to match, so SwiftUI
    /// shows it 1:1 instead of resampling it on every display.
    func image(id: String, url: URL, version: String, page index: Int, width displayWidth: CGFloat, backingScale: CGFloat) -> RenderedPage? {
        let pixelWidth = displayWidth * backingScale
        let key = "\(id)|\(version)|\(index)|\(Int(pixelWidth))" as NSString
        if let hit = cache.object(forKey: key) { return hit.page }
        // Requests queue up here; one whose page has scrolled away or whose
        // notebook was closed is dropped rather than drawn.
        guard !Task.isCancelled else { return nil }
        guard let doc = document(id: id, url: url, version: version), let page = doc.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
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
        let rendered = RenderedPage(image: NSImage(cgImage: cg, size: NSSize(width: CGFloat(width) / backingScale,
                                                                           height: CGFloat(height) / backingScale)))
        cache.setObject(RenderedPageBox(rendered), forKey: key, cost: width * height * 4)
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
