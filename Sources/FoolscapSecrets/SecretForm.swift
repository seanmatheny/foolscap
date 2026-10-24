import Foundation

/// An entry as the editing form holds it: a title, tags, labelled fields (each shown or
/// hidden), long secrets and notes. It is read from a `SecretEntry` and written back as
/// the vault's markdown (`markdown`), so the file format does not change; the form only
/// keeps the backticks, fences and `#` out of sight.
public struct SecretForm: Equatable, Sendable {
    public struct Field: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var label: String
        public var value: String
        public var isSecret: Bool
        public init(id: UUID = UUID(), label: String, value: String = "", isSecret: Bool) {
            self.id = id; self.label = label; self.value = value; self.isSecret = isSecret
        }
    }

    /// A multi-line secret (a key, recovery codes): a fenced block in the file.
    public struct Block: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var info: String
        public var body: String
        public init(id: UUID = UUID(), info: String = "", body: String = "") {
            self.id = id; self.info = info; self.body = body
        }
    }

    public var title: String
    public var tags: [String]
    public var fields: [Field]
    public var blocks: [Block]
    /// The notes, one per line.
    public var notes: String

    public init(title: String = "", tags: [String] = [], fields: [Field] = [], blocks: [Block] = [], notes: String = "") {
        self.title = title; self.tags = tags; self.fields = fields; self.blocks = blocks; self.notes = notes
    }

    /// What a new entry starts as: user, password (hidden) and site, all empty.
    public static func blank() -> SecretForm {
        SecretForm(fields: [Field(label: "user", isSecret: false), Field(label: "password", isSecret: true), Field(label: "site", isSecret: false)])
    }

    public init(entry: SecretEntry) {
        self.init(
            title: entry.title,
            tags: entry.tags,
            fields: entry.fields.map { Field(label: $0.label, value: $0.value, isSecret: $0.isSecret) },
            blocks: entry.blocks.map { Block(info: $0.info ?? "", body: $0.body) },
            notes: entry.notes.joined(separator: "\n"))
    }

    /// A new field's value is hidden when its label names a secret.
    public static func labelSuggestsSecret(_ label: String) -> Bool {
        let l = label.lowercased()
        return ["password", "passcode", "pin", "secret", "token", "key", "code", "combination", "pass"].contains { l.contains($0) }
            && !["key id", "user", "keyboard"].contains { l.contains($0) }
    }

    public var hasTitle: Bool { !Self.oneLine(title).isEmpty }

    /// The same entry whatever the ids, the field order kept.
    public func sameContent(as other: SecretForm) -> Bool {
        func key(_ f: SecretForm) -> [String] {
            [f.title, f.tags.joined(separator: " "), f.notes]
                + f.fields.map { "\($0.label)\u{1}\($0.value)\u{1}\($0.isSecret)" }
                + f.blocks.map { "\($0.info)\u{1}\($0.body)" }
        }
        return key(self) == key(other)
    }

    /// Typed or pasted tag text as tags: `#` dropped, split on spaces and commas,
    /// only the characters a tag may hold.
    public static func tags(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).compactMap { word in
            let cleaned = String(word.drop(while: { $0 == "#" }).filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    /// The entry in the vault's format. Fields with nothing in them are left out unless
    /// `keepingEmpty` (switching to the text view keeps them as places to type).
    public func markdown(keepingEmpty: Bool = false) -> String {
        var seen = Set<String>()
        let tagWords = tags.flatMap(Self.tags(from:)).filter { seen.insert($0).inserted }.map { "#" + $0 }
        var lines = ["## " + ([Self.oneLine(title)].filter { !$0.isEmpty } + tagWords).joined(separator: " ")]
        for field in fields {
            let value = field.isSecret ? Self.oneLine(field.value, trimming: false) : Self.oneLine(field.value)
            guard keepingEmpty || !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let label = Self.cleanLabel(field.label)
            if field.isSecret {
                lines.append("- \(label): `\(value)`")
            } else {
                lines.append(value.isEmpty ? "- \(label):" : "- \(label): \(value)")
            }
        }
        for block in blocks {
            let body = block.body.replacing(/\r\n?/, with: "\n").replacing(/\n+$/, with: "")
            guard keepingEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append("```" + Self.oneLine(block.info).filter { $0 != "`" })
            if !body.isEmpty { lines.append(body) }
            lines.append("```")
        }
        for note in notes.replacing(/\r\n?/, with: "\n").split(separator: "\n") {
            let line = note.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(SecretEntry.escapedNote(line)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A label the parser reads back whole: no backticks, no ": " inside, no colon at the end.
    static func cleanLabel(_ label: String) -> String {
        let cleaned = oneLine(label).replacingOccurrences(of: "`", with: "").replacingOccurrences(of: ": ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespaces))
        return cleaned.isEmpty ? "field" : cleaned
    }

    /// Line breaks (a multi-line paste into a one-line field) become spaces.
    static func oneLine(_ text: String, trimming: Bool = true) -> String {
        let joined = text.replacing(/[\r\n]+/, with: " ")
        return trimming ? joined.trimmingCharacters(in: .whitespaces) : joined
    }
}
