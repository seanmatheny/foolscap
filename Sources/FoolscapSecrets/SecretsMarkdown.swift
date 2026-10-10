import Foundation
import CryptoKit

/// Where an entry is filed: its title's first letter, or `#` for anything else.
public enum SecretLetter: Hashable, Comparable, Sendable, CustomStringConvertible {
    case letter(Character)
    case other

    public static let letters: [SecretLetter] = (0..<26).map { .letter(Character(UnicodeScalar(65 + $0)!)) }
    public static let all: [SecretLetter] = letters + [.other]

    public var description: String {
        switch self {
        case .letter(let c): return String(c)
        case .other: return "#"
        }
    }

    /// 0…25 for A…Z, 26 for `#`.
    public var ordinal: Int {
        switch self {
        case .letter(let c): return Int(c.asciiValue ?? 65) - 65
        case .other: return 26
        }
    }

    public static func < (a: SecretLetter, b: SecretLetter) -> Bool { a.ordinal < b.ordinal }

    /// Accents folded, case ignored: "école" files under E, "7-Zip" and "" under `#`.
    public static func filing(for title: String) -> SecretLetter {
        let folded = title.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        guard let first = folded.first, let ascii = first.asciiValue, ascii >= 65, ascii <= 90 else { return .other }
        return .letter(Character(UnicodeScalar(ascii)))
    }
}

/// A `- label: value` line. A value wrapped in backticks is a secret.
public struct SecretField: Hashable, Sendable {
    public var label: String
    public var value: String
    public var isSecret: Bool
    public var isURL: Bool

    public init(label: String, value: String, isSecret: Bool, isURL: Bool) {
        self.label = label; self.value = value; self.isSecret = isSecret; self.isURL = isURL
    }
}

/// A fenced block: a multi-line secret (a key, recovery codes), always masked.
public struct SecretBlock: Hashable, Sendable {
    public var info: String?
    public var body: String
    public var lineCount: Int { body.isEmpty ? 0 : body.split(separator: "\n", omittingEmptySubsequences: false).count }
}

/// One `## Title` section of the vault's markdown, parsed for display. `raw` is
/// the exact source; the parsed fields are derived from it and never written back.
public struct SecretEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public var raw: String
    public var title: String
    public var tags: [String]
    public var fields: [SecretField]
    public var blocks: [SecretBlock]
    public var notes: [String]
    public var changed: Date?
    public var letter: SecretLetter { SecretLetter.filing(for: title) }

    /// The collapsed row's muted line: the first two visible values, else the first note.
    public var summary: String {
        let values = fields.filter { !$0.isSecret }.prefix(2).map(\.value)
        let text = values.isEmpty ? (notes.first ?? "") : values.joined(separator: " · ")
        return text.count > 72 ? String(text.prefix(70)) + "…" : text
    }

    /// Everything a search may look at: the secrets themselves are never searched.
    var searchable: String {
        ([title] + tags + fields.flatMap { $0.isSecret ? [$0.label] : [$0.label, $0.value] } + notes).joined(separator: "\n")
    }

    // Regex literals are not Sendable; built on use, they are cheap.
    static var tagPattern: Regex<(Substring, Substring)> { /#([\p{L}\p{N}_-]+)/ }
    static var listPattern: Regex<(Substring, Substring)> { /^\s*[-*]\s+(.*)$/ }
    static var urlPattern: Regex<(Substring, Substring)> { /^(https?:\/\/\S+|www\.\S+)$/ }

    init(raw: String, ordinal: Int) {
        self.raw = raw
        let digest = SHA256.hash(data: Data(raw.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        id = "\(digest)-\(ordinal)"
        var title = "", tags: [String] = [], fields: [SecretField] = [], blocks: [SecretBlock] = [], notes: [String] = []
        var changed: Date?
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        if let first = lines.first, first.hasPrefix("##") {
            let heading = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            for m in heading.matches(of: Self.tagPattern) { tags.append(String(m.1)) }
            title = heading.replacing(Self.tagPattern, with: "").trimmingCharacters(in: .whitespaces)
            i = 1
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(lines[i]); i += 1 }
                blocks.append(SecretBlock(info: info.isEmpty ? nil : info, body: body.joined(separator: "\n")))
                i += 1
                continue
            }
            i += 1
            if trimmed.isEmpty { continue }
            if let m = line.firstMatch(of: Self.listPattern) {
                let content = String(m.1).trimmingCharacters(in: .whitespaces)
                let lineTags = content.matches(of: Self.tagPattern).map { String($0.1) }
                let withoutTags = content.replacing(Self.tagPattern, with: "").trimmingCharacters(in: .whitespaces)
                if withoutTags.isEmpty, !lineTags.isEmpty { tags += lineTags; continue }
                if let colon = content.range(of: ": "), !content[..<colon.lowerBound].contains("`") {
                    let label = String(content[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                    var value = String(content[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if label.lowercased() == "changed", let date = Self.dateFormatter.date(from: value) { changed = date; continue }
                    let isSecret = value.count >= 2 && value.hasPrefix("`") && value.hasSuffix("`")
                    if isSecret { value = String(value.dropFirst().dropLast()) }
                    let isURL = !isSecret && value.firstMatch(of: Self.urlPattern) != nil
                    if !isSecret { tags += lineTags }
                    fields.append(SecretField(label: label, value: value, isSecret: isSecret, isURL: isURL))
                    continue
                }
                notes.append(withoutTags.isEmpty ? content : withoutTags)
                tags += lineTags
                continue
            }
            notes.append(trimmed)
        }
        self.title = title; self.tags = tags; self.fields = fields; self.blocks = blocks; self.notes = notes; self.changed = changed
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// The vault's plaintext: a preamble (anything before the first `## `) and the
/// entries in file order. Serialising gives the source back byte for byte.
public struct SecretsDocument: Equatable, Sendable {
    public var preamble: String
    public var entries: [SecretEntry]

    public init(preamble: String = "", entries: [SecretEntry] = []) { self.preamble = preamble; self.entries = entries }

    /// What a new entry starts as.
    public static let template = "## \n- user: \n- password: ``\n- site: \n"

    public static func parse(_ text: String) -> SecretsDocument {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var preamble = ""
        var chunks: [String] = []
        var current: String?
        var inFence = false
        for (i, line) in lines.enumerated() {
            // `split` leaves a trailing "" when the text ends with a newline; every
            // line but the last gets its newline back, so the pieces rejoin exactly.
            let piece = i < lines.count - 1 ? line + "\n" : line
            if !inFence, line.hasPrefix("## ") || line == "##" {
                if let c = current { chunks.append(c) }
                current = piece
            } else if current != nil {
                current! += piece
            } else {
                preamble += piece
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
        }
        if let c = current { chunks.append(c) }
        return SecretsDocument(preamble: preamble, entries: chunks.enumerated().map { SecretEntry(raw: $1, ordinal: $0) })
    }

    public func serialized() -> String { preamble + entries.map(\.raw).joined() }

    public func entries(under letter: SecretLetter) -> [SecretEntry] {
        entries.filter { $0.letter == letter }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public var lettersWithEntries: Set<SecretLetter> { Set(entries.map(\.letter)) }

    /// Tags across the vault, most used first.
    public var tags: [String] {
        var counts: [String: Int] = [:]
        for e in entries { for t in e.tags { counts[t, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// Entries whose title, tags, labels, visible values or notes contain the query
    /// (case and accents ignored). Secret values and blocks are never searched.
    public func matching(_ query: String) -> [SecretEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.searchable.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: Mutations (all splices of raw text; the parsed fields follow)

    /// An entry's text as the file should hold it: a `## ` heading first, one trailing newline.
    public static func normalised(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        guard !lines.isEmpty else { return "" }
        if !lines[0].hasPrefix("## ") {
            lines[0] = "## " + lines[0].drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Add an entry, keeping the file in letter order (after the letter's last entry).
    /// Returns the new entry's id, or nil when the text has no title.
    @discardableResult
    public mutating func insert(_ text: String) -> String? {
        let normalised = Self.normalised(text)
        let entry = SecretEntry(raw: normalised, ordinal: 0)
        guard !normalised.isEmpty, !entry.title.isEmpty else { return nil }
        let index = entries.lastIndex { $0.letter <= entry.letter }.map { $0 + 1 } ?? 0
        entries.insert(entry, at: index)
        tidy()
        return entries[index].id
    }

    /// Replace an entry with the edited text; a text holding several `## ` splits
    /// into several entries, an empty one removes it. Returns the ids that took its place.
    @discardableResult
    public mutating func replace(id: String, with text: String) -> [String] {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return [] }
        let pieces = Self.parse(Self.normalised(text)).entries.filter { !$0.title.isEmpty }
        entries.replaceSubrange(index...index, with: pieces)
        tidy()
        return entries[index..<(index + pieces.count)].map(\.id)
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
        tidy()
    }

    /// Set the entry's `- changed: yyyy-MM-dd` line (added after its last list line).
    public mutating func stamp(id: String, changed date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let stamp = "- changed: " + SecretEntry.dateFormatter.string(from: date)
        var lines = entries[index].raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trailing = lines.last == "" ? lines.removeLast() : nil
        if let existing = lines.firstIndex(where: { $0.firstMatch(of: /^\s*[-*]\s+changed:\s/.ignoresCase()) != nil }) {
            lines[existing] = stamp
        } else {
            var insertAt = 1
            var inFence = false
            for (i, line) in lines.enumerated() where i > 0 {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
                if !inFence, line.firstMatch(of: SecretEntry.listPattern) != nil { insertAt = i + 1 }
            }
            lines.insert(stamp, at: min(insertAt, lines.count))
        }
        if trailing != nil { lines.append("") }
        entries[index] = SecretEntry(raw: lines.joined(separator: "\n"), ordinal: index)
        tidy()
    }

    /// After a change every entry ends with a newline (so the next heading starts a
    /// line) and the ids carry their new ordinals. An untouched document is left alone,
    /// so it still serialises byte for byte.
    private mutating func tidy() {
        if !entries.isEmpty, !preamble.isEmpty, !preamble.hasSuffix("\n") { preamble += "\n" }
        entries = entries.enumerated().map { i, e in
            SecretEntry(raw: e.raw.hasSuffix("\n") ? e.raw : e.raw + "\n", ordinal: i)
        }
    }
}
