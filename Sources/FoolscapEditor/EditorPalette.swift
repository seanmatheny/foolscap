import FoolscapCore
import FoolscapUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Everything the text view needs from a theme, resolved to the toolkit's types once.
public struct EditorPalette {
    /// The theme itself, for SwiftUI chrome drawn over the text (the tag list).
    public var theme: NotebookTheme
    public var ink: PlatformColor
    public var dimInk: PlatformColor
    public var accent: PlatformColor
    public var paper: PlatformColor
    public var ruleColor: PlatformColor
    public var marginRuleColor: PlatformColor
    public var ruling: Ruling
    public var showMarginRule: Bool
    public var body: PlatformFont
    public var mono: PlatformFont
    public var headings: [PlatformFont]   // index 0 = h1
    public var bold: PlatformFont
    public var italic: PlatformFont
    public var boldItalic: PlatformFont
    public var codeBackground: PlatformColor
    /// Opaque backdrop for fenced code blocks (hides the ruling).
    public var codeBlockBackground: PlatformColor
    public var tagBackground: PlatformColor
    public var selection: PlatformColor
    public var highlighter: [TaskStatus: PlatformColor]
    /// Colours of the `!` priority markers on task lines.
    public var priorityColors: [TaskPriority: PlatformColor]
    /// Line pitch: every body line is exactly this tall so text sits on the ruling.
    public var pitch: CGFloat
    public var isDark: Bool

    public init(theme: NotebookTheme) {
        self.theme = theme
        ink = theme.ink.platformColor
        dimInk = theme.dimInk.platformColor
        accent = theme.accent.platformColor
        paper = theme.page.paperColor.platformColor
        ruleColor = theme.page.ruleColor.platformColor
        marginRuleColor = theme.page.marginRuleColor.platformColor
        ruling = theme.page.ruling
        showMarginRule = theme.page.marginRule
        body = theme.type.body.platformFont
        mono = theme.type.mono.platformFont
        let h = theme.type.heading
        let bodySize = theme.type.body.size
        headings = [1.6, 1.33, 1.17, 1.07, 1.03, 1.0].map { ratio in
            FontSpec(family: h.family, size: (bodySize * ratio).rounded(), design: h.design, bold: true).platformFont
        }
        bold = Self.face(body, bold: true, italic: false)
        italic = Self.face(body, bold: false, italic: true)
        boldItalic = Self.face(body, bold: true, italic: true)
        codeBackground = theme.isDark ? PlatformColor.white.withAlphaComponent(0.06) : PlatformColor.black.withAlphaComponent(0.05)
        codeBlockBackground = theme.page.paperColor
            .mixed(with: theme.isDark ? .hex(0xFFFFFF) : .hex(0x000000), fraction: theme.isDark ? 0.08 : 0.055).platformColor
        tagBackground = theme.accent.platformColor.withAlphaComponent(0.14)
        selection = theme.accent.platformColor.withAlphaComponent(theme.isDark ? 0.35 : 0.22)
        highlighter = theme.highlighter.mapValues { $0.platformColor }
        priorityColors = Dictionary(uniqueKeysWithValues: TaskPriority.allCases.map { ($0, $0.color.platformColor) })
        pitch = theme.linePitch
        isDark = theme.isDark
    }

    /// `font` with the bold and italic faces of its family. The Mac's font manager
    /// finds the family's real faces; UIKit's descriptor traits do the same there.
    static func face(_ font: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        #if canImport(AppKit)
        let fm = NSFontManager.shared
        var f = font
        if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        return f
        #else
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let d = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: d, size: font.pointSize)
        #endif
    }

    /// Attributes that make syntax characters take (almost) no space and no ink.
    public var hiddenAttributes: [NSAttributedString.Key: Any] { Self.hidden }

    // Immutable after creation; built once instead of on every styled line.
    nonisolated(unsafe) private static let hidden: [NSAttributedString.Key: Any] =
        [.font: PlatformFont.systemFont(ofSize: 0.01), .foregroundColor: PlatformColor.clear]

    public var baseParagraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = pitch
        p.maximumLineHeight = pitch
        p.lineSpacing = 0
        p.paragraphSpacing = 0
        return p
    }

    public var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: ink, .paragraphStyle: baseParagraphStyle]
    }
}
