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

    public init(key: String, summary: String, statusName: String, statusCategory: JiraStatusCategory, issueType: String,
                isEpic: Bool = false, priority: String? = nil, parentKey: String? = nil, parentSummary: String? = nil,
                updated: Date? = nil, dueDate: String? = nil) {
        self.key = key; self.summary = summary; self.statusName = statusName; self.statusCategory = statusCategory
        self.issueType = issueType; self.isEpic = isEpic; self.priority = priority; self.parentKey = parentKey
        self.parentSummary = parentSummary; self.updated = updated; self.dueDate = dueDate
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
                  dueDate: raw.fields.duedate)
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
