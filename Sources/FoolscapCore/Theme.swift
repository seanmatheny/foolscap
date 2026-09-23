import Foundation

/// A colour in sRGB, kept framework-neutral so Core has no AppKit/SwiftUI dependency.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// `0xRRGGBB` with an optional alpha.
    public static func hex(_ value: UInt32, alpha: Double = 1) -> RGBA {
        RGBA(Double((value >> 16) & 0xFF) / 255,
             Double((value >> 8) & 0xFF) / 255,
             Double(value & 0xFF) / 255,
             alpha)
    }

    public func opacity(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
}

public enum Ruling: String, Codable, CaseIterable, Sendable {
    case lined, dotted, grid, blank
}

/// How a texture tile combines with the colour beneath it.
public enum TextureBlend: String, Codable, Sendable {
    /// Adds the tile's light parts: highlights on dark leather.
    case screen
    /// Neutral at mid-grey; gentle fibres on paper.
    case softLight
    /// Darkens: grain on light card.
    case multiply
}

public enum FontDesign: String, Codable, Sendable { case serif, sans, mono, rounded }

public struct FontSpec: Codable, Hashable, Sendable {
    /// A PostScript/family name. `nil` means the system font of `design`.
    public var family: String?
    public var size: Double
    public var design: FontDesign
    public var bold: Bool

    public init(family: String? = nil, size: Double, design: FontDesign = .serif, bold: Bool = false) {
        self.family = family; self.size = size; self.design = design; self.bold = bold
    }
}

public struct CoverMaterial: Codable, Hashable, Sendable {
    public var baseColor: RGBA
    public var textureTile: String
    public var grainOpacity: Double
    public var blend: TextureBlend
    public var stitchColor: RGBA

    public init(baseColor: RGBA, textureTile: String, grainOpacity: Double, blend: TextureBlend = .screen,
                stitchColor: RGBA) {
        self.baseColor = baseColor; self.textureTile = textureTile; self.grainOpacity = grainOpacity
        self.blend = blend; self.stitchColor = stitchColor
    }
}

public struct PageStyle: Codable, Hashable, Sendable {
    public var paperColor: RGBA
    public var textureTile: String
    public var textureOpacity: Double
    /// How the paper grain combines with the paper colour (`screen` shows on black).
    public var textureBlend: TextureBlend
    /// Ruling is off in every built-in theme; kept so a theme could opt in.
    public var ruling: Ruling
    public var ruleColor: RGBA
    public var marginRule: Bool
    public var marginRuleColor: RGBA

    public init(paperColor: RGBA, textureTile: String, textureOpacity: Double, textureBlend: TextureBlend = .softLight,
                ruling: Ruling = .blank, ruleColor: RGBA = .hex(0x000000, alpha: 0), marginRule: Bool = false,
                marginRuleColor: RGBA = .hex(0x000000, alpha: 0)) {
        self.paperColor = paperColor; self.textureTile = textureTile; self.textureOpacity = textureOpacity
        self.textureBlend = textureBlend; self.ruling = ruling; self.ruleColor = ruleColor
        self.marginRule = marginRule; self.marginRuleColor = marginRuleColor
    }
}

public struct Typography: Codable, Hashable, Sendable {
    public var body: FontSpec
    public var heading: FontSpec
    public var mono: FontSpec
    public var lineHeightMultiple: Double

    public init(body: FontSpec, heading: FontSpec, mono: FontSpec, lineHeightMultiple: Double) {
        self.body = body; self.heading = heading; self.mono = mono; self.lineHeightMultiple = lineHeightMultiple
    }
}

/// Everything that coordinates the look of one notebook: cover, paper, type and ink.
public struct NotebookTheme: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var cover: CoverMaterial
    public var page: PageStyle
    public var type: Typography
    public var ink: RGBA
    public var dimInk: RGBA
    public var accent: RGBA
    public var tabColors: [RGBA]
    public var highlighter: [TaskStatus: RGBA]
    public var isDark: Bool

    public init(id: String, name: String, cover: CoverMaterial, page: PageStyle, type: Typography,
                ink: RGBA, dimInk: RGBA, accent: RGBA, tabColors: [RGBA],
                highlighter: [TaskStatus: RGBA], isDark: Bool = false) {
        self.id = id; self.name = name; self.cover = cover; self.page = page; self.type = type
        self.ink = ink; self.dimInk = dimInk; self.accent = accent; self.tabColors = tabColors
        self.highlighter = highlighter; self.isDark = isDark
    }

    public func tabColor(at index: Int) -> RGBA {
        tabColors.isEmpty ? accent : tabColors[index % tabColors.count]
    }

    /// Vertical pitch of the ruling and of every body line, in points.
    public var linePitch: Double { (type.body.size * type.lineHeightMultiple * 1.35).rounded() }

    /// The same theme with all type sizes multiplied (text size preference).
    public func scaled(by factor: Double) -> NotebookTheme {
        guard factor != 1 else { return self }
        var t = self
        t.type.body.size *= factor
        t.type.heading.size *= factor
        t.type.mono.size *= factor
        return t
    }
}

// MARK: - Built-in themes

extension NotebookTheme {
    static let highlighterDefaults: [TaskStatus: RGBA] = [
        .notStarted: .hex(0x000000, alpha: 0),
        .inProgress: .hex(0xF7D842, alpha: 0.55),
        .completed:  .hex(0x8ED081, alpha: 0.55),
    ]

    /// Black Moleskine, ivory paper.
    public static let classicBlack = NotebookTheme(
        id: "classic-black", name: "Classic Black",
        cover: CoverMaterial(baseColor: .hex(0x1E1B19), textureTile: "leather", grainOpacity: 0.22,
                             stitchColor: .hex(0x3A3532)),
        page: PageStyle(paperColor: .hex(0xF6F0DF), textureTile: "paper", textureOpacity: 0.6),
        type: Typography(body: FontSpec(family: "Charter", size: 15, design: .serif),
                         heading: FontSpec(family: "Charter", size: 22, design: .serif, bold: true),
                         mono: FontSpec(family: "Menlo", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0x2A2622), dimInk: .hex(0x2A2622, alpha: 0.4), accent: .hex(0x9A3B2E),
        tabColors: [.hex(0xC9A66B), .hex(0x8FA88B), .hex(0xA98BA1), .hex(0x7E9DB8)],
        highlighter: highlighterDefaults)

    /// Oxblood leather, cream paper.
    public static let oxblood = NotebookTheme(
        id: "oxblood", name: "Oxblood",
        cover: CoverMaterial(baseColor: .hex(0x5A1F22), textureTile: "leather", grainOpacity: 0.2,
                             stitchColor: .hex(0xC9A66B)),
        page: PageStyle(paperColor: .hex(0xFBF5E6), textureTile: "paper", textureOpacity: 0.55),
        type: Typography(body: FontSpec(family: "Georgia", size: 15, design: .serif),
                         heading: FontSpec(family: "Georgia", size: 22, design: .serif, bold: true),
                         mono: FontSpec(family: "SF Mono", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0x2E2420), dimInk: .hex(0x2E2420, alpha: 0.4), accent: .hex(0x7A2E31),
        tabColors: [.hex(0xB08A4A), .hex(0x6F8F6B), .hex(0x8B6F86), .hex(0x5F7F9E)],
        highlighter: highlighterDefaults)

    /// Kraft card cover, soft white paper.
    public static let kraft = NotebookTheme(
        id: "kraft", name: "Kraft",
        cover: CoverMaterial(baseColor: .hex(0xB98F5E), textureTile: "kraft", grainOpacity: 0.7, blend: .multiply,
                             stitchColor: .hex(0x6B4F2A)),
        page: PageStyle(paperColor: .hex(0xF4EFE3), textureTile: "paper", textureOpacity: 0.7),
        type: Typography(body: FontSpec(family: "Avenir Next", size: 14.5, design: .sans),
                         heading: FontSpec(family: "Avenir Next", size: 21, design: .sans, bold: true),
                         mono: FontSpec(family: "Menlo", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0x26221E), dimInk: .hex(0x26221E, alpha: 0.4), accent: .hex(0x9C4A1A),
        tabColors: [.hex(0xD9A441), .hex(0x6E9E7A), .hex(0xC96B4E), .hex(0x5B87A8)],
        highlighter: highlighterDefaults)

    /// Dark mode: pale leather around true-black (OLED) paper with white ink.
    public static let midnight = NotebookTheme(
        id: "midnight", name: "Midnight",
        cover: CoverMaterial(baseColor: .hex(0x8A8178), textureTile: "leather", grainOpacity: 0.16,
                             stitchColor: .hex(0x4A443F)),
        page: PageStyle(paperColor: .hex(0x000000), textureTile: "paper", textureOpacity: 0.07, textureBlend: .screen),
        type: Typography(body: FontSpec(family: "Charter", size: 15, design: .serif),
                         heading: FontSpec(family: "Charter", size: 22, design: .serif, bold: true),
                         mono: FontSpec(family: "Menlo", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0xF4F1EA), dimInk: .hex(0xF4F1EA, alpha: 0.45), accent: .hex(0xE0B95A),
        tabColors: [.hex(0xC9B58F), .hex(0x9FB89E), .hex(0xB59FB0), .hex(0x94AEC4)],
        highlighter: [
            .notStarted: .hex(0x000000, alpha: 0),
            .inProgress: .hex(0xE0B95A, alpha: 0.28),
            .completed:  .hex(0x6FBF7A, alpha: 0.28),
        ],
        isDark: true)

    public static let builtIn: [NotebookTheme] = [.classicBlack, .oxblood, .kraft, .midnight]

    public static func builtIn(id: String) -> NotebookTheme? { builtIn.first { $0.id == id } }
}
