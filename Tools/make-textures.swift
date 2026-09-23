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

/// Periodic Worley (cellular) noise: distance to nearest of `count` feature points, wrapping.
func worley(count: Int, seed: UInt64) -> (Double, Double) -> Double {
    var r = RNG(s: seed)
    let pts = (0..<count).map { _ in (r.next(), r.next()) }
    return { x, y in
        var best = 1.0
        for (px, py) in pts {
            var dx = abs(x - px); if dx > 0.5 { dx = 1 - dx }
            var dy = abs(y - py); if dy > 0.5 { dy = 1 - dy }
            best = min(best, dx * dx + dy * dy)
        }
        return sqrt(best)
    }
}

func fbm(octaves: [(period: Int, weight: Double)], seed: UInt64) -> (Double, Double) -> Double {
    let fns = octaves.enumerated().map { (i, o) in (valueNoise(period: o.period, seed: seed &+ UInt64(i) * 7919), o.weight) }
    let total = octaves.reduce(0) { $0 + $1.weight }
    return { x, y in fns.reduce(0) { $0 + $1.0(x, y) * $1.1 } / total }
}

func write(_ name: String, _ f: (Double, Double) -> Double) {
    var pixels = [UInt8](repeating: 0, count: N * N)
    for j in 0..<N { for i in 0..<N {
        let v = max(0, min(1, f(Double(i) / Double(N), Double(j) / Double(N))))
        pixels[j * N + i] = UInt8(v * 255)
    } }
    let data = CFDataCreate(nil, pixels, pixels.count)!
    let provider = CGDataProvider(data: data)!
    let img = CGImage(width: N, height: N, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: N,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let url = outDir.appendingPathComponent("\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

// Leather: pebbled cells (Worley) with fine grain, mid-grey centred.
let cells = worley(count: 900, seed: 11)
let grain = fbm(octaves: [(32, 0.3), (128, 0.7)], seed: 23)
write("leather") { x, y in
    let c = cells(x, y)              // 0 at cell centres, ~0.025 at borders
    let ridge = min(1, c / 0.025)    // bright at borders
    return 0.5 + (ridge - 0.5) * 0.18 + (grain(x, y) - 0.5) * 0.3
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
