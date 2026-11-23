import Foundation

/// A hash that is the same on every launch and every device (Swift's `hashValue` is
/// seeded per process): FNV-1a over UTF-8.
public enum StableHash {
    public static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return hash
    }

    /// SplitMix64's finaliser: spreads FNV's bits so the low ones are as good as the high.
    public static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// A Reference note's bookcloth: named, so a cover reads the same on every theme and
/// device. Each has a face for a light page and a slightly lifted one for a dark page.
public enum CoverCloth: String, Codable, CaseIterable, Sendable {
    case oxblood, rust, ochre, olive, moss, teal, slate, navy, indigo, plum, rose, charcoal

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public func rgba(onDark: Bool) -> RGBA {
        let base = RGBA.hex(light)
        return onDark ? base.mixed(with: .hex(0xFFFFFF), fraction: 0.12) : base
    }

    private var light: UInt32 {
        switch self {
        case .oxblood: return 0x6E2A2C
        case .rust: return 0x9A4B2C
        case .ochre: return 0xB58A3A
        case .olive: return 0x6E6E3A
        case .moss: return 0x3F5E3E
        case .teal: return 0x2F6466
        case .slate: return 0x4C5966
        case .navy: return 0x26385A
        case .indigo: return 0x3E3A72
        case .plum: return 0x5E3352
        case .rose: return 0xA35D66
        case .charcoal: return 0x34332F
        }
    }
}

/// The figure pressed into a cover's cloth.
public enum CoverPattern: String, Codable, CaseIterable, Sendable {
    case plain, pinstripe, dots, chevron, grid, diagonal, waves, herringbone

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// What the reader chose for a cover; every field nil means "as the name has it".
public struct CoverChoice: Hashable, Sendable {
    public var symbol: String?
    public var cloth: CoverCloth?
    public var pattern: CoverPattern?

    public init(symbol: String? = nil, cloth: CoverCloth? = nil, pattern: CoverPattern? = nil) {
        self.symbol = symbol; self.cloth = cloth; self.pattern = pattern
    }

    public var isEmpty: Bool { symbol == nil && cloth == nil && pattern == nil }
}

/// A cover as drawn: the choice laid over the look derived from the title.
public struct ResolvedCover: Hashable, Sendable {
    public var cloth: CoverCloth
    public var pattern: CoverPattern
    /// An SF Symbol name, or nil for the monogram.
    public var symbol: String?
    public var monogram: String
}

public enum ReferenceCover {
    /// The title as hashed: precomposed, lower case, trimmed, so "Recipes" and " recipes" agree.
    public static func key(_ title: String) -> String {
        title.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The look a title has before anyone chooses: a cloth and a pattern from its hash.
    /// Depends on the title alone, never on which other notes exist.
    public static func derived(title: String) -> (cloth: CoverCloth, pattern: CoverPattern) {
        let h = StableHash.mix(StableHash.fnv1a(key(title)))
        let cloths = CoverCloth.allCases, patterns = CoverPattern.allCases
        return (cloths[Int(h % UInt64(cloths.count))], patterns[Int((h >> 16) % UInt64(patterns.count))])
    }

    public static func resolve(title: String, choice: CoverChoice = CoverChoice()) -> ResolvedCover {
        let d = derived(title: title)
        return ResolvedCover(cloth: choice.cloth ?? d.cloth, pattern: choice.pattern ?? d.pattern,
                             symbol: choice.symbol, monogram: monogram(title))
    }

    /// The first letters of the first two words ("Work Projects" → "WP"), or the first
    /// letter of a single word ("Recipes" → "R").
    public static func monogram(_ title: String) -> String {
        let words = title.split { !($0.isLetter || $0.isNumber) }
        let letters = words.prefix(2).compactMap { $0.first }
        guard !letters.isEmpty else { return "·" }
        return String(letters).uppercased()
    }
}
