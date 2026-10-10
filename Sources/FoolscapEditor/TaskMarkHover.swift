import AppKit
import FoolscapCore

/// The task mark under the pointer: a tint behind the `[ ]` says it can be
/// clicked (the click itself is handled in `mouseDown`).
extension MarkdownTextView {
    /// The `[ ]` of a task line, as a character range, when the point is on it.
    func taskMarkRange(at point: NSPoint) -> (line: Int, range: NSRange)? {
        let index = characterIndexForInsertion(at: point)
        guard let line = styler.blockMap.line(at: index), case .task = line.kind, !styler.isHidden(line: line.index),
              let parsed = TaskLineParser.parse(line.text) else { return nil }
        let range = NSRange(location: line.range.location + parsed.markOffset - 1, length: 3)
        guard let rect = characterRect(for: range), rect.insetBy(dx: -3, dy: -1).contains(point) else { return nil }
        return (line.index, range)
    }

    func taskMark(at point: NSPoint) -> Int? { taskMarkRange(at: point)?.line }

    func setHoverTaskMark(_ line: Int?) {
        guard line != hoverTaskMark else { return }
        var changed: Set<Int> = []
        if let old = hoverTaskMark { changed.insert(old) }
        if let line { changed.insert(line) }
        hoverTaskMark = line
        invalidate(lines: changed)
    }

    /// Drawn before the text, so the glyphs sit on the tint.
    func drawTaskMarkHover(in rect: NSRect) {
        guard let i = hoverTaskMark, i < styler.blockMap.lines.count else { return }
        let line = styler.blockMap.lines[i]
        guard case .task = line.kind, let parsed = TaskLineParser.parse(line.text),
              let glyphs = characterRect(for: NSRange(location: line.range.location + parsed.markOffset - 1, length: 3)),
              glyphs.intersects(rect) else { return }
        palette.accent.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: glyphs.insetBy(dx: -3, dy: -1), xRadius: 3, yRadius: 3).fill()
    }
}
