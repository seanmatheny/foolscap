import Foundation
import FoolscapStore

/// What the importer remembers between passes: which Kindle book became
/// which file, and which annotations were delivered. Lives in Application
/// Support, not the synced notes folder: it is per-machine bookkeeping.
public struct HighlightsState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Book: Codable, Equatable, Sendable {
        /// Relative path of the book's markdown file.
        public var path: String
        public var title: String
        public var author: String
        public var coverDone: Bool
        public init(path: String, title: String, author: String, coverDone: Bool) {
            self.path = path; self.title = title; self.author = author; self.coverDone = coverDone
        }
    }

    public struct Annotation: Codable, Equatable, Sendable {
        public var contentKey: String
        public var modified: Date?
        /// The Kindle range held no text; retried only when the annotation changes.
        public var empty: Bool
        public init(contentKey: String, modified: Date?, empty: Bool) {
            self.contentKey = contentKey; self.modified = modified; self.empty = empty
        }
    }

    public var version = HighlightsState.currentVersion
    /// Kindle book id → file.
    public var books: [String: Book] = [:]
    /// "<book id>/<annotation id>" → what was written.
    public var annotations: [String: Annotation] = [:]
    public var lastRun: Date?

    public init() {}

    public static func key(book: String, annotation: String) -> String { book + "/" + annotation }

    public static func load(from url: URL) -> HighlightsState {
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(HighlightsState.self, from: data),
              state.version == currentVersion else { return HighlightsState() }
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Which highlights were shown on which day, so the daily three stay put for
/// the day and recent ones are not picked again soon.
public struct DailyPickHistory: Codable, Equatable, Sendable {
    /// "yyyy-MM-dd" → content keys shown that day.
    public var days: [String: [String]] = [:]
    public static let keptDays = 60

    public init() {}

    public static func load(from url: URL) -> DailyPickHistory {
        guard let data = try? Data(contentsOf: url), let h = try? JSONDecoder().decode(DailyPickHistory.self, from: data) else { return DailyPickHistory() }
        return h
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    /// Drop days older than the kept window (day strings sort chronologically).
    public mutating func prune(keeping recent: Int = keptDays) {
        let keys = days.keys.sorted()
        if keys.count > recent { for k in keys.prefix(keys.count - recent) { days[k] = nil } }
    }
}

public enum HighlightsPaths {
    public static var supportDirectory: URL { AppSupport.directory.appendingPathComponent("Highlights", isDirectory: true) }
    public static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    public static var dailyURL: URL { supportDirectory.appendingPathComponent("daily.json") }
    /// Decoded KFX text is large and regenerable: it lives in Caches, outside backups.
    public static var kfxCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Foolscap/KFX", isDirectory: true)
    }
}
