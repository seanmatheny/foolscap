import AppKit
import FoolscapCore
import FoolscapStore

/// Editor geometry.
enum EditorMetrics {
    static let leftInset: CGFloat = 58
    static let rightInset: CGFloat = 36
    static let marginRuleOffset: CGFloat = 16   // red line sits this far left of the text
    static let topLines: CGFloat = 1            // ruled lines above the first text line
}

/// A TextKit 2 text view whose storage is the document's markdown. Draws the
/// paper ruling itself so lines scroll with the text and text sits on them.
public final class MarkdownTextView: NSTextView {
    var palette: EditorPalette
    let styler: MarkdownStyler
    let document: NoteDocument
    /// Distance from a line fragment's top to the baseline, measured from layout.
    private var measuredBaseline: CGFloat?

    public init(document: NoteDocument, palette: EditorPalette) {
        self.palette = palette
        self.document = document
        self.styler = MarkdownStyler(palette: palette)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = document.textStorage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        configure()
        styler.attach(to: document.textStorage)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        applyPalette()
    }

    func applyPalette() {
        // Plain-text views paint with these, not with storage attributes.
        textColor = palette.ink
        font = palette.body
        insertionPointColor = palette.ink
        selectedTextAttributes = [.backgroundColor: palette.selection]
        typingAttributes = palette.baseAttributes
        textContainerInset = NSSize(width: EditorMetrics.leftInset, height: palette.pitch * EditorMetrics.topLines)
        needsDisplay = true
    }

    /// Re-apply all display attributes (after a palette change).
    func restyleAll() {
        styler.palette = palette
        styler.restyleAll()
    }

    // MARK: Clicks

    /// Clicking a task's checkbox cycles its status; clicks on links open them.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if event.clickCount == 1, let line = styler.blockMap.line(at: index), case .task = line.kind,
           let parsed = TaskLineParser.parse(line.text) {
            let markRange = NSRange(location: line.range.location + parsed.markOffset - 1, length: 3)
            if NSLocationInRange(index, NSRange(location: markRange.location, length: markRange.length + 1)),
               let replaced = TaskLineParser.replacingStatus(in: line.text, with: parsed.status.next),
               shouldChangeText(in: line.range, replacementString: replaced) {
                textStorage?.replaceCharacters(in: line.range, with: replaced)
                didChangeText()
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Ruling

    private func baselineOffset() -> CGFloat {
        if let measuredBaseline { return measuredBaseline }
        guard let tlm = textLayoutManager, let start = tlm.documentRange.location as NSTextLocation? else { return palette.pitch * 0.78 }
        var result: CGFloat?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first {
                result = line.glyphOrigin.y
            }
            return false
        }
        if let r = result, r > 0 { measuredBaseline = r }
        return result ?? palette.pitch * 0.78
    }

    public override func draw(_ dirtyRect: NSRect) {
        drawRuling(in: dirtyRect)
        drawCodeBlocks(in: dirtyRect)
        super.draw(dirtyRect)
    }

    /// Frames (in view coordinates) of the layout fragments covering a character range.
    func fragmentRect(for range: NSRange) -> NSRect? {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager else { return nil }
        let doc = tlm.documentRange
        guard let start = cm.location(doc.location, offsetBy: range.location) else { return nil }
        let endOffset = range.location + range.length
        var rect: NSRect?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let fStart = cm.offset(from: doc.location, to: fragment.rangeInElement.location)
            if fStart >= endOffset && range.length > 0 { return false }
            var f = fragment.layoutFragmentFrame
            f.origin.x += textContainerInset.width
            f.origin.y += textContainerInset.height
            rect = rect.map { $0.union(f) } ?? f
            let fEnd = cm.offset(from: doc.location, to: fragment.rangeInElement.endLocation)
            return fEnd < endOffset
        }
        return rect
    }

    private func drawCodeBlocks(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lines = styler.blockMap.lines
        var i = 0
        while i < lines.count {
            guard case .fenceOpen = lines[i].kind else { i += 1; continue }
            var j = i
            while j + 1 < lines.count, lines[j].kind != .fenceClose { j += 1 }
            let range = NSRange(location: lines[i].range.location,
                                length: lines[j].range.location + lines[j].range.length - lines[i].range.location)
            if let r = fragmentRect(for: range), r.intersects(rect) {
                let block = NSRect(x: textContainerInset.width - 10, y: r.minY - 2,
                                   width: bounds.width - textContainerInset.width * 2 + 20, height: r.height + 4)
                let path = NSBezierPath(roundedRect: block, xRadius: 5, yRadius: 5)
                ctx.setFillColor(palette.codeBlockBackground.cgColor)
                ctx.addPath(path.cgPath); ctx.fillPath()
                ctx.setStrokeColor(palette.dimInk.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5)
                ctx.addPath(path.cgPath); ctx.strokePath()
            }
            i = j + 1
        }
    }

    private func drawRuling(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pitch = palette.pitch
        let top = textContainerInset.height
        // Rules sit just under the baseline of each line.
        let ruleOffset = baselineOffset() + 3
        ctx.saveGState()
        ctx.setLineWidth(0.8)
        let rule = palette.ruleColor.cgColor
        let firstLine = max(0, Int((rect.minY - top - ruleOffset) / pitch) - 1)
        let lastLine = Int((rect.maxY - top - ruleOffset) / pitch) + 1
        switch palette.ruling {
        case .blank: break
        case .lined:
            ctx.setStrokeColor(rule)
            for i in firstLine...lastLine {
                let y = top + ruleOffset + CGFloat(i) * pitch + 0.5
                ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(rule); ctx.setLineWidth(0.5)
            for i in firstLine...lastLine {
                let y = top + ruleOffset + CGFloat(i) * pitch + 0.5
                ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            var x = EditorMetrics.leftInset.truncatingRemainder(dividingBy: pitch) + 0.5
            while x < bounds.maxX {
                if x >= rect.minX - pitch { ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)) }
                x += pitch
            }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(rule)
            for i in firstLine...lastLine {
                let y = top + ruleOffset + CGFloat(i) * pitch
                var x = EditorMetrics.leftInset.truncatingRemainder(dividingBy: pitch)
                while x < bounds.maxX {
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
}
