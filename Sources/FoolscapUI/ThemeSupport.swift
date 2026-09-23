import SwiftUI
import AppKit
import FoolscapCore

public extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

public extension FontSpec {
    var nsFont: NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        if let family, let f = NSFont(name: family, size: size) {
            if bold, let b = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) as NSFont? { return b }
            return f
        }
        switch design {
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .serif:
            let d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.serif)
            return d.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .rounded:
            let d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded)
            return d.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .sans: return NSFont.systemFont(ofSize: size, weight: weight)
        }
    }
    var font: Font { Font(nsFont) }
}

private struct NotebookThemeKey: EnvironmentKey {
    static let defaultValue: NotebookTheme = .classicBlack
}

public extension EnvironmentValues {
    var notebookTheme: NotebookTheme {
        get { self[NotebookThemeKey.self] }
        set { self[NotebookThemeKey.self] = newValue }
    }
}

/// Finds this package's resource bundle both under `swift run` and inside the
/// hand-assembled Foolscap.app (where bundles live in Contents/Resources).
public enum FoolscapUIResources {
    public static let bundle: Bundle = {
        let name = "foolscap_FoolscapUI.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        return Bundle.module
    }()

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]

    @MainActor
    public static func texture(_ name: String) -> NSImage? {
        if let img = cache[name] { return img }
        guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Textures"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
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
        if let img = FoolscapUIResources.texture(tile) {
            // `blendMode` has to be the outermost modifier: opacity or clipping
            // applied after it would flatten the view into a normal composite.
            Image(nsImage: img)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(blendMode)
                .allowsHitTesting(false)
        }
    }
}
