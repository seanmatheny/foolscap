// xcrun swift Tools/make-icon.swift Icon/Foolscap.iconset
// A jester silhouette in gold on a leather cover.
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Foolscap.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Coordinates are on a 1024 canvas with the origin at the bottom-left.
/// Each piece is filled on its own so overlaps merge instead of cancelling.
func jesterPieces() -> [NSBezierPath] {
    var pieces: [NSBezierPath] = []
    func oval(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        pieces.append(NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)))
    }
    // Head
    oval(512, 430, 150)
    // Hat dome over the crown
    let dome = NSBezierPath()
    dome.move(to: NSPoint(x: 352, y: 470))
    dome.curve(to: NSPoint(x: 672, y: 470), controlPoint1: NSPoint(x: 380, y: 700), controlPoint2: NSPoint(x: 644, y: 700))
    dome.close()
    pieces.append(dome)
    // A tapered horn from two base points to a tip, with a bell.
    func horn(base1: NSPoint, base2: NSPoint, tip: NSPoint, c1: NSPoint, c2: NSPoint) {
        let h = NSBezierPath()
        h.move(to: base1)
        h.curve(to: tip, controlPoint1: c1, controlPoint2: NSPoint(x: (c1.x + tip.x) / 2, y: (c1.y + tip.y) / 2))
        h.curve(to: base2, controlPoint1: NSPoint(x: (c2.x + tip.x) / 2, y: (c2.y + tip.y) / 2), controlPoint2: c2)
        h.close()
        pieces.append(h)
        oval(tip.x, tip.y, 36)
    }
    // Outer horns rise then droop outward; the middle one stands up.
    horn(base1: NSPoint(x: 372, y: 520), base2: NSPoint(x: 470, y: 630), tip: NSPoint(x: 140, y: 560),
         c1: NSPoint(x: 300, y: 560), c2: NSPoint(x: 250, y: 800))
    horn(base1: NSPoint(x: 554, y: 630), base2: NSPoint(x: 652, y: 520), tip: NSPoint(x: 884, y: 560),
         c1: NSPoint(x: 774, y: 800), c2: NSPoint(x: 724, y: 560))
    horn(base1: NSPoint(x: 458, y: 620), base2: NSPoint(x: 566, y: 620), tip: NSPoint(x: 548, y: 930),
         c1: NSPoint(x: 420, y: 850), c2: NSPoint(x: 680, y: 800))
    // Ruff collar with pointed scallops and bells
    let collar = NSBezierPath()
    let top: CGFloat = 310, valley: CGFloat = 255, tipY: CGFloat = 195
    let xs: [CGFloat] = [290, 401, 512, 623, 734]
    collar.move(to: NSPoint(x: xs.first! - 34, y: top))
    collar.line(to: NSPoint(x: xs.last! + 34, y: top))
    for (i, x) in xs.reversed().enumerated() {
        collar.line(to: NSPoint(x: x, y: tipY))
        if i < xs.count - 1 { collar.line(to: NSPoint(x: x - 55, y: valley)) }
    }
    collar.close()
    pieces.append(collar)
    for x in xs { oval(x, tipY, 26) }
    return pieces
}

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    let inset = 80 * s
    let cover = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    let coverPath = CGPath(roundedRect: cover, cornerWidth: 90 * s, cornerHeight: 90 * s, transform: nil)
    ctx.addPath(coverPath); ctx.setFillColor(NSColor(calibratedRed: 0.12, green: 0.105, blue: 0.1, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(coverPath); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 0, alpha: 0.25).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.3, blue: 0.26, alpha: 0.9).cgColor)
    ctx.setLineWidth(6 * s); ctx.setLineDash(phase: 0, lengths: [22 * s, 16 * s])
    ctx.addPath(CGPath(roundedRect: cover.insetBy(dx: 44 * s, dy: 44 * s), cornerWidth: 60 * s, cornerHeight: 60 * s, transform: nil)); ctx.strokePath()
    ctx.restoreGState()
    // Jester in gold foil.
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    NSColor(calibratedRed: 0.82, green: 0.68, blue: 0.37, alpha: 1).setFill()
    for piece in jesterPieces() { piece.fill() }
    // Hairlines in the leather colour: hat brim and collar edge, so the face reads as a face.
    NSColor(calibratedRed: 0.12, green: 0.105, blue: 0.1, alpha: 1).setStroke()
    let brim = NSBezierPath()
    brim.move(to: NSPoint(x: 366, y: 500))
    brim.curve(to: NSPoint(x: 658, y: 500), controlPoint1: NSPoint(x: 440, y: 455), controlPoint2: NSPoint(x: 584, y: 455))
    brim.lineWidth = 14; brim.lineCapStyle = .round; brim.stroke()
    let neck = NSBezierPath()
    neck.move(to: NSPoint(x: 370, y: 312)); neck.line(to: NSPoint(x: 654, y: 312))
    neck.lineWidth = 12; neck.lineCapStyle = .round; neck.stroke()
    ctx.restoreGState()
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
