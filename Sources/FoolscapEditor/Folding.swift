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

    // MARK: Hover

    // The chevrons and pills themselves are drawn by `EditorDecorations`.

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
        setHoverTaskMark(taskMark(at: point))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverHeading(nil)
        setHoverTaskMark(nil)
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
