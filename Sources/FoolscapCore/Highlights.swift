import Foundation
import CryptoKit

/// The editable part of a highlight: the trailing "— pos …" line of its block.
/// Position and date come from the Kindle; tags, ♥ and hidden are the user's.
public struct HighlightMeta: Hashable, Sendable {
    /// The Kindle's start position (a byte offset for MOBI, a pid for KFX):
    /// keeps a book's highlights in reading order.
    public var position: Int
    public var added: Date?
    public var tags: [String]
    /// ♥: shown more often among the day's highlights.
    public var isFavourite: Bool
    /// Never shown among the day's highlights.
    public var isHidden: Bool

    public init(position: Int, added: Date? = nil, tags: [String] = [], isFavourite: Bool = false, isHidden: Bool = false) {
        self.position = position; self.added = added; self.tags = tags
        self.isFavourite = isFavourite; self.isHidden = isHidden
    }
}

/// One highlight as the index sees it. Identity is `path#line` plus a hash of
/// the quote text, like a task: editing tags, ♥ or hidden keeps the identity.
public struct HighlightItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var path: String
    /// Line of the block's first `>` line.
    public var line: Int
    /// Line of the block's "— pos …" line.
    public var metaLine: Int
    public var bookTitle: String
    public var bookAuthor: String
    public var paragraphs: [String]
    /// A typed Kindle note attached to the highlight.
    public var note: String?
    public var meta: HighlightMeta
    public var contentKey: String

    public init(path: String, line: Int, metaLine: Int, bookTitle: String, bookAuthor: String,
                paragraphs: [String], note: String?, meta: HighlightMeta) {
        self.id = HighlightItem.id(path: path, line: line)
        self.path = path; self.line = line; self.metaLine = metaLine
        self.bookTitle = bookTitle; self.bookAuthor = bookAuthor
        self.paragraphs = paragraphs; self.note = note; self.meta = meta
        self.contentKey = HighlightItem.contentKey(for: paragraphs)
    }

    public var text: String { paragraphs.joined(separator: "\n\n") }
    public var tags: [String] { meta.tags }
    public var isFavourite: Bool { meta.isFavourite }
    public var isHidden: Bool { meta.isHidden }

    public static func id(path: String, line: Int) -> String { "\(path)#L\(line)" }

    /// A hash of the quote text alone, whitespace-collapsed and case-folded.
    public static func contentKey(for paragraphs: [String]) -> String {
        let normalised = paragraphs.joined(separator: " ").lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalised.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads a book file back: the header, then every blockquote that ends with a
/// meta line. Blocks without one are left alone (and reported without an item).
public enum HighlightParser {
    public struct Block: Equatable, Sendable {
        public var firstLine: Int
        public var lastLine: Int
        public var item: HighlightItem?
    }

    public struct Parsed: Equatable, Sendable {
        public var title: String
        public var author: String
        public var items: [HighlightItem]
        public var blocks: [Block]
        /// Index of the first block's first line, or the line count when there is none.
        public var firstBlockLine: Int
    }

    public static func parse(_ text: String, path: String) -> Parsed {
        let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var title = "", author = ""
        var foundTitle = false, foundAuthor = false
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix(">") {
                var end = i
                while end + 1 < lines.count, lines[end + 1].hasPrefix(">") { end += 1 }
                let block = parseBlock(lines[i...end], firstLine: i, path: path, title: title, author: author)
                blocks.append(block)
                i = end + 1
                continue
            }
            if blocks.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !foundTitle, trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
                    title = MarkdownEscaping.unescape(String(trimmed[space...]).trimmingCharacters(in: .whitespaces))
                    foundTitle = true
                } else if foundTitle, !foundAuthor, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                    author = MarkdownEscaping.unescape(trimmed)
                    foundAuthor = true
                }
            }
            i += 1
        }
        let items = blocks.compactMap(\.item).map { item -> HighlightItem in
            // Blocks parsed before the author line was seen (never in a well-formed file) get the final header.
            var fixed = item; fixed.bookTitle = title; fixed.bookAuthor = author; return fixed
        }
        return Parsed(title: title, author: author, items: items, blocks: blocks, firstBlockLine: blocks.first?.firstLine ?? lines.count)
    }

    private static func parseBlock(_ lines: ArraySlice<String>, firstLine: Int, path: String, title: String, author: String) -> Block {
        let lastLine = firstLine + lines.count - 1
        let contents = lines.map(content)
        guard let metaOffset = contents.lastIndex(where: { isMetaLine($0) }),
              let meta = parseMeta(contents[metaOffset]) else {
            return Block(firstLine: firstLine, lastLine: lastLine, item: nil)
        }
        var paragraphs: [String] = [], notes: [String] = []
        for (offset, c) in contents.enumerated() where offset != metaOffset {
            let trimmed = c.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(HighlightMarkdown.noteMark) {
                notes.append(MarkdownEscaping.unescape(String(trimmed.dropFirst(HighlightMarkdown.noteMark.count)).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraphs.append(MarkdownEscaping.unescape(trimmed))
            }
        }
        let item = HighlightItem(path: path, line: firstLine, metaLine: firstLine + metaOffset, bookTitle: title, bookAuthor: author,
                                 paragraphs: paragraphs, note: notes.isEmpty ? nil : notes.joined(separator: "\n"), meta: meta)
        return Block(firstLine: firstLine, lastLine: lastLine, item: item)
    }

    /// A `>` line's content: the marker and one following space removed.
    static func content(of line: String) -> String {
        var s = Substring(line)
        if s.hasPrefix(">") { s = s.dropFirst() }
        if s.hasPrefix(" ") { s = s.dropFirst() }
        return String(s)
    }

    static func isMetaLine(_ content: String) -> Bool {
        let t = content.trimmingCharacters(in: .whitespaces)
        return t == HighlightMarkdown.metaMark || t.hasPrefix(HighlightMarkdown.metaMark + " ")
    }

    /// "— pos 1234 · 12 Mar 2026 · #tag ♥ hidden" → meta. Fields are separated
    /// by " · "; flags are tolerated inside any field.
    public static func parseMeta(_ content: String) -> HighlightMeta? {
        var t = content.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(HighlightMarkdown.metaMark) else { return nil }
        t = String(t.dropFirst(HighlightMarkdown.metaMark.count))
        var position: Int?
        var added: Date?
        var tags: [String] = []
        var favourite = false, hidden = false
        for field in t.components(separatedBy: HighlightMarkdown.fieldSeparator) {
            var rest: [String] = []
            for token in field.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                if token == HighlightMarkdown.favouriteMark { favourite = true }
                else if token == HighlightMarkdown.hiddenMark { hidden = true }
                else if token.hasPrefix("#") {
                    let tag = String(token.dropFirst()).lowercased()
                    if !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
                } else { rest.append(token) }
            }
            guard !rest.isEmpty else { continue }
            if rest[0] == "pos", rest.count >= 2, let n = Int(rest[1]) {
                position = n
                if rest.count > 2, let d = HighlightMarkdown.dateFormatter.date(from: rest[2...].joined(separator: " ")) { added = d }
            } else if let d = HighlightMarkdown.dateFormatter.date(from: rest.joined(separator: " ")) {
                added = d
            }
        }
        guard let position else { return nil }
        return HighlightMeta(position: position, added: added, tags: tags, isFavourite: favourite, isHidden: hidden)
    }
}

/// Writes book files and their blocks. Identical input gives identical output.
public enum HighlightMarkdown {
    public static let rootTag = "kindle"
    public static let noteMark = "*Note:*"
    public static let metaMark = "—"
    public static let favouriteMark = "♥"
    public static let hiddenMark = "hidden"
    static let fieldSeparator = " · "

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// Keep quote text literal where it matters: `#` never becomes a tag, a
    /// leading `—`, `*` or `>` never reads as a meta line, a note or a nested
    /// quote. Emphasis inside the quote is left alone so the file stays readable.
    public static func escape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "#", with: "\\#")
        if let first = out.first, first == "—" || first == "*" || first == ">" { out = "\\" + out }
        return out
    }

    public static func unescape(_ text: String) -> String { MarkdownEscaping.unescape(text) }

    public static func renderHeader(title: String, author: String) -> String {
        var out = "# \(MarkdownEscaping.escape(title))\n"
        if !author.isEmpty { out += MarkdownEscaping.escape(author) + "\n" }
        out += "#" + rootTag + "\n"
        return out
    }

    public static func renderMeta(_ meta: HighlightMeta) -> String {
        var fields = ["pos \(meta.position)"]
        if let added = meta.added { fields.append(dateFormatter.string(from: added)) }
        var flags = meta.tags.map { "#" + $0 }
        if meta.isFavourite { flags.append(favouriteMark) }
        if meta.isHidden { flags.append(hiddenMark) }
        if !flags.isEmpty { fields.append(flags.joined(separator: " ")) }
        return "> " + metaMark + " " + fields.joined(separator: fieldSeparator)
    }

    /// One blockquote, lines joined with "\n", no trailing newline.
    public static func renderBlock(paragraphs: [String], note: String?, meta: HighlightMeta) -> String {
        var lines = paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { "> " + escape($0) }
        if lines.isEmpty { lines = ["> "] }
        for n in (note ?? "").split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !n.isEmpty {
            lines.append("> " + noteMark + " " + escape(n))
        }
        lines.append(renderMeta(meta))
        return lines.joined(separator: "\n")
    }

    /// A highlight the importer wants in the file. With `replacingKey`, the
    /// block holding that content key is rewritten (its tags, ♥ and hidden kept).
    public struct NewBlock: Sendable {
        public var paragraphs: [String]
        public var note: String?
        public var meta: HighlightMeta
        public var replacingKey: String?
        public init(paragraphs: [String], note: String? = nil, meta: HighlightMeta, replacingKey: String? = nil) {
            self.paragraphs = paragraphs; self.note = note; self.meta = meta; self.replacingKey = replacingKey
        }
    }

    /// Splice new blocks into a book file: replacements in place, the rest in
    /// position order (before the first block with a larger position, else at
    /// the end). Everything already in the file is kept, including lines the
    /// parser does not understand.
    public static func inserting(_ blocks: [NewBlock], into text: String, path: String) -> String {
        guard !blocks.isEmpty else { return text }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }   // the trailing newline
        let parsed = HighlightParser.parse(lines.joined(separator: "\n"), path: path)
        struct Segment { var lines: [String]; var position: Int? }
        // Header, then one segment per block (the block plus whatever follows it up to the next block).
        var header = Array(lines[0..<min(parsed.firstBlockLine, lines.count)])
        var segments: [Segment] = []
        for (n, block) in parsed.blocks.enumerated() {
            let end = n + 1 < parsed.blocks.count ? parsed.blocks[n + 1].firstLine - 1 : lines.count - 1
            segments.append(Segment(lines: Array(lines[block.firstLine...max(block.firstLine, end)]), position: block.item?.meta.position))
        }
        var pending: [NewBlock] = []
        for new in blocks {
            if let key = new.replacingKey, let n = parsed.blocks.firstIndex(where: { $0.item?.contentKey == key }), let old = parsed.blocks[n].item {
                var meta = new.meta
                meta.tags = old.meta.tags; meta.isFavourite = old.meta.isFavourite; meta.isHidden = old.meta.isHidden
                if meta.added == nil { meta.added = old.meta.added }
                let blockLength = parsed.blocks[n].lastLine - parsed.blocks[n].firstLine + 1
                let tail = Array(segments[n].lines.dropFirst(blockLength))
                segments[n] = Segment(lines: renderBlock(paragraphs: new.paragraphs, note: new.note ?? old.note, meta: meta).components(separatedBy: "\n") + tail,
                                      position: meta.position)
            } else {
                pending.append(new)
            }
        }
        for new in pending.sorted(by: { $0.meta.position < $1.meta.position }) {
            let rendered = renderBlock(paragraphs: new.paragraphs, note: new.note, meta: new.meta).components(separatedBy: "\n")
            if let n = segments.firstIndex(where: { ($0.position ?? Int.max) > new.meta.position }) {
                segments.insert(Segment(lines: rendered + [""], position: new.meta.position), at: n)
            } else {
                if let last = segments.indices.last {
                    if segments[last].lines.last != "" { segments[last].lines.append("") }
                } else if header.last != "" {
                    header.append("")
                }
                segments.append(Segment(lines: rendered + [""], position: new.meta.position))
            }
        }
        var out = header + segments.flatMap(\.lines)
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }
}
