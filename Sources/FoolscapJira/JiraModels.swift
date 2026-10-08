import Foundation

/// Jira's three status categories, which every workflow's statuses map onto.
public enum JiraStatusCategory: String, Codable, Sendable {
    case new, indeterminate, done, unknown
}

/// An issue as the page shows it and the state file keeps it.
public struct JiraIssue: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var summary: String
    public var statusName: String
    public var statusCategory: JiraStatusCategory
    public var issueType: String
    public var isEpic: Bool
    public var priority: String?
    public var parentKey: String?
    public var parentSummary: String?
    public var updated: Date?
    public var dueDate: String?
    public var commentCount: Int?

    public init(key: String, summary: String, statusName: String, statusCategory: JiraStatusCategory, issueType: String,
                isEpic: Bool = false, priority: String? = nil, parentKey: String? = nil, parentSummary: String? = nil,
                updated: Date? = nil, dueDate: String? = nil, commentCount: Int? = nil) {
        self.key = key; self.summary = summary; self.statusName = statusName; self.statusCategory = statusCategory
        self.issueType = issueType; self.isEpic = isEpic; self.priority = priority; self.parentKey = parentKey
        self.parentSummary = parentSummary; self.updated = updated; self.dueDate = dueDate; self.commentCount = commentCount
    }

    public var id: String { key }

    public func url(site: URL) -> URL { site.appendingPathComponent("browse/\(key)") }

    /// Highest … Lowest → 0 … 4; anything else after them.
    public var priorityRank: Int {
        switch priority?.lowercased() {
        case "highest", "blocker": return 0
        case "high", "critical", "major": return 1
        case "medium", "standard", "normal": return 2
        case "low", "minor": return 3
        case "lowest", "trivial": return 4
        default: return 5
        }
    }

    /// The task-list priority the issue's maps to; nil for none.
    public var taskPriorityLevel: Int {
        switch priorityRank {
        case 0, 1: return 3
        case 2: return 2
        case 3, 4: return 1
        default: return 0
        }
    }
}

/// A move the workflow allows from an issue's current status.
public struct JiraTransition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var toStatusName: String
    public var toCategory: JiraStatusCategory

    public init(id: String, name: String, toStatusName: String, toCategory: JiraStatusCategory) {
        self.id = id; self.name = name; self.toStatusName = toStatusName; self.toCategory = toCategory
    }
}

/// What a new task is made from: the title typed, and the defaults it lands with.
public struct JiraTaskDraft: Equatable, Sendable {
    public var summary: String
    public var projectKey: String
    public var issueTypeID: String
    public var epicKey: String?
    public var assigneeAccountID: String?
    public var sprintID: Int?

    public init(summary: String, projectKey: String, issueTypeID: String, epicKey: String? = nil,
                assigneeAccountID: String? = nil, sprintID: Int? = nil) {
        self.summary = summary; self.projectKey = projectKey; self.issueTypeID = issueTypeID
        self.epicKey = epicKey; self.assigneeAccountID = assigneeAccountID; self.sprintID = sprintID
    }
}

// MARK: - Wire shapes

/// The wire shape of `GET /rest/api/3/search/jql`. Everything that can be
/// null in Jira is optional here: priority, parent and due date often are.
struct JiraSearchPage: Decodable {
    var issues: [RawIssue]
    var nextPageToken: String?
    var isLast: Bool?

    struct RawIssue: Decodable {
        var key: String
        var fields: Fields
    }
    struct Fields: Decodable {
        var summary: String?
        var status: Status?
        var issuetype: IssueType?
        var priority: Named?
        var parent: Parent?
        var updated: String?
        var duedate: String?
        var comment: CommentField?
    }
    struct Status: Decodable {
        var name: String
        var statusCategory: Named?
    }
    struct Named: Decodable {
        var key: String?
        var name: String?
    }
    struct IssueType: Decodable {
        var name: String
        var hierarchyLevel: Int?
    }
    struct Parent: Decodable {
        var key: String
        var fields: ParentFields?
    }
    struct ParentFields: Decodable {
        var summary: String?
    }
    struct CommentField: Decodable {
        var total: Int?
    }
}

extension JiraIssue {
    init(_ raw: JiraSearchPage.RawIssue) {
        let type = raw.fields.issuetype
        self.init(key: raw.key,
                  summary: raw.fields.summary ?? "",
                  statusName: raw.fields.status?.name ?? "Unknown",
                  statusCategory: raw.fields.status?.statusCategory?.key.flatMap { JiraStatusCategory(rawValue: $0) } ?? .unknown,
                  issueType: type?.name ?? "Issue",
                  isEpic: type?.hierarchyLevel == 1 || type?.name == "Epic",
                  priority: raw.fields.priority?.name,
                  parentKey: raw.fields.parent?.key,
                  parentSummary: raw.fields.parent?.fields?.summary,
                  updated: raw.fields.updated.flatMap(JiraDates.parse),
                  dueDate: raw.fields.duedate,
                  commentCount: raw.fields.comment?.total)
    }
}

/// `GET /rest/api/3/issue/{key}/transitions`.
struct JiraTransitionsPage: Decodable {
    var transitions: [Raw]
    struct Raw: Decodable {
        var id: String
        var name: String
        var to: To?
    }
    struct To: Decodable {
        var name: String?
        var statusCategory: JiraSearchPage.Named?
    }
}

extension JiraTransition {
    init(_ raw: JiraTransitionsPage.Raw) {
        self.init(id: raw.id, name: raw.name, toStatusName: raw.to?.name ?? raw.name,
                  toCategory: raw.to?.statusCategory?.key.flatMap { JiraStatusCategory(rawValue: $0) } ?? .unknown)
    }
}

/// `POST /rest/api/3/issue` answers with the new key.
struct JiraCreatedIssue: Decodable {
    var key: String
}

/// `GET /rest/api/3/myself`.
struct JiraMyself: Decodable {
    var accountId: String
}

/// `GET /rest/api/3/issue/createmeta/{project}/issuetypes`.
struct JiraIssueTypesPage: Decodable {
    var issueTypes: [Entry]
    struct Entry: Decodable {
        var id: String
        var name: String
    }
}

/// `GET /rest/agile/1.0/board/{id}/sprint?state=active`.
struct JiraSprintPage: Decodable {
    var values: [Sprint]
    struct Sprint: Decodable {
        var id: Int
        var name: String
        var state: String?
    }
}

/// Jira's error body: `errorMessages` plus per-field `errors`.
struct JiraErrorBody: Decodable {
    var errorMessages: [String]?
    var errors: [String: String]?

    var message: String? {
        let parts = (errorMessages ?? []) + (errors ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Atlassian Document Format, the little of it a comment needs: one
/// paragraph per blank-line-separated block, line breaks kept inside them.
enum JiraADF {
    static func document(from text: String) -> [String: Any] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let paragraphs: [[String: Any]] = blocks.map { block in
            var content: [[String: Any]] = []
            for (i, line) in block.components(separatedBy: "\n").enumerated() {
                if i > 0 { content.append(["type": "hardBreak"]) }
                content.append(["type": "text", "text": line])
            }
            return ["type": "paragraph", "content": content]
        }
        return ["type": "doc", "version": 1, "content": paragraphs]
    }
}

/// Jira stamps "2026-10-07T12:34:56.000+1300": no colon in the offset, which
/// ISO8601DateFormatter refuses.
enum JiraDates {
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()

    static func parse(_ string: String) -> Date? {
        formatter.date(from: string)
    }
}
