import AppKit
import FoolscapCore
import FoolscapStore

/// Applies display attributes to the markdown text storage as it changes.
/// The characters are never touched: only fonts, colours and paragraph styles.
/// Attributes are applied from the storage delegate so every edit path
/// (typing, paste, task write-back, external reload) is styled the same way.
@MainActor
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    var palette: EditorPalette
    private(set) var blockMap = BlockMap(lines: [])
    private var previousFenceLines = 0
    weak var storage: NSTextStorage?
    /// Extra space below a paragraph, for overlay cards (Phase 4).
    var overlayHeights: [Int: CGFloat] = [:]
    var isRestyling = false
    /// Called after every styling pass, outside the storage edit.
    var onStyled: (() -> Void)?
    /// The view whose selection decides which lines show their syntax.
    weak var textView: NSTextView?
    private var activeLines: Set<Int> = []
    /// An image/URL line whose markdown was revealed from its hover badge.
    /// It collapses again as soon as the selection leaves it.
    private(set) var forcedRevealLine: Int?

    init(palette: EditorPalette) {
        self.palette = palette
    }

    func attach(to storage: NSTextStorage) {
        self.storage = storage
        storage.delegate = self
        restyleAll()
    }

    func restyleAll() {
        guard let storage else { return }
        blockMap = BlockMap.scan(storage.string)
        previousFenceLines = fenceLineCount(blockMap)
        activeLines = linesUnderSelection(blockMap)
        style(range: NSRange(location: 0, length: storage.length), map: blockMap)
    }

    /// Lines intersecting the current selection: their markdown syntax stays visible.
    private func linesUnderSelection(_ map: BlockMap) -> Set<Int> {
        guard let textView else { return [] }
        var out: Set<Int> = []
        for value in textView.selectedRanges {
            let r = value.rangeValue
            guard let first = map.line(at: r.location), let last = map.line(at: r.location + r.length) else { continue }
            for i in first.index...last.index { out.insert(i) }
        }
        return out
    }

    /// Reveal syntax on the caret's line and hide it elsewhere.
    func selectionChanged() {
        let now = linesUnderSelection(blockMap)
        var changed = now.symmetricDifference(activeLines)
        if let forced = forcedRevealLine, !now.contains(forced) {
            forcedRevealLine = nil
            changed.insert(forced)
        }
        guard !changed.isEmpty else { return }
        activeLines = now
        restyle(lines: Array(changed))
    }

    /// Show the markdown of an image/URL line (from its badge) until the caret leaves it.
    func forceReveal(line: Int) {
        let previous = forcedRevealLine
        forcedRevealLine = line
        restyle(lines: [previous, line].compactMap { $0 })
    }

    /// True for image/URL lines that are drawn as a hairline (caret must skip them).
    func isCollapsed(line index: Int) -> Bool {
        guard index < blockMap.lines.count else { return false }
        switch blockMap.lines[index].kind {
        case .imageLine, .urlLine: return forcedRevealLine != index
        default: return false
        }
    }

    // MARK: NSTextStorageDelegate

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            guard editedMask.contains(.editedCharacters), !isRestyling, let textStorage = storage else { return }
            let text = textStorage.string as NSString
            let newMap = BlockMap.scan(textStorage.string)
            let paragraphRange = text.paragraphRange(for: editedRange)
            activeLines = linesUnderSelection(newMap)
            let fenceNow = fenceLineCount(newMap)
            let touchesFence = touchesFenceLine(newMap, range: paragraphRange) || touchesFenceLine(blockMap, range: NSRange(location: paragraphRange.location, length: max(0, paragraphRange.length - delta)))
            blockMap = newMap
            let restyle: NSRange
            if fenceNow != previousFenceLines || touchesFence {
                restyle = NSRange(location: paragraphRange.location, length: text.length - paragraphRange.location)
            } else {
                restyle = paragraphRange
            }
            previousFenceLines = fenceNow
            style(range: restyle, map: newMap)
        }
    }

    private func fenceLineCount(_ map: BlockMap) -> Int {
        map.lines.reduce(0) { n, l in
            switch l.kind { case .fenceOpen, .fenceClose: return n + 1; default: return n }
        }
    }

    private func touchesFenceLine(_ map: BlockMap, range: NSRange) -> Bool {
        for line in map.lines where NSIntersectionRange(line.range, range).length > 0 || line.range.location == range.location {
            switch line.kind { case .fenceOpen, .fenceClose: return true; default: break }
            if line.range.location > range.location + range.length { break }
        }
        return false
    }

    // MARK: Styling

    private func style(range: NSRange, map: BlockMap) { style(ranges: [range], map: map) }

    /// Style several ranges in one storage edit, with one `onStyled` at the end.
    private func style(ranges: [NSRange], map: BlockMap) {
        guard let storage else { return }
        let ranges = ranges.filter { $0.length > 0 || storage.length == 0 }
        guard !ranges.isEmpty else { return }
        isRestyling = true
        storage.beginEditing()
        for range in ranges {
            var language = ""
            var inBlockComment = false
            var i = firstLine(endingAtOrAfter: range.location, in: map)
            // Only code lines need the language: find the fence that opens their block.
            if i < map.lines.count, case .fenceInside = map.lines[i].kind {
                for l in map.lines[0..<i].reversed() {
                    if case .fenceOpen(let lang) = l.kind { language = lang; break }
                    if case .fenceClose = l.kind { break }
                }
            }
            while i < map.lines.count {
                let line = map.lines[i]
                i += 1
                if line.range.location >= range.location + range.length && range.length > 0 { break }
                guard NSIntersectionRange(line.range, range).length > 0 || (line.range.length == 0 && NSLocationInRange(line.range.location, range))
                        || line.range.location == range.location else { continue }
                styleLine(line, in: storage, language: &language, inBlockComment: &inBlockComment)
            }
        }
        storage.endEditing()
        isRestyling = false
        onStyled?()
    }

    /// Index of the first line whose range (newline included) reaches `offset`;
    /// no earlier line can intersect a range starting there.
    private func firstLine(endingAtOrAfter offset: Int, in map: BlockMap) -> Int {
        var lo = 0, hi = map.lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let r = map.lines[mid].range
            if r.location + r.length < offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Re-style specific lines (selection moves, overlay heights). Runs of
    /// adjacent lines become one range, all styled in a single pass.
    func restyle(lines indices: [Int]) {
        let map = blockMap
        let sorted = Set(indices).filter { $0 >= 0 && $0 < map.lines.count }.sorted()
        guard let first = sorted.first else { return }
        var ranges: [NSRange] = []
        var start = first, end = first
        func flush() {
            // Through the last line's newline, so an empty last line is still included.
            let a = map.lines[start].range, b = map.lines[end].range
            ranges.append(NSRange(location: a.location, length: b.location + b.length + 1 - a.location))
        }
        for i in sorted.dropFirst() {
            if i == end + 1 { end = i } else { flush(); start = i; end = i }
        }
        flush()
        style(ranges: ranges, map: map)
    }

    private static let headingMarker = try! NSRegularExpression(pattern: #"^#{1,6}\s"#)
    private static let quoteMarker = try! NSRegularExpression(pattern: #"^>\s?"#)
    private static let listMarker = try! NSRegularExpression(pattern: #"^\s*([-*+]|\d+[.)])\s"#)

    /// First match's range, or `NSNotFound` (like `range(of:options: .regularExpression)`).
    private static func match(_ regex: NSRegularExpression, in text: String) -> NSRange {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))?.range
            ?? NSRange(location: NSNotFound, length: 0)
    }

    private func styleLine(_ line: ScannedLine, in storage: NSTextStorage, language: inout String, inBlockComment: inout Bool) {
        // Include the newline so paragraph attributes cover the whole paragraph.
        let paraLength = min(storage.length - line.range.location, line.range.length + 1)
        let para = NSRange(location: line.range.location, length: max(0, paraLength))
        let p = palette
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = p.pitch
        ps.maximumLineHeight = p.pitch
        // Overlay lines (image, URL) collapse to a hairline unless the caret is on them;
        // the reserved block height stays a whole number of ruled lines either way.
        let isOverlay: Bool = { if case .imageLine = line.kind { return true }; if case .urlLine = line.kind { return true }; return false }()
        let collapsed = isOverlay && forcedRevealLine != line.index
        if collapsed { ps.minimumLineHeight = 1; ps.maximumLineHeight = 1 }
        if let total = overlayHeights[line.index] {
            ps.paragraphSpacing = max(0, total - (collapsed ? 1 : p.pitch))
        }
        var base: [NSAttributedString.Key: Any] = [.font: p.body, .foregroundColor: p.ink, .paragraphStyle: ps,
                                                    .backgroundColor: NSColor.clear, .strikethroughStyle: 0, .underlineStyle: 0]
        base[.link] = nil
        let text = line.text as NSString
        func abs(_ r: NSRange) -> NSRange { NSRange(location: line.range.location + r.location, length: r.length) }
        func set(_ attrs: [NSAttributedString.Key: Any], _ r: NSRange) {
            let a = abs(r)
            guard a.location + a.length <= storage.length else { return }
            storage.addAttributes(attrs, range: a)
        }

        // Syntax is dimmed on the caret's line and hidden everywhere else (Bear-style).
        // Image and URL lines are different: the caret never rests on them, so they
        // only reveal when asked from the picture's or card's badge.
        let reveal = isOverlay ? forcedRevealLine == line.index : activeLines.contains(line.index)
        let syntaxAttrs: [NSAttributedString.Key: Any] = reveal ? [.foregroundColor: p.dimInk] : p.hiddenAttributes
        var inlineRange = NSRange(location: 0, length: text.length)
        switch line.kind {
        case .heading(let level):
            base[.font] = p.headings[min(level, p.headings.count) - 1]
            storage.setAttributes(base, range: para)
            let hashes = Self.match(Self.headingMarker, in: line.text)
            if hashes.location != NSNotFound { set(syntaxAttrs, hashes) }
        case .fenceOpen(let lang):
            language = lang; inBlockComment = false
            base[.font] = p.mono; base[.foregroundColor] = p.dimInk
            storage.setAttributes(base, range: para)
            if !reveal { set(p.hiddenAttributes, NSRange(location: 0, length: text.length)) }
            return
        case .fenceClose:
            base[.font] = p.mono; base[.foregroundColor] = p.dimInk
            storage.setAttributes(base, range: para)
            if !reveal { set(p.hiddenAttributes, NSRange(location: 0, length: text.length)) }
            return
        case .fenceInside:
            base[.font] = p.mono
            storage.setAttributes(base, range: para)
            for (token, r) in CodeHighlighter.tokens(in: line.text, language: language, inBlockComment: &inBlockComment) {
                set([.foregroundColor: p.codeColor(for: token)], r)
            }
            return
        case .quote:
            base[.font] = p.italic; base[.foregroundColor] = p.ink.withAlphaComponent(0.8)
            ps.firstLineHeadIndent = 16; ps.headIndent = 16
            storage.setAttributes(base, range: para)
            let marker = Self.match(Self.quoteMarker, in: line.text)
            if marker.location != NSNotFound {
                set(reveal ? [.foregroundColor: p.dimInk, .font: p.body] : p.hiddenAttributes, marker)
            }
            inlineRange = NSRange(location: marker.length, length: text.length - marker.length)
        case .task(let status):
            storage.setAttributes(base, range: para)
            if let parsed = TaskLineParser.parse(line.text) {
                let prefix = NSRange(location: 0, length: parsed.markOffset + 2)
                set([.font: p.mono, .foregroundColor: status == .notStarted ? p.dimInk : p.accent], prefix)
                let titleStart = prefix.location + prefix.length
                let title = NSRange(location: titleStart, length: text.length - titleStart)
                // The priority marker (`!`, `!!`, `!!!`) shows in its light's colour.
                if let marker = TaskLineParser.priorityRange(in: parsed.title), let color = p.priorityColors[TaskLineParser.priority(in: parsed.title)] {
                    var titleOffset = titleStart
                    while titleOffset < text.length, text.character(at: titleOffset) == 0x20 || text.character(at: titleOffset) == 0x09 { titleOffset += 1 }
                    set([.foregroundColor: color, .font: p.bold], NSRange(location: titleOffset + marker.location, length: marker.length))
                }
                if status == .completed {
                    set([.foregroundColor: p.dimInk, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                         .strikethroughColor: p.dimInk], title)
                }
                if let hl = p.highlighter[status], hl.alphaComponent > 0 {
                    let trimmed = NSRange(location: titleStart + 1, length: max(0, title.length - 1))
                    set([.backgroundColor: hl], trimmed)
                }
                inlineRange = title
            }
        case .listItem:
            storage.setAttributes(base, range: para)
            let bullet = Self.match(Self.listMarker, in: line.text)
            if bullet.location != NSNotFound {
                set([.foregroundColor: p.accent], bullet)
                inlineRange = NSRange(location: bullet.length, length: text.length - bullet.length)
            }
        case .imageLine:
            // The picture is the content: the markdown shows only while the caret is on the line.
            base[.foregroundColor] = p.dimInk
            base[.font] = p.mono.withSize(11)
            storage.setAttributes(base, range: para)
            if !reveal { set(p.hiddenAttributes, NSRange(location: 0, length: text.length)) }
            return
        case .urlLine(let url):
            // Same for bare URLs: the card stands in for the address.
            base[.font] = p.mono.withSize(11)
            storage.setAttributes(base, range: para)
            if reveal {
                set([.foregroundColor: p.accent, .link: url], NSRange(location: 0, length: text.length))
            } else {
                set(p.hiddenAttributes, NSRange(location: 0, length: text.length))
            }
            return
        case .rule:
            base[.foregroundColor] = p.dimInk
            storage.setAttributes(base, range: para)
            return
        case .blank, .plain:
            storage.setAttributes(base, range: para)
        }

        // Inline spans.
        let sub = text.substring(with: inlineRange)
        let tokens = InlineTokenizer.tokenize(sub)
        func sh(_ r: NSRange) -> NSRange { NSRange(location: inlineRange.location + r.location, length: r.length) }
        for t in tokens {
            switch t.kind {
            case .bold: set([.font: p.bold], sh(t.content))
            case .italic: set([.font: p.italic], sh(t.content))
            case .boldItalic: set([.font: NSFontManager.shared.convert(p.bold, toHaveTrait: .italicFontMask)], sh(t.content))
            case .code: set([.font: p.mono, .backgroundColor: p.codeBackground], sh(t.content))
            case .strikethrough: set([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: p.dimInk], sh(t.content))
            case .link(let url):
                set([.foregroundColor: p.accent, .link: url], sh(t.content))
            case .url(let url):
                set([.foregroundColor: p.accent, .link: url], sh(t.range))
            case .tag: set([.foregroundColor: p.accent, .backgroundColor: p.tagBackground], sh(t.range))
            }
            for s in t.syntax { set(syntaxAttrs, sh(s)) }
        }
    }
}

extension EditorPalette {
    func codeColor(for token: CodeHighlighter.Token) -> NSColor {
        switch token {
        case .keyword: return accent
        case .string: return isDark ? NSColor(srgbRed: 0.70, green: 0.82, blue: 0.55, alpha: 1) : NSColor(srgbRed: 0.30, green: 0.50, blue: 0.22, alpha: 1)
        case .comment: return dimInk
        case .number: return isDark ? NSColor(srgbRed: 0.75, green: 0.65, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.30, blue: 0.65, alpha: 1)
        case .type: return isDark ? NSColor(srgbRed: 0.55, green: 0.78, blue: 0.90, alpha: 1) : NSColor(srgbRed: 0.15, green: 0.42, blue: 0.62, alpha: 1)
        }
    }
}
