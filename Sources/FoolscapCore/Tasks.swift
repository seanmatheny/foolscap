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

/// Priority is written at the start of the task text as `!`, `!!` or `!!!`
/// (the Reminders convention), so it survives in plain markdown.
public enum TaskPriority: Int, Codable, CaseIterable, Sendable, Hashable, Comparable {
    case none = 0, low = 1, medium = 2, high = 3

    public var marker: String { String(repeating: "!", count: rawValue) }

    public init(marker: String) {
        self = TaskPriority(rawValue: min(3, marker.count)) ?? .none
    }

    public var title: String {
        switch self {
        case .none: return "No Priority"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    /// The indicator light: blue, amber and red; nil for no priority.
    public var color: RGBA? {
        switch self {
        case .none: return nil
        case .low: return .hex(0x4E8AC2)
        case .medium: return .hex(0xE0A030)
        case .high: return .hex(0xD2453A)
        }
    }

    public static func < (a: TaskPriority, b: TaskPriority) -> Bool { a.rawValue < b.rawValue }
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
    /// Free text kept on indented lines under the task in the note (may hold links).
    public var notes: String?

    public init(providerID: String, title: String, status: TaskStatus, tags: [String], indent: Int,
                source: TaskSource, isReadOnly: Bool = false, notes: String? = nil) {
        self.id = "\(providerID):\(source.path)#L\(source.line)"
        self.providerID = providerID
        self.title = title
        self.status = status
        self.tags = tags
        self.indent = indent
        self.source = source
        self.contentKey = TaskItem.contentKey(for: title)
        self.isReadOnly = isReadOnly
        self.notes = notes
    }

    nonisolated(unsafe) private static let linkPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>)\]]+"#)

    /// The first http(s) link in the notes, if any.
    public var firstLink: URL? {
        guard let notes else { return nil }
        guard let m = Self.linkPattern.firstMatch(in: notes, range: NSRange(location: 0, length: (notes as NSString).length)) else { return nil }
        return URL(string: (notes as NSString).substring(with: m.range))
    }

    /// The first tag is the category.
    public var category: String? { tags.first }

    /// The `!` marker at the start of the title, if any.
    public var priority: TaskPriority { TaskLineParser.priority(in: title) }

    /// Title with the priority marker and tags removed, for display.
    public var displayTitle: String {
        TaskLineParser.stripTags(from: TaskLineParser.stripPriority(from: title))
    }

    /// Priority is metadata like status: changing it keeps the task's identity.
    public static func contentKey(for title: String) -> String {
        let normalised = TaskLineParser.stripPriority(from: title).lowercased()
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
    /// Replace the task's text (including its #tags). Read-only providers throw.
    func setTitle(_ title: String, of task: TaskItem) async throws
    /// Replace the task's notes (nil or empty removes them).
    func setNotes(_ notes: String?, of task: TaskItem) async throws
}

public extension TaskProvider {
    func setTitle(_ title: String, of task: TaskItem) async throws { throw TaskWriteError.readOnly }
    func setNotes(_ notes: String?, of task: TaskItem) async throws { throw TaskWriteError.readOnly }
}
