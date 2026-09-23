// xcrun swift Tools/make-icon.swift Icon/Foolscap.iconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Foolscap.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    let inset = 80 * s
    let cover = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    // Shadow + cover
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    let coverPath = CGPath(roundedRect: cover, cornerWidth: 90 * s, cornerHeight: 90 * s, transform: nil)
    ctx.addPath(coverPath); ctx.setFillColor(NSColor(calibratedRed: 0.12, green: 0.105, blue: 0.1, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    // Subtle leather gradient
    ctx.saveGState(); ctx.addPath(coverPath); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 0, alpha: 0.25).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    // Stitching
    ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.3, blue: 0.26, alpha: 0.9).cgColor)
    ctx.setLineWidth(6 * s); ctx.setLineDash(phase: 0, lengths: [22 * s, 16 * s])
    ctx.addPath(CGPath(roundedRect: cover.insetBy(dx: 44 * s, dy: 44 * s), cornerWidth: 60 * s, cornerHeight: 60 * s, transform: nil)); ctx.strokePath()
    ctx.restoreGState()
    // Elastic band
    ctx.setFillColor(NSColor(calibratedRed: 0.06, green: 0.05, blue: 0.05, alpha: 1).cgColor)
    ctx.fill(CGRect(x: cover.maxX - 170 * s, y: cover.minY - 8 * s, width: 44 * s, height: cover.height + 16 * s))
    // Jester's cap: three lobes and bells, gold foil
    let gold = NSColor(calibratedRed: 0.80, green: 0.66, blue: 0.36, alpha: 1)
    ctx.setFillColor(gold.cgColor); ctx.setStrokeColor(gold.cgColor); ctx.setLineWidth(18 * s)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let cx = size * 0.44, base = size * 0.36, w = size * 0.42
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx - w / 2, y: base))
    p.addQuadCurve(to: CGPoint(x: cx - w * 0.62, y: base + size * 0.30), control: CGPoint(x: cx - w * 0.72, y: base + size * 0.1))
    p.addQuadCurve(to: CGPoint(x: cx - w * 0.16, y: base + size * 0.16), control: CGPoint(x: cx - w * 0.36, y: base + size * 0.22))
    p.addQuadCurve(to: CGPoint(x: cx, y: base + size * 0.36), control: CGPoint(x: cx - w * 0.04, y: base + size * 0.26))
    p.addQuadCurve(to: CGPoint(x: cx + w * 0.16, y: base + size * 0.16), control: CGPoint(x: cx + w * 0.04, y: base + size * 0.26))
    p.addQuadCurve(to: CGPoint(x: cx + w * 0.62, y: base + size * 0.30), control: CGPoint(x: cx + w * 0.36, y: base + size * 0.22))
    p.addQuadCurve(to: CGPoint(x: cx + w / 2, y: base), control: CGPoint(x: cx + w * 0.72, y: base + size * 0.1))
    p.closeSubpath()
    ctx.addPath(p); ctx.drawPath(using: .fillStroke)
    // Brim
    ctx.fill(CGRect(x: cx - w / 2 - 10 * s, y: base - 26 * s, width: w + 20 * s, height: 30 * s))
    // Bells
    for pt in [CGPoint(x: cx - w * 0.62, y: base + size * 0.30), CGPoint(x: cx, y: base + size * 0.36), CGPoint(x: cx + w * 0.62, y: base + size * 0.30)] {
        ctx.fillEllipse(in: CGRect(x: pt.x - 26 * s, y: pt.y - 26 * s, width: 52 * s, height: 52 * s))
    }
    img.unlockFocus()
    return img
}

for (px, names) in [(16, ["16x16"]), (32, ["16x16@2x", "32x32"]), (64, ["32x32@2x"]), (128, ["128x128"]),
                    (256, ["128x128@2x", "256x256"]), (512, ["256x256@2x", "512x512"]), (1024, ["512x512@2x"])] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    for n in names { try! data.write(to: outDir.appendingPathComponent("icon_\(n).png")) }
}
print("iconset written to \(outDir.path)")
