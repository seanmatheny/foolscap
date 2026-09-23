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
    private var documents: [String: PDFDocument] = [:]
    private let cache: NSCache<NSString, RenderedPageBox> = {
        let c = NSCache<NSString, RenderedPageBox>()
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    private final class RenderedPageBox {
        let page: RenderedPage
        init(_ page: RenderedPage) { self.page = page }
    }

    private func document(id: String, url: URL) -> PDFDocument? {
        if let d = documents[id] { return d }
        guard let d = PDFDocument(url: url) else { return nil }
        documents[id] = d
        return d
    }

    /// Media-box sizes in points, so the view can reserve space before drawing.
    func pageSizes(id: String, url: URL) -> [CGSize] {
        guard let doc = document(id: id, url: url) else { return [] }
        return (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).size }
    }

    /// `pixelWidth` is the display width times the backing scale.
    func image(id: String, url: URL, version: String, page index: Int, pixelWidth: CGFloat) -> RenderedPage? {
        let key = "\(id)|\(version)|\(index)|\(Int(pixelWidth))" as NSString
        if let hit = cache.object(forKey: key) { return hit.page }
        guard let doc = document(id: id, url: url), let page = doc.page(at: index) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = pixelWidth / bounds.width
        let width = Int(pixelWidth.rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let rendered = RenderedPage(image: NSImage(cgImage: cg, size: NSSize(width: bounds.width, height: bounds.height)))
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
