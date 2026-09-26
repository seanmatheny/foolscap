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

    public var title: String {
        switch self {
        case .blank: return "None"
        case .lined: return "Lined"
        case .dotted: return "Dot grid"
        case .grid: return "Graph"
        }
    }
}

/// The paper's surface, chosen in Settings independently of the theme.
public enum PaperTexture: String, Codable, CaseIterable, Sendable {
    case none, cotton, laid, linen, vellum, flecked, coldPress

    public var title: String {
        switch self {
        case .none: return "None"
        case .cotton: return "Cotton"
        case .laid: return "Laid"
        case .linen: return "Linen"
        case .vellum: return "Vellum"
        case .flecked: return "Flecked"
        case .coldPress: return "Cold press"
        }
    }

    /// The tile in FoolscapUI/Textures (`make textures`); empty for none.
    public var tile: String {
        switch self {
        case .none: return ""
        case .coldPress: return "paper-coldpress"
        default: return "paper-" + rawValue
        }
    }

    /// Overlay opacity on light paper (soft light).
    var strength: Double {
        switch self {
        case .none: return 0
        case .cotton, .vellum, .flecked: return 0.9
        case .laid, .linen: return 0.8
        case .coldPress: return 0.7
        }
    }
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

    /// The elastic band (optional, see Settings) is the leather's own colour, darkened.
    public var bandColor: RGBA { RGBA(baseColor.r * 0.5, baseColor.g * 0.5, baseColor.b * 0.5, 1) }
}

public struct PageStyle: Codable, Hashable, Sendable {
    public var paperColor: RGBA
    public var textureTile: String
    public var textureOpacity: Double
    /// How the paper grain combines with the paper colour (`screen` shows on black).
    public var textureBlend: TextureBlend
    /// Ruling is off in every built-in theme; the Settings ruling preference
    /// switches it on (see `NotebookTheme.ruled`) using the theme's colours below.
    public var ruling: Ruling
    public var ruleColor: RGBA
    public var marginRule: Bool
    public var marginRuleColor: RGBA

    public init(paperColor: RGBA, textureTile: String, textureOpacity: Double, textureBlend: TextureBlend = .softLight,
                ruling: Ruling = .blank, ruleColor: RGBA = .hex(0xB9C6D8, alpha: 0.7), marginRule: Bool = false,
                marginRuleColor: RGBA = .hex(0xE0A2A2, alpha: 0.8)) {
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

    /// The same theme on another paper (texture preference, independent of theme).
    /// Dark paper screens the tile in, which lifts the whole page, so it gets a
    /// small fraction of the strength.
    public func onPaper(_ texture: PaperTexture) -> NotebookTheme {
        var t = self
        t.page.textureTile = texture.tile
        t.page.textureOpacity = texture.strength * (t.page.textureBlend == .screen ? 0.1 : 1)
        return t
    }

    /// The same theme with the paper ruled (ruling preference, independent of theme).
    public func ruled(_ ruling: Ruling, marginRule: Bool) -> NotebookTheme {
        var t = self
        t.page.ruling = ruling
        t.page.marginRule = marginRule
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
        page: PageStyle(paperColor: .hex(0xFBF5E6), textureTile: "paper", textureOpacity: 0.55,
                        ruleColor: .hex(0x9A8E7A, alpha: 0.55), marginRuleColor: .hex(0xC9868A, alpha: 0.75)),
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
        page: PageStyle(paperColor: .hex(0xF4EFE3), textureTile: "paper", textureOpacity: 0.7,
                        ruleColor: .hex(0xA9C1B6, alpha: 0.6), marginRuleColor: .hex(0xD59A8C, alpha: 0.8)),
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
        page: PageStyle(paperColor: .hex(0x000000), textureTile: "paper", textureOpacity: 0.07, textureBlend: .screen,
                        ruleColor: .hex(0xFFFFFF, alpha: 0.10), marginRuleColor: .hex(0xC97C7C, alpha: 0.5)),
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

    /// Deep green pebbled leather, warm cream paper, brass tabs.
    public static let forest = NotebookTheme(
        id: "forest", name: "Forest",
        cover: CoverMaterial(baseColor: .hex(0x1F3A2C), textureTile: "leather", grainOpacity: 0.3,
                             stitchColor: .hex(0xC2A35C)),
        page: PageStyle(paperColor: .hex(0xF7EFDC), textureTile: "paper", textureOpacity: 0.6,
                        ruleColor: .hex(0x9AA48E, alpha: 0.6), marginRuleColor: .hex(0xC98A7A, alpha: 0.75)),
        type: Typography(body: FontSpec(family: "Iowan Old Style", size: 15, design: .serif),
                         heading: FontSpec(family: "Iowan Old Style", size: 22, design: .serif, bold: true),
                         mono: FontSpec(family: "Menlo", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0x24291F), dimInk: .hex(0x24291F, alpha: 0.42), accent: .hex(0x8A5A1E),
        tabColors: [.hex(0xC9A85A), .hex(0x7FA07E), .hex(0xB07D6A), .hex(0x6F8FA6)],
        highlighter: highlighterDefaults)

    /// Navy leather, cool white paper, muted tabs.
    public static let navy = NotebookTheme(
        id: "navy", name: "Navy",
        cover: CoverMaterial(baseColor: .hex(0x1C2A44), textureTile: "leather", grainOpacity: 0.3,
                             stitchColor: .hex(0x9FB0C8)),
        page: PageStyle(paperColor: .hex(0xF7F6F1), textureTile: "paper", textureOpacity: 0.5,
                        ruleColor: .hex(0xA9B6C9, alpha: 0.65), marginRuleColor: .hex(0xD09090, alpha: 0.75)),
        type: Typography(body: FontSpec(family: "Palatino", size: 15, design: .serif),
                         heading: FontSpec(family: "Palatino", size: 22, design: .serif, bold: true),
                         mono: FontSpec(family: "SF Mono", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0x1F2430), dimInk: .hex(0x1F2430, alpha: 0.42), accent: .hex(0x2F5C8F),
        tabColors: [.hex(0xB9A57A), .hex(0x8AA58C), .hex(0xA48CA0), .hex(0x6E8DAF)],
        highlighter: highlighterDefaults)

    /// Tan full-grain leather with its creases showing, ivory paper.
    public static let saddle = NotebookTheme(
        id: "saddle", name: "Saddle",
        cover: CoverMaterial(baseColor: .hex(0x8E5A2B), textureTile: "leather-grain", grainOpacity: 0.55, blend: .softLight,
                             stitchColor: .hex(0xE8D3A6)),
        page: PageStyle(paperColor: .hex(0xFAF3E1), textureTile: "paper", textureOpacity: 0.6,
                        ruleColor: .hex(0xB5A98F, alpha: 0.55), marginRuleColor: .hex(0xCF8F7C, alpha: 0.75)),
        type: Typography(body: FontSpec(family: "Baskerville", size: 15.5, design: .serif),
                         heading: FontSpec(family: "Baskerville", size: 23, design: .serif, bold: true),
                         mono: FontSpec(family: "Menlo", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0x2B2119), dimInk: .hex(0x2B2119, alpha: 0.42), accent: .hex(0xA0522D),
        tabColors: [.hex(0xD2A24C), .hex(0x8AA37E), .hex(0xC07A5B), .hex(0x6F93B0)],
        highlighter: highlighterDefaults)

    /// Charcoal full-grain leather, pale grey paper: dark without being black.
    public static let slate = NotebookTheme(
        id: "slate", name: "Slate",
        cover: CoverMaterial(baseColor: .hex(0x33373C), textureTile: "leather-grain", grainOpacity: 0.4, blend: .softLight,
                             stitchColor: .hex(0x8C9298)),
        page: PageStyle(paperColor: .hex(0xECEBE7), textureTile: "paper", textureOpacity: 0.5,
                        ruleColor: .hex(0xA6ABB3, alpha: 0.6), marginRuleColor: .hex(0xC98C8C, alpha: 0.7)),
        type: Typography(body: FontSpec(family: "Charter", size: 15, design: .serif),
                         heading: FontSpec(family: "Charter", size: 22, design: .serif, bold: true),
                         mono: FontSpec(family: "SF Mono", size: 13, design: .mono),
                         lineHeightMultiple: 1.35),
        ink: .hex(0x22252A), dimInk: .hex(0x22252A, alpha: 0.42), accent: .hex(0x9C4B3A),
        tabColors: [.hex(0xBFA46F), .hex(0x8AA391), .hex(0xA995A6), .hex(0x7C97B0)],
        highlighter: highlighterDefaults)

    public static let builtIn: [NotebookTheme] = [.classicBlack, .oxblood, .kraft, .midnight, .forest, .navy, .saddle, .slate]

    public static func builtIn(id: String) -> NotebookTheme? { builtIn.first { $0.id == id } }
}
