import AppKit
import FoolscapCore

/// Which sections of which notes are folded shut, remembered across launches.
/// Keyed on the note's path and the heading line's own text: the file never
/// carries a marker.
enum FoldMemory {
    static let key = "foldedSections"
    /// Where the folds are kept; tests point this at a throwaway suite.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static func folded(for path: String, defaults: UserDefaults = FoldMemory.defaults) -> Set<String> {
        let all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[path] ?? [])
    }

    static func save(_ headings: Set<String>, for path: String, defaults: UserDefaults = FoldMemory.defaults) {
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        if headings.isEmpty { all[path] = nil } else { all[path] = headings.sorted() }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }
}

// MARK: - Fold controls in the margin

extension MarkdownTextView {
    /// The chevron sits between the margin rule and the text.
    static let foldChevronX: CGFloat = EditorMetrics.leftInset - 9

    /// The heading whose chevron or "n lines" pill is under `point`, if any.
    func foldControl(at point: NSPoint) -> Int? {
        for (index, rect) in foldPills where rect.insetBy(dx: -3, dy: -3).contains(point) { return index }
        let zone = (EditorMetrics.leftInset - EditorMetrics.marginRuleOffset)...(EditorMetrics.leftInset - 2)
        guard zone.contains(point.x) else { return nil }
        let index = characterIndexForInsertion(at: NSPoint(x: EditorMetrics.leftInset + 2, y: point.y))
        guard let line = styler.blockMap.line(at: index), case .heading = line.kind,
              styler.sectionEnd(afterHeading: line.index) > line.index + 1,
              let rect = fragmentRect(for: line.range), rect.minY <= point.y, point.y < rect.minY + palette.pitch else { return nil }
        return line.index
    }

    /// Fold or unfold the section under a heading; a caret left inside goes to the heading's end.
    func setFold(_ folded: Bool, heading index: Int) {
        guard styler.isFolded(heading: index) != folded else { return }
        styler.setFolded(folded, heading: index)
        caretOutOfHiddenText(preferring: index)
    }

    func toggleFold(heading index: Int) { setFold(!styler.isFolded(heading: index), heading: index) }

    /// After a fold, a caret that was in the section moves to the end of its heading.
    private func caretOutOfHiddenText(preferring heading: Int?) {
        let caret = selectedRange()
        guard caret.length == 0, let line = styler.blockMap.line(at: caret.location), styler.isHidden(line: line.index) else { return }
        var index = heading ?? line.index
        while index > 0, styler.isHidden(line: index) { index -= 1 }
        let h = styler.blockMap.lines[index].range
        setSelectedRange(NSRange(location: h.location + h.length, length: 0))
    }

    /// The heading the caret's line belongs to: the line itself when it is one, else the nearest above.
    private func headingForCaret() -> Int? {
        guard let line = styler.blockMap.line(at: selectedRange().location) else { return nil }
        var i = line.index
        while i >= 0 {
            if case .heading = styler.blockMap.lines[i].kind { return i }
            i -= 1
        }
        return nil
    }

    @objc func foldSection(_ sender: Any?) {
        guard let h = headingForCaret(), styler.sectionEnd(afterHeading: h) > h + 1 else { NSSound.beep(); return }
        setFold(true, heading: h)
        needsDisplay = true
    }

    @objc func unfoldSection(_ sender: Any?) {
        guard var i = headingForCaret() else { NSSound.beep(); return }
        // The caret's own heading, or the nearest folded one above it.
        while i >= 0 {
            if styler.isFolded(heading: i) { setFold(false, heading: i); needsDisplay = true; return }
            i -= 1
        }
        NSSound.beep()
    }

    @objc func foldAllSections(_ sender: Any?) {
        styler.setAllFolded(true)
        caretOutOfHiddenText(preferring: nil)
        needsDisplay = true
    }

    @objc func unfoldAllSections(_ sender: Any?) {
        styler.setAllFolded(false)
        needsDisplay = true
    }

    // MARK: Drawing

    /// Chevrons beside every heading with lines under it (faint while open, firmer
    /// under the pointer or caret, solid when folded) and a "n lines" pill after a
    /// folded heading's text.
    func drawFoldControls(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let span = characterSpan(under: rect) else { return }
        let lines = styler.blockMap.lines
        var pills: [Int: NSRect] = [:]
        var i = styler.blockMap.line(at: span.first)?.index ?? 0
        while i < lines.count, lines[i].range.location <= span.last {
            defer { i += 1 }
            let line = lines[i]
            guard case .heading = line.kind, !styler.isHidden(line: i), styler.sectionEnd(afterHeading: i) > i + 1 else { continue }
            let folded = styler.isFolded(heading: i)
            guard let frame = fragmentRect(for: line.range) else { continue }
            let active = hoverHeading == i || styler.isRevealed(line: i)
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
            guard folded, let storage = textStorage else { continue }
            let hidden = styler.sectionEnd(afterHeading: i) - i - 1
            let label = NSAttributedString(string: hidden == 1 ? "1 line" : "\(hidden) lines", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: palette.dimInk])
            let textWidth = storage.attributedSubstring(from: line.range).size().width
            let size = label.size()
            let pill = NSRect(x: EditorMetrics.leftInset + textWidth + 10, y: cy - 8.5, width: size.width + 14, height: 17)
            ctx.setFillColor(palette.dimInk.withAlphaComponent(0.13).cgColor)
            ctx.addPath(NSBezierPath(roundedRect: pill, xRadius: 8.5, yRadius: 8.5).cgPath); ctx.fillPath()
            label.draw(at: NSPoint(x: pill.minX + 7, y: pill.minY + (pill.height - size.height) / 2))
            pills[i] = pill
        }
        // Pills scrolled out of the dirty rect keep their last frames for hit testing.
        for (index, pill) in foldPills where !pill.intersects(rect) { pills[index] = pills[index] ?? pill }
        foldPills = pills
    }

    /// Track the pointer so an open heading shows its chevron while hovered.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let foldTracking { removeTrackingArea(foldTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        foldTracking = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        var hovered: Int?
        if point.x < bounds.width - EditorMetrics.rightInset {
            let index = characterIndexForInsertion(at: NSPoint(x: EditorMetrics.leftInset + 2, y: point.y))
            if let line = styler.blockMap.line(at: index), case .heading = line.kind, !styler.isHidden(line: line.index),
               styler.sectionEnd(afterHeading: line.index) > line.index + 1,
               let rect = fragmentRect(for: line.range), rect.minY <= point.y, point.y < rect.minY + palette.pitch {
                hovered = line.index
            }
        }
        setHoverHeading(hovered)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverHeading(nil)
    }

    private func setHoverHeading(_ index: Int?) {
        guard index != hoverHeading else { return }
        for i in [hoverHeading, index].compactMap({ $0 }) where i < styler.blockMap.lines.count {
            if let rect = fragmentRect(for: styler.blockMap.lines[i].range) {
                setNeedsDisplay(NSRect(x: 0, y: rect.minY - 2, width: bounds.width, height: rect.height + 4))
            }
        }
        hoverHeading = index
    }
}
