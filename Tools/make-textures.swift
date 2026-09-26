// Generates seamless 256px greyscale texture tiles centred on mid-grey so they
// can be multiplied over a base colour at low opacity.
//   xcrun swift Tools/make-textures.swift Sources/FoolscapUI/Textures
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Textures")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let N = 256

struct RNG { var s: UInt64; mutating func next() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 1_000_000) / 1_000_000 } }

/// Periodic value noise on a lattice of `period` cells, smoothstep interpolated.
func valueNoise(period: Int, seed: UInt64) -> (Double, Double) -> Double {
    var r = RNG(s: seed)
    var lattice = [Double](repeating: 0, count: period * period)
    for i in lattice.indices { lattice[i] = r.next() }
    return { x, y in
        let fx = x * Double(period), fy = y * Double(period)
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func sm(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        func at(_ i: Int, _ j: Int) -> Double { lattice[((j % period + period) % period) * period + ((i % period + period) % period)] }
        let a = at(x0, y0), b = at(x0 + 1, y0), c = at(x0, y0 + 1), d = at(x0 + 1, y0 + 1)
        let u = sm(tx), v = sm(ty)
        return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v
    }
}

/// Periodic Worley (cellular) noise: distance to the nearest of `count`
/// feature points, wrapping. Points are bucketed on a grid so each lookup
/// checks nine buckets, not every point (a tile has a million pixels).
func worley(count: Int, seed: UInt64) -> (Double, Double) -> Double {
    var r = RNG(s: seed)
    let pts = (0..<count).map { _ in (r.next(), r.next()) }
    let g = max(1, Int(sqrt(Double(count) / 2)))
    var buckets = [[(Double, Double)]](repeating: [], count: g * g)
    for p in pts { buckets[min(g - 1, Int(p.1 * Double(g))) * g + min(g - 1, Int(p.0 * Double(g)))].append(p) }
    return { x, y in
        var best = 1.0
        let cx = min(g - 1, Int(x * Double(g))), cy = min(g - 1, Int(y * Double(g)))
        for j in -1...1 { for i in -1...1 {
            for (px, py) in buckets[((cy + j + g) % g) * g + ((cx + i + g) % g)] {
                var dx = abs(x - px); if dx > 0.5 { dx = 1 - dx }
                var dy = abs(y - py); if dy > 0.5 { dy = 1 - dy }
                best = min(best, dx * dx + dy * dy)
            }
        } }
        // A sparse neighbourhood (few points per bucket) can miss the true nearest
        // point two buckets away; the ring check covers what the leather needs.
        return sqrt(best)
    }
}

func fbm(octaves: [(period: Int, weight: Double)], seed: UInt64) -> (Double, Double) -> Double {
    let fns = octaves.enumerated().map { (i, o) in (valueNoise(period: o.period, seed: seed &+ UInt64(i) * 7919), o.weight) }
    let total = octaves.reduce(0) { $0 + $1.weight }
    return { x, y in fns.reduce(0) { $0 + $1.0(x, y) * $1.1 } / total }
}

/// `retina` tiles are twice the pixels at 144 dpi, so they still tile every
/// 256 pt but stay sharp on a Retina screen (fine paper detail needs it).
func write(_ name: String, retina: Bool = false, points: Int = N, _ f: (Double, Double) -> Double) {
    let n = retina ? points * 2 : points
    var pixels = [UInt8](repeating: 0, count: n * n)
    for j in 0..<n { for i in 0..<n {
        let v = max(0, min(1, f(Double(i) / Double(n), Double(j) / Double(n))))
        pixels[j * n + i] = UInt8(v * 255)
    } }
    let data = CFDataCreate(nil, pixels, pixels.count)!
    let provider = CGDataProvider(data: data)!
    let img = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = outDir.appendingPathComponent("\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = retina ? [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] : [:]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

/// Value noise with separate periods across and down, for fibres and threads
/// that run one way.
func stretchedNoise(periodX: Int, periodY: Int, seed: UInt64) -> (Double, Double) -> Double {
    var r = RNG(s: seed)
    var lattice = [Double](repeating: 0, count: periodX * periodY)
    for i in lattice.indices { lattice[i] = r.next() }
    return { x, y in
        let fx = x * Double(periodX), fy = y * Double(periodY)
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Double(x0), ty = fy - Double(y0)
        func sm(_ t: Double) -> Double { t * t * (3 - 2 * t) }
        func at(_ i: Int, _ j: Int) -> Double {
            lattice[((j % periodY + periodY) % periodY) * periodX + ((i % periodX + periodX) % periodX)]
        }
        let u = sm(tx), v = sm(ty)
        return (at(x0, y0) * (1 - u) + at(x0 + 1, y0) * u) * (1 - v) + (at(x0, y0 + 1) * (1 - u) + at(x0 + 1, y0 + 1) * u) * v
    }
}

// Leather: pebbled grain at two scales (larger pebbles with finer pores inside
// them), each pebble domed rather than flat, over slow tone variation and a
// few soft creases. A 512 pt Retina tile, so the pattern repeats rarely.
let pebbles = worley(count: 700, seed: 11)
let pores = worley(count: 9000, seed: 12)
let tone = fbm(octaves: [(3, 0.5), (6, 0.3), (24, 0.2)], seed: 23)
let creaseNoise = fbm(octaves: [(2, 0.6), (5, 0.4)], seed: 29)
write("leather", retina: true, points: 512) { x, y in
    let p = pebbles(x, y)            // 0 at pebble centres, ~0.03 at the seams
    let dome = 1 - min(1, p / 0.03)  // high in the middle of a pebble
    let seam = exp(-pow(p / 0.006, 2))   // a sharp dark groove between pebbles
    let pore = 1 - min(1, pores(x, y) / 0.008)
    // Light from the top-left: each pebble's upper-left face is lit.
    let lit = (pebbles(x - 0.002, y - 0.002) - p) / 0.004
    let crease = exp(-pow((creaseNoise(x, y) - 0.5) / 0.012, 2))
    return 0.5 + (dome - 0.5) * 0.12 + lit * 0.08 - seam * 0.22 - pore * 0.06 + (tone(x, y) - 0.5) * 0.22 - crease * 0.12
}

// Full-grain leather: a smoother hide with fine pores and a faint pebble,
// broad soft folds in the tone, and a few thin creases that wander one way.
let hidePores = worley(count: 6000, seed: 61)
let hidePebble = worley(count: 400, seed: 62)
let hideTone = fbm(octaves: [(2, 0.5), (4, 0.3), (16, 0.2)], seed: 67)
let hideFold = stretchedNoise(periodX: 2, periodY: 6, seed: 69)
let creaseA = stretchedNoise(periodX: 3, periodY: 20, seed: 71)
let creaseB = stretchedNoise(periodX: 5, periodY: 28, seed: 77)
let creaseWobble = fbm(octaves: [(32, 0.6), (96, 0.4)], seed: 79)
write("leather-grain", retina: true, points: 512) { x, y in
    let pore = 1 - min(1, hidePores(x, y) / 0.006)
    let pebble = 1 - min(1, hidePebble(x, y) / 0.04)
    let w = (creaseWobble(x, y) - 0.5) * 0.02
    // Thin lines only where each field passes its midpoint steeply, so they stay sparse.
    let ca = exp(-pow((creaseA(x, y + w) - 0.5) / 0.006, 2))
    let cb = exp(-pow((creaseB(x, y - w) - 0.55) / 0.005, 2))
    let fold = (hideFold(x, y) - 0.5) * 0.2
    return 0.5 + (hideTone(x, y) - 0.5) * 0.28 + fold + (pebble - 0.5) * 0.05 - pore * 0.05 - ca * 0.10 - cb * 0.08
}

// Paper: soft fibrous fractal noise, low contrast.
let fibre = fbm(octaves: [(8, 0.35), (16, 0.25), (32, 0.2), (128, 0.2)], seed: 5)
write("paper") { x, y in 0.5 + (fibre(x, y) - 0.5) * 0.35 }

// Kraft: horizontally stretched fibres with speckles.
let stretch = fbm(octaves: [(4, 0.3), (32, 0.3), (128, 0.4)], seed: 9)
let speck = valueNoise(period: 128, seed: 31)
write("kraft") { x, y in
    let base = stretch(x * 0.25 + y * 0.02, y)  // period-safe? x*0.25 keeps wrap since 0.25*period integer
    let s = speck(x, y) > 0.93 ? -0.25 : 0
    return 0.5 + (base - 0.5) * 0.45 + s
}

// MARK: Paper textures (Settings › Paper), Retina tiles centred on mid-grey.
// Soft light barely moves a pale paper, so these carry more contrast than the
// cover tiles.

// Cotton: soft rag-paper clouds with fine fibre.
let cottonClouds = fbm(octaves: [(4, 0.3), (8, 0.3), (32, 0.2), (128, 0.2)], seed: 41)
let cottonFibre = stretchedNoise(periodX: 64, periodY: 256, seed: 43)
write("paper-cotton", retina: true) { x, y in
    0.5 + (cottonClouds(x, y) - 0.5) * 1.1 + (cottonFibre(x, y) - 0.5) * 0.3
}

// Laid: the fine horizontal wire lines of a laid mould, crossed by two chain
// lines per tile, over a faint mottle.
let laidMottle = fbm(octaves: [(4, 0.5), (16, 0.3), (64, 0.2)], seed: 47)
let laidWobble = stretchedNoise(periodX: 8, periodY: 1, seed: 53)
write("paper-laid", retina: true) { x, y in
    let wire = sin(2 * .pi * (64 * y + 0.15 * laidWobble(x, y)))
    var chain = 0.0
    for c in [0.25, 0.75] {
        let d = abs(x - c)
        chain += exp(-(d * d) / (2 * 0.004 * 0.004))
    }
    return 0.5 + wire * 0.16 - chain * 0.3 + (laidMottle(x, y) - 0.5) * 0.5
}

// Linen: fine uneven threads both ways (each a couple of pixels, thickening
// and thinning along its length) and the over-under of the weave.
let warp = stretchedNoise(periodX: 24, periodY: 256, seed: 59)
let weft = stretchedNoise(periodX: 256, periodY: 24, seed: 61)
let linenSlub = fbm(octaves: [(16, 0.6), (64, 0.4)], seed: 67)
write("paper-linen", retina: true) { x, y in
    let weave = sin(2 * .pi * 128 * x) * sin(2 * .pi * 128 * y)
    return 0.5 + (warp(x, y) - 0.5) * 0.55 + (weft(x, y) - 0.5) * 0.55 + weave * 0.1 + (linenSlub(x, y) - 0.5) * 0.2
}

// Vellum: broad, parchment-like clouding with little fine detail.
let vellumClouds = fbm(octaves: [(2, 0.4), (4, 0.3), (8, 0.2), (64, 0.1)], seed: 71)
write("paper-vellum", retina: true) { x, y in 0.5 + (vellumClouds(x, y) - 0.5) * 1.4 }

// Flecked: recycled stock, soft base with scattered dark specks and pale flecks.
let fleckBase = fbm(octaves: [(8, 0.5), (32, 0.3), (128, 0.2)], seed: 73)
let paleFleck = stretchedNoise(periodX: 96, periodY: 192, seed: 83)
var speckRNG = RNG(s: 79)
let specks: [(x: Double, y: Double, r: Double, depth: Double)] = (0..<220).map { _ in
    (speckRNG.next(), speckRNG.next(), (0.8 + speckRNG.next() * 1.6) / 512, 0.35 + speckRNG.next() * 0.35)
}
write("paper-flecked", retina: true) { x, y in
    var v = 0.5 + (fleckBase(x, y) - 0.5) * 0.7
    if paleFleck(x, y) > 0.9 { v += 0.3 }
    for s in specks {
        var dx = abs(x - s.x); if dx > 0.5 { dx = 1 - dx }
        var dy = abs(y - s.y); if dy > 0.5 { dy = 1 - dy }
        let d = (dx * dx + dy * dy).squareRoot()
        if d < s.r * 1.5 { v -= s.depth * max(0, min(1, (s.r * 1.5 - d) / (s.r * 0.5))) }
    }
    return v
}

// Cold press: the pebbled tooth of watercolour paper, drawn as a relief lit
// from the top left so the bumps read as raised.
let toothHeight = fbm(octaves: [(32, 0.5), (64, 0.35), (128, 0.15)], seed: 89)
write("paper-coldpress", retina: true) { x, y in
    let e = 1.0 / 512
    return 0.5 + (toothHeight(x - e, y - e) - toothHeight(x + e, y + e)) * 6
}
