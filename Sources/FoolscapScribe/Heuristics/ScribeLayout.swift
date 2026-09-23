import Foundation

// Ported from notes_sync.py in KindleScribeSync-mac. Units are fractions of the page.

/// A row further than this many typical row pitches from the previous one starts a paragraph.
let paragraphGap = 1.6
/// A TODO line reaching this far across the page ran out of room and wraps onto the next line.
let wrapMargin = 0.80
/// Two OCR readings this similar are the same handwritten TODO read slightly differently.
let sameTodoRatio = 0.80

/// One line of handwriting: OCR fragments at the same height, joined left to right.
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(_ text: String, x: Double, y: Double, w: Double, h: Double) {
        self.text = text; self.x = x; self.y = y; self.w = w; self.h = h
    }

    public var middle: Double { y + h / 2 }
    public var right: Double { x + w }
}

public enum ScribeLayout {
    /// Pick between Vision's readings of a fragment. It reads a handwritten "TODO:"
    /// as "TODD:" often enough to lose tasks, while scoring both readings the same.
    /// So when its first choice carries no TODO marker and one of its alternates
    /// does, take the alternate; Vision has to have proposed it, which keeps a real
    /// "Todd:" safe.
    public static func preferredReading(_ observation: OCRObservation) -> String {
        let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, ScribeTodos.splitTodo(text) == nil {
            for alternate in observation.alternates where ScribeTodos.splitTodo(alternate) != nil {
                return alternate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }

    /// Arrange one page's OCR fragments into paragraphs of lines. Vision often
    /// returns a handwritten line in several pieces, in no dependable order, so
    /// pieces at the same height are joined left to right; a skipped rule starts
    /// a new paragraph.
    public static func layoutPage(_ observations: [OCRObservation]) -> [[TextLine]] {
        let fragments = observations
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { TextLine(preferredReading($0), x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
            .enumerated()
            .sorted { ($0.element.middle, $0.offset) < ($1.element.middle, $1.offset) }
            .map(\.element)
        var rows: [[TextLine]] = []
        for fragment in fragments {
            if let last = rows.last, sharesRow(last, fragment) {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        let lines = rows.map(joinRow)
        guard let first = lines.first else { return [] }

        var paragraphs: [[TextLine]] = [[first]]
        if lines.count > 1 {
            let pitches = zip(lines, lines.dropFirst()).map { $1.middle - $0.middle }
            let typical = median(pitches)
            for (line, pitch) in zip(lines.dropFirst(), pitches) {
                if pitch > typical * paragraphGap {
                    paragraphs.append([line])
                } else {
                    paragraphs[paragraphs.count - 1].append(line)
                }
            }
        }
        return paragraphs
    }

    public static func layoutPages(_ ocr: OCRResult) -> [[[TextLine]]] {
        ocr.pages.map { layoutPage($0.observations) }
    }

    static func horizontalOverlap(_ a: TextLine, _ b: TextLine) -> Double {
        max(0, min(a.right, b.right) - max(a.x, b.x))
    }

    static func sharesRow(_ row: [TextLine], _ fragment: TextLine) -> Bool {
        let top = row.map(\.y).min()!
        let bottom = row.map { $0.y + $0.h }.max()!
        if abs(fragment.middle - (top + bottom) / 2) > 0.5 * min(bottom - top, fragment.h) { return false }
        // Text stacked over other text (a word squeezed in above a line) is its own line.
        return row.allSatisfy { horizontalOverlap(fragment, $0) <= 0.2 * min(fragment.w, $0.w) }
    }

    static func joinRow(_ row: [TextLine]) -> TextLine {
        let sorted = row.enumerated().sorted { ($0.element.x, $0.offset) < ($1.element.x, $1.offset) }.map(\.element)
        let x = sorted.map(\.x).min()!
        let y = sorted.map(\.y).min()!
        return TextLine(sorted.map(\.text).joined(separator: " "), x: x, y: y,
                        w: sorted.map(\.right).max()! - x, h: sorted.map { $0.y + $0.h }.max()! - y)
    }

    /// `statistics.median`: the mean of the two middle values when the count is even.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }
}
