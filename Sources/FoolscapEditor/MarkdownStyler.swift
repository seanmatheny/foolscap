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
        style(range: NSRange(location: 0, length: storage.length), map: blockMap)
    }

    // MARK: NSTextStorageDelegate

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        MainActor.assumeIsolated {
            guard editedMask.contains(.editedCharacters), !isRestyling, let textStorage = storage else { return }
            let text = textStorage.string as NSString
            let newMap = BlockMap.scan(textStorage.string)
            let paragraphRange = text.paragraphRange(for: editedRange)
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

    private func style(range: NSRange, map: BlockMap) {
        guard let storage, range.length > 0 || storage.length == 0 else { return }
        isRestyling = true
        storage.beginEditing()
        var language = ""
        var inBlockComment = false
        // Find the language of an enclosing fence for the first styled line.
        if let first = map.line(at: range.location) {
            for l in map.lines[0..<first.index].reversed() {
                if case .fenceOpen(let lang) = l.kind { language = lang; break }
                if case .fenceClose = l.kind { break }
            }
        }
        for line in map.lines where NSIntersectionRange(line.range, range).length > 0 || (line.range.length == 0 && NSLocationInRange(line.range.location, range)) || line.range.location == range.location {
            if line.range.location >= range.location + range.length && range.length > 0 { break }
            styleLine(line, in: storage, language: &language, inBlockComment: &inBlockComment)
        }
        storage.endEditing()
        isRestyling = false
    }

    private func styleLine(_ line: ScannedLine, in storage: NSTextStorage, language: inout String, inBlockComment: inout Bool) {
        // Include the newline so paragraph attributes cover the whole paragraph.
        let paraLength = min(storage.length - line.range.location, line.range.length + 1)
        let para = NSRange(location: line.range.location, length: max(0, paraLength))
        let p = palette
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = p.pitch
        ps.maximumLineHeight = p.pitch
        ps.paragraphSpacing = overlayHeights[line.index] ?? 0
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

        var inlineRange = NSRange(location: 0, length: text.length)
        switch line.kind {
        case .heading(let level):
            base[.font] = p.headings[min(level, p.headings.count) - 1]
            storage.setAttributes(base, range: para)
            let hashes = text.range(of: "^#{1,6}\\s", options: .regularExpression)
            if hashes.location != NSNotFound { set([.foregroundColor: p.dimInk], hashes) }
        case .fenceOpen(let lang):
            language = lang; inBlockComment = false
            base[.font] = p.mono; base[.foregroundColor] = p.dimInk
            storage.setAttributes(base, range: para)
            return
        case .fenceClose:
            base[.font] = p.mono; base[.foregroundColor] = p.dimInk
            storage.setAttributes(base, range: para)
            return
        case .fenceInside:
            base[.font] = p.mono
            storage.setAttributes(base, range: para)
            for (token, r) in CodeHighlighter.tokens(in: line.text, language: language, inBlockComment: &inBlockComment) {
                set([.foregroundColor: p.codeColor(for: token)], r)
            }
            return
        case .quote:
            base[.font] = p.italic; base[.foregroundColor] = p.ink.withAlphaComponent(0.75)
            storage.setAttributes(base, range: para)
            let marker = text.range(of: "^>\\s?", options: .regularExpression)
            if marker.location != NSNotFound { set([.foregroundColor: p.dimInk, .font: p.body], marker) }
            inlineRange = NSRange(location: marker.length, length: text.length - marker.length)
        case .task(let status):
            storage.setAttributes(base, range: para)
            if let parsed = TaskLineParser.parse(line.text) {
                let prefix = NSRange(location: 0, length: parsed.markOffset + 2)
                set([.font: p.mono, .foregroundColor: status == .notStarted ? p.dimInk : p.accent], prefix)
                let titleStart = prefix.location + prefix.length
                let title = NSRange(location: titleStart, length: text.length - titleStart)
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
            let bullet = text.range(of: "^\\s*([-*+]|\\d+[.)])\\s", options: .regularExpression)
            if bullet.location != NSNotFound {
                set([.foregroundColor: p.accent], bullet)
                inlineRange = NSRange(location: bullet.length, length: text.length - bullet.length)
            }
        case .imageLine:
            base[.foregroundColor] = p.dimInk
            storage.setAttributes(base, range: para)
            return
        case .urlLine(let url):
            storage.setAttributes(base, range: para)
            set([.foregroundColor: p.accent, .link: url], NSRange(location: 0, length: text.length))
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
            for s in t.syntax { set([.foregroundColor: p.dimInk], sh(s)) }
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
