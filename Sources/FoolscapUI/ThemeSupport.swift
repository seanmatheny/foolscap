import SwiftUI
import ImageIO
import FoolscapCore

#if canImport(AppKit)
import AppKit

public extension RGBA {
    var nsColor: NSColor { platformColor }
}

public extension FontSpec {
    var nsFont: NSFont { platformFont }
}
#endif

/// Finds this package's resource bundle both under `swift run` and inside the
/// hand-assembled Foolscap.app (where bundles live in Contents/Resources).
public enum FoolscapUIResources {
    public static let bundle: Bundle = {
        let name = "foolscap_FoolscapUI.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        return Bundle.module
    }()

    /// A texture tile as decoded pixels plus the scale its file claims (its DPI
    /// over 72), so a Retina tile covers the same points as an `NSImage` of it would.
    public struct Tile {
        public let image: CGImage
        public let scale: CGFloat
    }

    nonisolated(unsafe) private static var tiles: [String: Tile] = [:]

    @MainActor
    public static func tile(_ name: String) -> Tile? {
        if let tile = tiles[name] { return tile }
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Textures"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        let tile = Tile(image: image, scale: dpi > 0 ? dpi / 72 : 1)
        tiles[name] = tile
        return tile
    }

    #if canImport(AppKit)
    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    /// The tile as an `NSImage`, for AppKit views that draw it themselves.
    @MainActor
    public static func texture(_ name: String) -> NSImage? {
        if let img = cache[name] { return img }
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Textures"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
    #endif
}

/// A tiled greyscale texture multiplied over whatever is underneath.
public struct TextureOverlay: View {
    let tile: String
    let opacity: Double
    let blend: TextureBlend
    public init(tile: String, opacity: Double, blend: TextureBlend = .softLight) {
        self.tile = tile; self.opacity = opacity; self.blend = blend
    }
    private var blendMode: BlendMode {
        switch blend {
        case .screen: return .screen
        case .softLight: return .softLight
        case .multiply: return .multiply
        }
    }
    public var body: some View {
        if !tile.isEmpty, opacity > 0, let tile = FoolscapUIResources.tile(tile) {
            // `blendMode` has to be the outermost modifier: opacity or clipping
            // applied after it would flatten the view into a normal composite.
            Image(decorative: tile.image, scale: tile.scale)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(blendMode)
                .allowsHitTesting(false)
        }
    }
}
