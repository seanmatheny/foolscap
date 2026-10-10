import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Rasterises Kindle Scribe notebook pages for the recognisers.
///
/// Scribe exports are 96 dpi page images (1860×2480) wrapped in a PDF, so rendering
/// at 96 dpi reproduces the original pixels exactly; other scales resample.
public enum PageRaster {
    public static let nativeDPI: CGFloat = 96

    /// Render one page. `stripTemplate` blanks the page template (rules, grids,
    /// dots, drawn in mid grey) and pale highlighter, both of which cut through
    /// handwriting and cost the recogniser whole lines. Ink is black or a saturated
    /// colour, so anything light and unsaturated is safe to blank out.
    public static func render(_ page: PDFPage, dpi: CGFloat = nativeDPI, stripTemplate: Bool = true) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        if stripTemplate, let data = context.data {
            let bytesPerRow = context.bytesPerRow
            let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            for row in 0..<height {
                var offset = row * bytesPerRow
                for _ in 0..<width {
                    let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                    let high = max(red, green, blue), low = min(red, green, blue)
                    let luminance = (2126 * red + 7152 * green + 722 * blue) / 10000
                    if luminance >= 90 && (high - low) * 2 <= high {
                        pixels[offset] = 255
                        pixels[offset + 1] = 255
                        pixels[offset + 2] = 255
                    }
                    offset += 4
                }
            }
        }
        return context.makeImage()
    }

    /// The dpi that fits the page's longer side within `maxSide` pixels, never
    /// above the native resolution (upscaling adds nothing for recognition).
    public static func dpi(fitting maxSide: Int, page: PDFPage) -> CGFloat {
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        guard longest > 0, maxSide > 0 else { return nativeDPI }
        return min(nativeDPI, CGFloat(maxSide) * 72.0 / longest)
    }

    /// PNG bytes for an image, for handing a page to a recogniser or hashing it.
    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Hash of the rendered pixels (not the PNG encoding), the identity of a page
    /// for per-page recognition caches.
    public static func pixelHash(_ image: CGImage) -> String {
        var hasher = SHA256()
        if let data = image.dataProvider?.data as Data? {
            hasher.update(data: data)
        }
        hasher.update(data: Data("\(image.width)x\(image.height)".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
