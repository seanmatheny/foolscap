import Foundation
import CryptoKit

public enum TaskStatus: String, Codable, CaseIterable, Sendable, Hashable {
    case notStarted, inProgress, completed

    /// The character inside the brackets in markdown: `[ ]`, `[/]`, `[x]`.
    public var mark: Character {
        switch self {
        case .notStarted: return " "
        case .inProgress: return "/"
        case .completed: return "x"
        }
    }

    public init?(mark: Character) {
        switch mark {
        case " ": self = .notStarted
        case "/": self = .inProgress
        case "x", "X": self = .completed
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .notStarted: return "Not Started"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        }
    }

    public var next: TaskStatus {
        switch self {
        case .notStarted: return .inProgress
        case .inProgress: return .completed
        case .completed: return .notStarted
        }
    }
}

/// Where a task lives. For note-backed tasks this is a file path and a 0-based line.
public struct TaskSource: Codable, Hashable, Sendable {
    public var path: String
    public var line: Int
    /// The day the note belongs to, when it is a daily note.
    public var day: String?

    public init(path: String, line: Int, day: String? = nil) {
        self.path = path; self.line = line; self.day = day
    }
}

public struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var providerID: String
    /// The task text as written, including tags, without the bullet and checkbox.
    public var title: String
    public var status: TaskStatus
    public var tags: [String]
    public var indent: Int
    public var source: TaskSource
    /// Stable identity across line moves: a hash of the normalised title.
    public var contentKey: String
    public var isReadOnly: Bool

    public init(providerID: String, title: String, status: TaskStatus, tags: [String], indent: Int,
                source: TaskSource, isReadOnly: Bool = false) {
        self.id = "\(providerID):\(source.path)#L\(source.line)"
        self.providerID = providerID
        self.title = title
        self.status = status
        self.tags = tags
        self.indent = indent
        self.source = source
        self.contentKey = TaskItem.contentKey(for: title)
        self.isReadOnly = isReadOnly
    }

    /// The first tag is the category.
    public var category: String? { tags.first }

    /// Title with tags removed, for display.
    public var displayTitle: String {
        TaskLineParser.stripTags(from: title)
    }

    public static func contentKey(for title: String) -> String {
        let normalised = title.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let digest = SHA256.hash(data: Data(normalised.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public enum TaskWriteError: Error, Sendable {
    /// The line no longer holds the expected task and no unique replacement was found.
    case moved
    case readOnly
}

/// Something that can contribute tasks to the Tasks tab.
public protocol TaskProvider: AnyObject, Sendable {
    var id: String { get }
    /// Emits whenever the provider's task list may have changed.
    var changes: AsyncStream<Void> { get }
    func tasks() async throws -> [TaskItem]
    func setStatus(_ status: TaskStatus, of task: TaskItem) async throws
}
