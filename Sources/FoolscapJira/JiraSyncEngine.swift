import Foundation
import FoolscapCore
import FoolscapStore

public struct JiraSyncReport: Equatable, Sendable {
    public var fetched = 0
    /// Pulled issues Jira has since closed, whose tasks were ticked.
    public var resolved = 0
    public init() {}
}

/// Where a pulled issue's task goes, and how it is ticked when Jira closes the issue.
public protocol JiraTaskSink: Sendable {
    /// `- [/] title` with a note line under it, unless a task with that content
    /// key is in Tasks.md already. Returns whether a line was written.
    func add(title: String, notes: String) async -> Bool
    /// Tick the open task for `key`: by content key, else by a title starting
    /// "KEY " (the user may have edited the rest). Returns whether a mark was written.
    func complete(key: String, contentKey: String) async -> Bool
}

public struct LibraryJiraTaskSink: JiraTaskSink {
    let library: NotebookLibrary
    public init(library: NotebookLibrary) { self.library = library }

    public func add(title: String, notes: String) async -> Bool {
        await library.addStandaloneTask(title, status: .today, notes: notes, skipIfPresent: true)
    }

    public func complete(key: String, contentKey: String) async -> Bool {
        await library.save()
        let index = await library.index
        let tasks = await Task.detached(priority: .utility) { (try? index.tasks()) ?? [] }.value
        guard let task = tasks.first(where: { $0.status.isOpen && ($0.contentKey == contentKey || $0.title.hasPrefix(key + " ")) })
        else { return false }
        let doc = await library.loadedDocument(atRelativePath: task.source.path)
        let ticked = await MainActor.run {
            (try? doc.replaceTaskMark(line: task.source.line, expectedKey: task.contentKey, with: .completed)) != nil
        }
        guard ticked else { return false }
        await library.save()
        return true
    }
}

/// One pass: fetch the open issues assigned to the user, then notice which
/// pulled issues Jira has closed and tick their tasks.
public actor JiraSyncEngine {
    public static let tag = "jira"

    let client: any JiraClient
    let stateURL: URL
    let sink: any JiraTaskSink
    let now: @Sendable () -> Date
    public private(set) var state: JiraState

    public init(client: any JiraClient, stateURL: URL, sink: any JiraTaskSink, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.stateURL = stateURL; self.sink = sink; self.now = now
        state = JiraState.load(from: stateURL)
    }

    public func syncOnce(_ credentials: JiraCredentials, progress: (@Sendable (String) -> Void)? = nil) async throws -> JiraSyncReport {
        var report = JiraSyncReport()
        progress?("Fetching your issues…")
        let open = try await client.assignedIssues(credentials)
        state.issues = open
        report.fetched = open.count

        // A pulled issue that has left the open list was closed, or reassigned:
        // ask which. Reassigned ones stay pending and are asked again next pass.
        let openKeys = Set(open.map(\.key))
        let pending = state.ledger.filter { $0.value.resolvedAt == nil && !openKeys.contains($0.key) }.map(\.key).sorted()
        if !pending.isEmpty {
            progress?("Checking closed issues…")
            let closed = try await client.issues(keys: pending, credentials).filter { $0.statusCategory == .done }
            for issue in closed {
                guard let pulled = state.ledger[issue.key] else { continue }
                if await sink.complete(key: issue.key, contentKey: pulled.contentKey) { report.resolved += 1 }
                // Stamped either way: ticked, or already gone from the notes.
                state.ledger[issue.key]?.resolvedAt = now()
            }
        }
        state.lastSync = now()
        try? state.save(to: stateURL)
        return report
    }

    /// The sun button: the issue becomes a Today task in Tasks.md with a link
    /// to it in its notes. Returns whether a line was written (not when the
    /// task is there already).
    public func pull(_ issue: JiraIssue, site: URL) async -> Bool {
        let title = Self.taskTitle(for: issue)
        let added = await sink.add(title: title, notes: issue.url(site: site).absoluteString)
        state.ledger[issue.key] = JiraState.Pulled(contentKey: TaskItem.contentKey(for: title), title: title, pulledAt: now())
        try? state.save(to: stateURL)
        return added
    }

    /// "KEY summary #jira": one line, and no `#` from the summary (it would read as a tag).
    public static func taskTitle(for issue: JiraIssue) -> String {
        let summary = issue.summary
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(issue.key) \(summary) #\(tag)"
    }
}
