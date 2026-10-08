import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapJira

final class FakeJiraClient: JiraClient, @unchecked Sendable {
    var open: [JiraIssue] = []
    var byKey: [String: JiraIssue] = [:]
    var offline = false
    var unauthorised = false
    var keyQueries: [[String]] = []

    func assignedIssues(_ credentials: JiraCredentials) async throws -> [JiraIssue] {
        if offline { throw URLError(.notConnectedToInternet) }
        if unauthorised { throw JiraClientError.unauthorised }
        return open
    }
    func issues(keys: [String], _ credentials: JiraCredentials) async throws -> [JiraIssue] {
        keyQueries.append(keys)
        return keys.compactMap { byKey[$0] }
    }
}

final class MemoryTokenStore: JiraTokenStore, @unchecked Sendable {
    var tokens: [String: String] = [:]
    func token(for email: String) throws -> String? { tokens[email] }
    func save(token: String, for email: String) throws { tokens[email] = token }
    func forget(email: String) throws { tokens[email] = nil }
}

private func issue(_ key: String, _ summary: String, status: String = "To Do", category: JiraStatusCategory = .new,
                   type: String = "Task", priority: String? = nil, parent: (String, String)? = nil, updated: Date? = nil) -> JiraIssue {
    JiraIssue(key: key, summary: summary, statusName: status, statusCategory: category, issueType: type, isEpic: type == "Epic",
              priority: priority, parentKey: parent?.0, parentSummary: parent?.1, updated: updated)
}

private let credentials = JiraCredentials(site: URL(string: "https://x.atlassian.net")!, email: "a@b.c", token: "tok")

@Suite struct JiraClientTests {
    @Test func decodesASearchPage() throws {
        let json = """
        {"issues":[
          {"key":"CPAS-1","fields":{"summary":"An epic","status":{"name":"Open","statusCategory":{"key":"new","name":"To Do"}},
            "issuetype":{"name":"Epic","hierarchyLevel":1},"priority":null,"parent":null,"updated":"2026-10-07T12:34:56.000+1300","duedate":null}},
          {"key":"CPAS-2","fields":{"summary":"Rotate the secret","status":{"name":"In Progress","statusCategory":{"key":"indeterminate","name":"In Progress"}},
            "issuetype":{"name":"Task","hierarchyLevel":0},"priority":{"name":"High"},
            "parent":{"key":"CPAS-1","fields":{"summary":"An epic"}},"updated":"2026-10-07T12:34:56.000+1300","duedate":"2026-10-10"}}
        ],"nextPageToken":"abc"}
        """
        let page = try JSONDecoder().decode(JiraSearchPage.self, from: Data(json.utf8))
        let issues = page.issues.map(JiraIssue.init)
        #expect(issues.map(\.key) == ["CPAS-1", "CPAS-2"])
        #expect(issues[0].isEpic && issues[0].priority == nil && issues[0].statusCategory == .new)
        #expect(!issues[1].isEpic && issues[1].statusCategory == .indeterminate && issues[1].priorityRank == 1)
        #expect(issues[1].parentKey == "CPAS-1" && issues[1].parentSummary == "An epic" && issues[1].dueDate == "2026-10-10")
        #expect(issues[1].updated != nil && page.nextPageToken == "abc" && page.isLast == nil)
    }

    @Test func buildsTheRequest() throws {
        let r = JiraCloudClient.request(site: credentials.site, jql: "key in (A-1)", nextPageToken: "p2", credentials: credentials)
        let url = try #require(r.url)
        #expect(url.path == "/rest/api/3/search/jql")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.first { $0.name == "jql" }?.value == "key in (A-1)")
        #expect(query.first { $0.name == "fields" }?.value == JiraCloudClient.fields)
        #expect(query.first { $0.name == "maxResults" }?.value == "100")
        #expect(query.first { $0.name == "nextPageToken" }?.value == "p2")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("a@b.c:tok".utf8).base64EncodedString())
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func taskTitleDropsHashesAndNewlines() {
        let title = JiraSyncEngine.taskTitle(for: issue("CPAS-9", "Fix the #thing\n  now"))
        #expect(title == "CPAS-9 Fix the thing now #jira")
    }
}

@Suite @MainActor struct JiraSyncEngineTests {
    @Test func pullWritesATodayTaskOnceAndResolutionTicksIt() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-jira-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        let client = FakeJiraClient()
        let engine = JiraSyncEngine(client: client, stateURL: tmp.appendingPathComponent("state.json"),
                                    sink: LibraryJiraTaskSink(library: library), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let fix = issue("CPAS-1027", "Fix the #thing", status: "Open")
        let other = issue("CPAS-1050", "Encrypt the volume", status: "In Progress", category: .indeterminate)
        client.open = [fix, other]

        #expect(await engine.pull(fix, site: credentials.site))
        #expect(await engine.pull(other, site: credentials.site))
        #expect(await engine.pull(fix, site: credentials.site) == false)
        let tasksText = try String(contentsOf: folder.tasksFile, encoding: .utf8)
        #expect(tasksText.hasSuffix("- [/] CPAS-1027 Fix the thing #jira\n  https://x.atlassian.net/browse/CPAS-1027\n"
                                    + "- [/] CPAS-1050 Encrypt the volume #jira\n  https://x.atlassian.net/browse/CPAS-1050\n"))
        await library.rescan(full: true)
        let indexed = try library.index.tasks()
        #expect(indexed.count == 2 && indexed.allSatisfy { $0.status == .today && $0.tags == ["jira"] })
        #expect(indexed.first?.notes == "https://x.atlassian.net/browse/CPAS-1027")

        // Both open: nothing to ask about.
        var report = try await engine.syncOnce(credentials)
        #expect(report.fetched == 2 && report.resolved == 0 && client.keyQueries.isEmpty)

        // The user edits the first task's title; then Jira closes it and reassigns the second.
        let doc = await library.loadedDocument(atRelativePath: NotesFolder.tasksFileName)
        try doc.replaceTaskTitle(line: indexed[0].source.line, expectedKey: indexed[0].contentKey, with: "CPAS-1027 Fix the thing #jira #urgent")
        await library.save()
        client.open = []
        client.byKey = ["CPAS-1027": issue("CPAS-1027", "Fix the #thing", status: "Done", category: .done),
                        "CPAS-1050": issue("CPAS-1050", "Encrypt the volume", status: "In Progress", category: .indeterminate)]
        report = try await engine.syncOnce(credentials)
        #expect(report.resolved == 1 && client.keyQueries == [["CPAS-1027", "CPAS-1050"]])
        let after = try String(contentsOf: folder.tasksFile, encoding: .utf8)
        #expect(after.contains("- [x] CPAS-1027 Fix the thing #jira #urgent\n") && after.contains("- [/] CPAS-1050"))
        let state = await engine.state
        #expect(state.ledger["CPAS-1027"]?.resolvedAt != nil && state.ledger["CPAS-1050"]?.resolvedAt == nil)

        // The closed one is not asked about again; the reassigned one is.
        _ = try await engine.syncOnce(credentials)
        #expect(client.keyQueries.last == ["CPAS-1050"])
    }
}

@Suite @MainActor struct JiraSectionTests {
    private func makeSection(_ tmp: URL, client: FakeJiraClient, store: MemoryTokenStore, state: JiraState? = nil) throws -> (JiraSection, UserDefaults) {
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        let suite = "foolscap-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(0, forKey: JiraSection.minutesKey)
        let stateURL = tmp.appendingPathComponent("state.json")
        if let state { try state.save(to: stateURL) }
        return (JiraSection(library: library, client: client, store: store, stateURL: stateURL, defaults: defaults), defaults)
    }

    @Test func groupsPutInProgressFirstAndLeaveOutEpics() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-jira-section-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var state = JiraState()
        state.issues = [
            issue("CPAS-1", "Epic", status: "Open", type: "Epic"),
            issue("CPAS-6", "Waiting", status: "Awaiting - Internal", category: .indeterminate),
            issue("CPAS-2", "Low open", status: "Open", priority: "Minor", updated: Date(timeIntervalSince1970: 10)),
            issue("CPAS-3", "Doing", status: "In Progress", category: .indeterminate),
            issue("CPAS-4", "Big open", status: "Open", priority: "Major", updated: Date(timeIntervalSince1970: 5)),
            issue("CPAS-5", "Newer low", status: "Open", priority: "Minor", updated: Date(timeIntervalSince1970: 20)),
        ]
        state.ledger["CPAS-3"] = JiraState.Pulled(contentKey: "k", title: "t", pulledAt: Date())
        state.ledger["CPAS-4"] = JiraState.Pulled(contentKey: "k", title: "t", pulledAt: Date(), resolvedAt: Date())
        let (section, _) = try makeSection(tmp, client: FakeJiraClient(), store: MemoryTokenStore(), state: state)
        // Awaiting shares Jira's in-progress category but is neither first nor highlighted.
        #expect(section.groups.map(\.name) == ["In Progress", "Awaiting - Internal", "Open"])
        #expect(section.groups.map(\.isActive) == [true, false, false])
        #expect(section.groups[2].issues.map(\.key) == ["CPAS-4", "CPAS-5", "CPAS-2"])
        #expect(section.openCount == 5)
        #expect(section.isPulled(state.issues[3]) && !section.isPulled(state.issues[4]) && !section.isPulled(state.issues[2]))
    }

    @Test func credentialsStatusAndErrors() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-jira-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let client = FakeJiraClient(), store = MemoryTokenStore()
        let (section, defaults) = try makeSection(tmp, client: client, store: store)
        #expect(throws: JiraClientError.unauthorised) { try section.saveCredentials(site: "x.atlassian.net", email: "a@b.c", token: " ") }
        try section.saveCredentials(site: "x.atlassian.net/", email: " a@b.c ", token: "tok")
        #expect(section.credentials == credentials && store.tokens["a@b.c"] == "tok")
        #expect(defaults.string(forKey: JiraSection.siteKey) == "https://x.atlassian.net" && !section.status.needsCredentials)
        // An empty token keeps the one on file.
        try section.saveCredentials(site: "https://x.atlassian.net", email: "a@b.c", token: "")
        #expect(section.credentials?.token == "tok")

        client.offline = true
        await section.runSync()
        #expect(section.status.isOffline && section.status.lastError == nil)
        client.offline = false
        client.unauthorised = true
        await section.runSync()
        #expect(!section.status.isOffline && section.status.lastError?.contains("token") == true)
        client.unauthorised = false
        client.open = [issue("CPAS-7", "Seven")]
        await section.runSync()
        #expect(section.status.lastError == nil && section.state.issues.map(\.key) == ["CPAS-7"] && section.status.lastRun != nil)

        section.clearCredentials()
        #expect(section.credentials == nil && store.tokens.isEmpty && section.status.needsCredentials)
    }
}
