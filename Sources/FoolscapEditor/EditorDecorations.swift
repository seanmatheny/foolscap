import Foundation
import CoreGraphics
import FoolscapCore
import FoolscapUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// The page's own drawing (ruling, code backdrops, quote bars, bullets, task-mark
// tint, fold chevrons and pills) and the layout geometry it reads, kept apart from
// the Mac text view so an iOS twin can draw the same page: a TextKit 2 UITextView
// draws its text in fragment subviews, so the decorations must be painted from
// platform-neutral code into whatever context the host hands over. Only
// CoreGraphics, Foundation and the TextKit 2 types both platforms share are used
// here; colours and fonts come through `PlatformColor`/`PlatformFont`.

/// What the decorations read from the text view that hosts them. The Mac view is
/// one (`MarkdownTextView`); the iOS view will be another.
@MainActor
protocol DecorationGeometry: AnyObject {
    var textLayoutManager: NSTextLayoutManager? { get }
    /// Where the text container's origin sits in view coordinates: the inset
    /// above and to the left of the text.
    var textOrigin: CGPoint { get }
    /// The view's width: backdrops span it and the grid's columns run out to it.
    var viewWidth: CGFloat { get }
    var styler: MarkdownStyler { get }
    var palette: EditorPalette { get }
    /// The heading under the pointer, whose chevron draws firmer.
    var hoverHeading: Int? { get }
    /// The task line whose `[ ]` mark is under the pointer (tinted, to say it is clickable).
    var hoverTaskMark: Int? { get }
    /// The "n lines" pills drawn after folded headings, kept for hit testing.
    var foldPills: [Int: CGRect] { get set }
}

// MARK: - Geometry

extension DecorationGeometry {
    /// The frame of one character (in view coordinates), from the existing layout.
    func characterRect(for range: NSRange) -> CGRect? {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager,
              let start = cm.location(tlm.documentRange.location, offsetBy: range.location),
              let end = cm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var rect: CGRect?
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rect = frame
            return false
        }
        guard var r = rect else { return nil }
        r.origin.x += textOrigin.x
        r.origin.y += textOrigin.y
        return r
    }

    /// The UTF-16 offsets whose laid-out text lies under `rect` (plus a margin),
    /// looked up in the existing layout so drawing never lays out the rest of the note.
    func characterSpan(under rect: CGRect) -> (first: Int, last: Int)? {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager, !styler.blockMap.lines.isEmpty else { return nil }
        let doc = tlm.documentRange
        let margin = palette.pitch * 2
        let top = CGPoint(x: 0, y: max(0, rect.minY - margin - textOrigin.y))
        let bottom = CGPoint(x: 0, y: rect.maxY + margin - textOrigin.y)
        let first = tlm.textLayoutFragment(for: top).map { cm.offset(from: doc.location, to: $0.rangeInElement.location) } ?? 0
        let last = tlm.textLayoutFragment(for: bottom).map { cm.offset(from: doc.location, to: $0.rangeInElement.endLocation) }
            ?? cm.offset(from: doc.location, to: doc.endLocation)
        guard first <= last else { return nil }
        return (first, last)
    }

    /// Bottom of the last text line of the paragraph at `range` (excludes paragraph spacing).
    /// The document's last paragraph, when the text ends with a newline, also carries
    /// the empty line after it (TextKit's extra line fragment); that one is skipped, or
    /// an image on the last line is drawn over the empty line below its reserved space.
    func lineBottom(for range: NSRange) -> CGFloat? {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager,
              let start = cm.location(tlm.documentRange.location, offsetBy: range.location) else { return nil }
        var bottom: CGFloat?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let lines = fragment.textLineFragments
            if let last = lines.last(where: { $0.characterRange.length > 0 }) ?? lines.last {
                bottom = fragment.layoutFragmentFrame.minY + last.typographicBounds.maxY + textOrigin.y
            }
            return false
        }
        return bottom
    }

    /// Frames (in view coordinates) of the layout fragments covering a character range.
    func fragmentRect(for range: NSRange) -> CGRect? {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager else { return nil }
        let doc = tlm.documentRange
        guard let start = cm.location(doc.location, offsetBy: range.location) else { return nil }
        let endOffset = range.location + range.length
        var rect: CGRect?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let fStart = cm.offset(from: doc.location, to: fragment.rangeInElement.location)
            if fStart >= endOffset && range.length > 0 { return false }
            var f = fragment.layoutFragmentFrame
            f.origin.x += textOrigin.x
            f.origin.y += textOrigin.y
            rect = rect.map { $0.union(f) } ?? f
            let fEnd = cm.offset(from: doc.location, to: fragment.rangeInElement.endLocation)
            return fEnd < endOffset
        }
        return rect
    }

    /// Code blocks and quotes whose text lies under `rect`. Only the characters
    /// under the rect (plus a margin) are measured, so drawing never lays out the
    /// rest of the document; a block that runs on past them is extended beyond it.
    func decorations(in rect: CGRect) -> [EditorDecorations.Decoration] {
        let lines = styler.blockMap.lines
        guard let (first, last) = characterSpan(under: rect) else { return [] }
        let pitch = palette.pitch

        var out: [EditorDecorations.Decoration] = []
        func add(from i: Int, to j: Int, code: String?) {
            // A block inside a folded section is hidden with it (folds end only at headings, so blocks are never cut).
            guard !styler.isHidden(line: i) else { return }
            let start = lines[i].range.location, end = lines[j].range.location + lines[j].range.length
            guard end >= first, start <= last else { return }
            let clipStart = max(start, first), clipEnd = min(end, last)
            guard var r = fragmentRect(for: NSRange(location: clipStart, length: clipEnd - clipStart)) else { return }
            if start < first { r.origin.y -= pitch; r.size.height += pitch }
            if end > last { r.size.height += pitch }
            guard r.intersects(rect) else { return }
            if let code {
                out.append(EditorDecorations.Decoration(kind: .code(language: start < first ? nil : code), rect: r))
            } else {
                out.append(EditorDecorations.Decoration(kind: .quote, rect: r))
            }
        }
        // Back up to the start of a block that begins above the measured span.
        var i = styler.blockMap.line(at: first)?.index ?? 0
        backUp: while i > 0 {
            switch lines[i].kind {
            case .fenceInside, .fenceClose: i -= 1
            case .quote where lines[i - 1].kind == .quote: i -= 1
            default: break backUp
            }
        }
        while i < lines.count, lines[i].range.location <= last {
            switch lines[i].kind {
            case .fenceOpen(let language):
                var j = i
                while j + 1 < lines.count, lines[j].kind != .fenceClose { j += 1 }
                add(from: i, to: j, code: language)
                i = j + 1
            case .quote:
                var j = i
                while j + 1 < lines.count, lines[j + 1].kind == .quote { j += 1 }
                add(from: i, to: j, code: nil)
                i = j + 1
            default:
                i += 1
            }
        }
        return out
    }
}

// MARK: - Drawing

/// Paints the page's decorations for a `DecorationGeometry` into a context whose
/// coordinates are the view's (origin top left, y down). `drawUnderText` goes
/// before the text is drawn and `drawOverText` after it: the Mac view's text
/// drawing leaves the context clipped to the text container, and the chevrons sit
/// in the margin outside it, while the bullets must cover the `-` they stand for.
@MainActor
struct EditorDecorations {
    struct Decoration: Equatable {
        enum Kind: Equatable {
            /// `language` is nil when the fence line lies outside the measured text.
            case code(language: String?)
            case quote
        }
        var kind: Kind
        /// The block's layout fragments, in view coordinates.
        var rect: CGRect
    }

    /// The chevron sits between the margin rule and the text.
    static var foldChevronX: CGFloat { EditorMetrics.leftInset - 9 }

    let geometry: any DecorationGeometry

    init(geometry: any DecorationGeometry) { self.geometry = geometry }

    private var palette: EditorPalette { geometry.palette }
    private var styler: MarkdownStyler { geometry.styler }

    /// Ruling, code backdrops, quote bars, the hovered task mark's tint, then the
    /// fold chevrons and pills, in that order.
    func drawUnderText(in ctx: CGContext, rect: CGRect) {
        withCurrent(ctx) {
            drawRuling(in: ctx, rect: rect)
            let visible = geometry.decorations(in: rect)
            drawCodeBlocks(visible, in: ctx)
            drawQuoteBars(visible, in: ctx)
            drawTaskMarkHover(in: ctx, rect: rect)
            drawFoldControls(in: ctx, rect: rect)
        }
    }

    /// The list bullets, drawn over the text so they cover its `-`.
    func drawOverText(in ctx: CGContext, rect: CGRect) {
        withCurrent(ctx) { drawBullets(in: ctx, rect: rect) }
    }

    /// Text goes through `NSAttributedString.draw`, which paints into the
    /// platform's current context, so the passed one is made current meanwhile.
    private func withCurrent(_ ctx: CGContext, _ body: () -> Void) {
        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        #elseif canImport(UIKit)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        #endif
        body()
    }

    /// A rounded rectangle; the radius never exceeds half a side, as `CGPath` insists.
    private func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    // MARK: Ruling

    private func drawRuling(in ctx: CGContext, rect: CGRect) {
        let pitch = palette.pitch
        // Fixed to the page, not the text: a header above the text moves the text by whole lines.
        let top = pitch * EditorMetrics.topLines
        // Rules sit just under the baseline of each line.
        let ruleOffset = PageRuling.ruleOffset(palette)
        let right = geometry.viewWidth
        ctx.saveGState()
        ctx.setLineWidth(0.8)
        let rule = palette.ruleColor.cgColor
        let firstLine = max(0, Int((rect.minY - top - ruleOffset) / pitch) - 1)
        let lastLine = Int((rect.maxY - top - ruleOffset) / pitch) + 1
        // Empty (not a trap) when the dirty rect lies wholly above the first rule,
        // as it does while a scroll bounces past the top of the page.
        let lines = stride(from: firstLine, through: lastLine, by: 1)
        switch palette.ruling {
        case .blank: break
        case .lined:
            ctx.setStrokeColor(rule)
            for i in lines {
                let y = top + ruleOffset + CGFloat(i) * pitch
                ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(rule); ctx.setLineWidth(0.5)
            for i in lines {
                let y = top + ruleOffset + CGFloat(i) * pitch
                ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            var x = EditorMetrics.leftInset.truncatingRemainder(dividingBy: pitch) + 0.5
            while x < right {
                if x >= rect.minX - pitch { ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)) }
                x += pitch
            }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(rule)
            for i in lines {
                let y = top + ruleOffset + CGFloat(i) * pitch
                var x = EditorMetrics.leftInset.truncatingRemainder(dividingBy: pitch)
                while x < right {
                    ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += pitch
                }
            }
        }
        if palette.showMarginRule {
            ctx.setStrokeColor(palette.marginRuleColor.cgColor); ctx.setLineWidth(1)
            let x = EditorMetrics.leftInset - EditorMetrics.marginRuleOffset + 0.5
            ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)); ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: Code backdrops and quote bars

    private func drawCodeBlocks(_ decorations: [Decoration], in ctx: CGContext) {
        let inset = geometry.textOrigin.x
        for d in decorations {
            guard case .code(let language) = d.kind else { continue }
            let r = d.rect
            let block = CGRect(x: inset - 10, y: r.minY - 2,
                               width: geometry.viewWidth - inset * 2 + 20, height: r.height + 4)
            let path = roundedPath(block, radius: 5)
            ctx.setFillColor(palette.codeBlockBackground.cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(palette.dimInk.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5)
            ctx.addPath(path); ctx.strokePath()
            if let language, !language.isEmpty {
                let label = NSAttributedString(string: language, attributes: [
                    .font: PlatformFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: palette.dimInk.withAlphaComponent(0.6)])
                let size = label.size()
                label.draw(at: CGPoint(x: block.maxX - size.width - 8, y: block.minY + 5))
            }
        }
    }

    private func drawQuoteBars(_ decorations: [Decoration], in ctx: CGContext) {
        for d in decorations where d.kind == .quote {
            let r = d.rect
            let bar = CGRect(x: geometry.textOrigin.x + 2, y: r.minY + 3, width: 3, height: r.height - 6)
            ctx.setFillColor(palette.accent.withAlphaComponent(0.55).cgColor)
            ctx.addPath(roundedPath(bar, radius: 1.5)); ctx.fillPath()
        }
    }

    // MARK: Task mark under the pointer

    /// Drawn before the text, so the glyphs sit on the tint.
    private func drawTaskMarkHover(in ctx: CGContext, rect: CGRect) {
        guard let i = geometry.hoverTaskMark, i < styler.blockMap.lines.count else { return }
        let line = styler.blockMap.lines[i]
        guard case .task = line.kind, let parsed = TaskLineParser.parse(line.text),
              let glyphs = geometry.characterRect(for: NSRange(location: line.range.location + parsed.markOffset - 1, length: 3)),
              glyphs.intersects(rect) else { return }
        ctx.setFillColor(palette.accent.withAlphaComponent(0.14).cgColor)
        ctx.addPath(roundedPath(glyphs.insetBy(dx: -3, dy: -1), radius: 3)); ctx.fillPath()
    }

    // MARK: Fold controls in the margin

    /// Chevrons beside every heading with lines under it (faint while open, firmer
    /// under the pointer or caret, solid when folded) and a "n lines" pill after a
    /// folded heading's text.
    private func drawFoldControls(in ctx: CGContext, rect: CGRect) {
        guard let span = geometry.characterSpan(under: rect) else { return }
        let lines = styler.blockMap.lines
        let storage = (geometry.textLayoutManager?.textContentManager as? NSTextContentStorage)?.textStorage
        var pills: [Int: CGRect] = [:]
        var i = styler.blockMap.line(at: span.first)?.index ?? 0
        while i < lines.count, lines[i].range.location <= span.last {
            defer { i += 1 }
            let line = lines[i]
            guard case .heading = line.kind, !styler.isHidden(line: i), styler.sectionEnd(afterHeading: i) > i + 1 else { continue }
            let folded = styler.isFolded(heading: i)
            guard let frame = geometry.fragmentRect(for: line.range) else { continue }
            let active = geometry.hoverHeading == i || styler.isRevealed(line: i)
            let cy = frame.minY + palette.pitch * 0.55
            let cx = Self.foldChevronX
            ctx.saveGState()
            ctx.setStrokeColor(palette.dimInk.withAlphaComponent(folded ? 0.9 : (active ? 0.6 : 0.3)).cgColor)
            ctx.setLineWidth(1.6); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            if folded {
                ctx.move(to: CGPoint(x: cx - 2, y: cy - 3.5)); ctx.addLine(to: CGPoint(x: cx + 2, y: cy)); ctx.addLine(to: CGPoint(x: cx - 2, y: cy + 3.5))
            } else {
                ctx.move(to: CGPoint(x: cx - 3.5, y: cy - 2)); ctx.addLine(to: CGPoint(x: cx, y: cy + 2)); ctx.addLine(to: CGPoint(x: cx + 3.5, y: cy - 2))
            }
            ctx.strokePath()
            ctx.restoreGState()
            guard folded, let storage else { continue }
            let hidden = styler.sectionEnd(afterHeading: i) - i - 1
            let label = NSAttributedString(string: hidden == 1 ? "1 line" : "\(hidden) lines", attributes: [
                .font: PlatformFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: palette.dimInk])
            let textWidth = storage.attributedSubstring(from: line.range).size().width
            let size = label.size()
            let pill = CGRect(x: EditorMetrics.leftInset + textWidth + 10, y: cy - 8.5, width: size.width + 14, height: 17)
            ctx.setFillColor(palette.dimInk.withAlphaComponent(0.13).cgColor)
            ctx.addPath(roundedPath(pill, radius: 8.5)); ctx.fillPath()
            label.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + (pill.height - size.height) / 2))
            pills[i] = pill
        }
        // Pills scrolled out of the dirty rect keep their last frames for hit testing.
        for (index, pill) in geometry.foldPills where !pill.intersects(rect) { pills[index] = pills[index] ?? pill }
        geometry.foldPills = pills
    }

    // MARK: List bullets

    /// The dot standing in for a `-`, `*` or `+` (drawn as text in the body font so
    /// it shares the line's baseline); nested items get a ring, then a small square.
    private func drawBullets(in ctx: CGContext, rect: CGRect) {
        guard let span = geometry.characterSpan(under: rect) else { return }
        let lines = styler.blockMap.lines
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = palette.pitch; ps.maximumLineHeight = palette.pitch
        ps.alignment = .center
        var i = styler.blockMap.line(at: span.first)?.index ?? 0
        while i < lines.count, lines[i].range.location <= span.last {
            defer { i += 1 }
            let line = lines[i]
            guard case .listItem = line.kind, !styler.isHidden(line: i), !styler.isRevealed(line: i),
                  let prefix = LinePrefix.parse(line.text), case .bullet = prefix.kind else { continue }
            let marker = NSRange(location: line.range.location + (prefix.indent as NSString).length, length: 1)
            guard let glyph = geometry.characterRect(for: marker), glyph.intersects(rect) else { continue }
            let level = prefix.indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            let dot = level == 0 ? "•" : level == 1 ? "◦" : "▪"
            let attrs: [NSAttributedString.Key: Any] = [.font: palette.body, .foregroundColor: palette.accent, .paragraphStyle: ps]
            let width = (dot as NSString).size(withAttributes: [.font: palette.body]).width + 2
            NSAttributedString(string: dot, attributes: attrs)
                .draw(in: CGRect(x: glyph.midX - width / 2, y: glyph.minY, width: width, height: glyph.height))
        }
    }
}
