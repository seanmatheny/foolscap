import Foundation
import FoolscapCore

/// The Reference tab's covers: one sidecar, `Reference/.foolscap-covers.json`, never
/// anything in a note. Keys are paths relative to `Reference/` ("Recipes.md"); each
/// entry's fields are optional (a missing one is the look the title derives):
///
///     {"covers":{"Recipes.md":{"cloth":"teal","pattern":"dots","symbol":"fork.knife"}},"format":1}
///
/// Both devices write it, a cover at a time, so every change is read from disk, applied
/// and written back, and keys this build does not know (in an entry or at the top) are
/// kept as they were. Dot-prefixed but a `.foolscap-` file, so backups carry it.
public enum ReferenceCovers {
    public static let fileName = ".foolscap-covers.json"
    public static let format = 1

    public static func url(in folder: NotesFolder) -> URL { folder.referenceDirectory.appendingPathComponent(fileName) }

    /// The file's JSON object (an empty one when it is missing or does not parse).
    public typealias Document = [String: JSONValue]

    public static func decode(_ data: Data) -> Document {
        (try? JSONDecoder().decode(Document.self, from: data)) ?? [:]
    }

    public static func encode(_ document: Document) throws -> Data {
        var doc = document
        doc["format"] = .number(Double(format))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(doc)
    }

    private static func covers(_ document: Document) -> [String: JSONValue] { document["covers"]?.object ?? [:] }

    /// Every entry's choice, by key. An unknown cloth or pattern name reads as derived.
    public static func choices(in document: Document) -> [String: CoverChoice] {
        var out: [String: CoverChoice] = [:]
        for (key, value) in covers(document) {
            guard let entry = value.object else { continue }
            out[key] = CoverChoice(symbol: entry["symbol"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                   cloth: entry["cloth"]?.string.flatMap(CoverCloth.init(rawValue:)),
                                   pattern: entry["pattern"]?.string.flatMap(CoverPattern.init(rawValue:)))
        }
        return out
    }

    /// Whether the file holds an entry for `key`, whatever is in it.
    public static func hasEntry(_ key: String, in document: Document) -> Bool { covers(document)[key] != nil }

    /// `document` with `key`'s choice set (an empty choice removes the three known
    /// fields, and the entry once nothing else is left in it).
    public static func setting(_ choice: CoverChoice, for key: String, in document: Document) -> Document {
        var doc = document
        var all = covers(document)
        var entry = all[key]?.object ?? [:]
        entry["symbol"] = choice.symbol.map(JSONValue.string)
        entry["cloth"] = choice.cloth.map { .string($0.rawValue) }
        entry["pattern"] = choice.pattern.map { .string($0.rawValue) }
        all[key] = entry.isEmpty ? nil : .object(entry)
        doc["covers"] = .object(all)
        return doc
    }

    /// `document` with `old`'s entry under `new` (whatever it holds); unchanged when `old` has none.
    public static func moving(_ old: String, to new: String, in document: Document) -> Document {
        var all = covers(document)
        guard let entry = all.removeValue(forKey: old) else { return document }
        all[new] = entry
        var doc = document
        doc["covers"] = .object(all)
        return doc
    }

    public static func removing(_ key: String, in document: Document) -> Document {
        var all = covers(document)
        guard all.removeValue(forKey: key) != nil else { return document }
        var doc = document
        doc["covers"] = .object(all)
        return doc
    }

    /// The sidecar as it is on disk (starting an iCloud download it still needs).
    /// Coordinated IO: call off the main actor.
    public static func read(_ folder: NotesFolder, presenter: NSFilePresenter? = nil) -> Document {
        let file = url(in: folder)
        if ICloudPlaceholders.needsDownload(file) { ICloudPlaceholders.startDownload(file) }
        guard FileManager.default.fileExists(atPath: file.path), let data = try? FileIO.read(file, presenter: presenter) else { return [:] }
        return decode(data)
    }

    /// Read, change and write back in one go, skipping the write when nothing changed.
    /// Returns the document as written. Coordinated IO: call off the main actor.
    @discardableResult
    public static func update(_ folder: NotesFolder, presenter: NSFilePresenter? = nil,
                              _ change: (Document) -> Document) throws -> Document {
        let file = url(in: folder)
        let existing = FileManager.default.fileExists(atPath: file.path) ? try? FileIO.read(file, presenter: presenter) : nil
        let before = existing.map(decode) ?? [:]
        let after = change(before)
        let data = try encode(after)
        if let existing, existing == data { return after }
        // No file and nothing to say: none is written.
        if existing == nil, covers(after).isEmpty { return after }
        try FileIO.write(data, to: file, presenter: presenter)
        return after
    }
}

/// Any JSON value, so a file's keys this build does not know survive a rewrite.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
