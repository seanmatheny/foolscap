import AppKit
import FoolscapCore
import FoolscapUI

/// Everything the text view needs from a theme, resolved to AppKit types once.
public struct EditorPalette {
    public var ink: NSColor
    public var dimInk: NSColor
    public var accent: NSColor
    public var paper: NSColor
    public var ruleColor: NSColor
    public var marginRuleColor: NSColor
    public var ruling: Ruling
    public var showMarginRule: Bool
    public var body: NSFont
    public var mono: NSFont
    public var headings: [NSFont]   // index 0 = h1
    public var bold: NSFont
    public var italic: NSFont
    public var codeBackground: NSColor
    /// Opaque backdrop for fenced code blocks (hides the ruling).
    public var codeBlockBackground: NSColor
    public var tagBackground: NSColor
    public var selection: NSColor
    public var highlighter: [TaskStatus: NSColor]
    /// Colours of the `!` priority markers on task lines.
    public var priorityColors: [TaskPriority: NSColor]
    /// Line pitch: every body line is exactly this tall so text sits on the ruling.
    public var pitch: CGFloat
    public var isDark: Bool

    public init(theme: NotebookTheme) {
        ink = theme.ink.nsColor
        dimInk = theme.dimInk.nsColor
        accent = theme.accent.nsColor
        paper = theme.page.paperColor.nsColor
        ruleColor = theme.page.ruleColor.nsColor
        marginRuleColor = theme.page.marginRuleColor.nsColor
        ruling = theme.page.ruling
        showMarginRule = theme.page.marginRule
        body = theme.type.body.nsFont
        mono = theme.type.mono.nsFont
        let h = theme.type.heading
        let bodySize = theme.type.body.size
        headings = [1.6, 1.33, 1.17, 1.07, 1.03, 1.0].map { ratio in
            FontSpec(family: h.family, size: (bodySize * ratio).rounded(), design: h.design, bold: true).nsFont
        }
        let fm = NSFontManager.shared
        bold = fm.convert(body, toHaveTrait: .boldFontMask)
        italic = fm.convert(body, toHaveTrait: .italicFontMask)
        codeBackground = theme.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05)
        codeBlockBackground = theme.page.paperColor.nsColor.blended(withFraction: theme.isDark ? 0.08 : 0.055,
                                                                     of: theme.isDark ? .white : .black) ?? paper
        tagBackground = theme.accent.nsColor.withAlphaComponent(0.14)
        selection = theme.accent.nsColor.withAlphaComponent(theme.isDark ? 0.35 : 0.22)
        highlighter = theme.highlighter.mapValues { $0.nsColor }
        priorityColors = Dictionary(uniqueKeysWithValues: TaskPriority.allCases.compactMap { p in p.color.map { (p, $0.nsColor) } })
        pitch = theme.linePitch
        isDark = theme.isDark
    }

    /// Attributes that make syntax characters take (almost) no space and no ink.
    public var hiddenAttributes: [NSAttributedString.Key: Any] { Self.hidden }

    // Immutable after creation; built once instead of on every styled line.
    nonisolated(unsafe) private static let hidden: [NSAttributedString.Key: Any] =
        [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]

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
