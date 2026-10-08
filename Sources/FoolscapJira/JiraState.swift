import Foundation
import FoolscapStore

/// What the last sync found, and which issues were pulled into Today. Lives in
/// Application Support (and so in backups); it holds no secret.
public struct JiraState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = currentVersion
    /// The last fetch, so the page has something to show while offline.
    public var issues: [JiraIssue] = []
    public var lastSync: Date?
    /// Issue key → the task written for it.
    public var ledger: [String: Pulled] = [:]

    public struct Pulled: Codable, Equatable, Sendable {
        /// `TaskItem.contentKey` of the task line, its identity across moves.
        public var contentKey: String
        public var title: String
        public var pulledAt: Date
        /// Jira closed the issue and the task was ticked (or had gone already).
        public var resolvedAt: Date?

        public init(contentKey: String, title: String, pulledAt: Date, resolvedAt: Date? = nil) {
            self.contentKey = contentKey; self.title = title; self.pulledAt = pulledAt; self.resolvedAt = resolvedAt
        }
    }

    public init() {}

    public static func load(from url: URL) -> JiraState {
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(JiraState.self, from: data),
              state.version == currentVersion else { return JiraState() }
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

public enum JiraPaths {
    public static var supportDirectory: URL { AppSupport.directory.appendingPathComponent("Jira", isDirectory: true) }
    public static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
}
