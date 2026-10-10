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
    var transitionsByKey: [String: [JiraTransition]] = [:]
    var transitioned: [(key: String, id: String, resolution: String?)] = []
    var rejectTransition: String?
    var created: [JiraTaskDraft] = []
    var comments: [(key: String, body: String)] = []
    var accountID = "acc-1"
    var taskTypeID: String? = "10008"
    var sprintID: Int? = 13779
    var nextKey = 100

    func assignedIssues(_ credentials: JiraCredentials) async throws -> [JiraIssue] {
        if offline { throw URLError(.notConnectedToInternet) }
        if unauthorised { throw JiraClientError.unauthorised }
        return open
    }
    func issues(keys: [String], _ credentials: JiraCredentials) async throws -> [JiraIssue] {
        keyQueries.append(keys)
        return keys.compactMap { byKey[$0] }
    }
    func issue(key: String, _ credentials: JiraCredentials) async throws -> JiraIssue {
        guard let issue = byKey[key] else { throw JiraClientError.rejected("no issue \(key)") }
        return issue
    }
    func transitions(for key: String, _ credentials: JiraCredentials) async throws -> [JiraTransition] { transitionsByKey[key] ?? [] }
    func transition(_ key: String, to transitionID: String, resolution: String?, _ credentials: JiraCredentials) async throws {
        if let rejectTransition { throw JiraClientError.rejected(rejectTransition) }
        transitioned.append((key, transitionID, resolution))
        if var issue = byKey[key], let t = transitionsByKey[key]?.first(where: { $0.id == transitionID }) {
            issue.statusName = t.toStatusName; issue.statusCategory = t.toCategory
            byKey[key] = issue
        }
    }
    func createTask(_ draft: JiraTaskDraft, _ credentials: JiraCredentials) async throws -> JiraIssue {
        created.append(draft)
        nextKey += 1
        let issue = JiraIssue(key: "\(draft.projectKey)-\(nextKey)", summary: draft.summary, statusName: "Open", statusCategory: .new,
                              issueType: "Task", parentKey: draft.epicKey, commentCount: 0)
        byKey[issue.key] = issue
        return issue
    }
    func comment(_ key: String, body: String, _ credentials: JiraCredentials) async throws { comments.append((key, body)) }
    func myself(_ credentials: JiraCredentials) async throws -> String { accountID }
    func issueTypeID(named name: String, project: String, _ credentials: JiraCredentials) async throws -> String? { taskTypeID }
    func activeSprintID(board: Int, _ credentials: JiraCredentials) async throws -> Int? { sprintID }
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

    @Test func commentBecomesParagraphsOfADF() throws {
        let doc = JiraADF.document(from: "First line\nsecond line\n\nSecond paragraph\n")
        let json = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
        let text = String(decoding: json, as: UTF8.self)
        #expect(text == #"{"content":[{"content":[{"text":"First line","type":"text"},{"type":"hardBreak"},{"text":"second line","type":"text"}],"type":"paragraph"},{"content":[{"text":"Second paragraph","type":"text"}],"type":"paragraph"}],"type":"doc","version":1}"#)
    }

    @Test func writeRequestsCarryTheirBodies() throws {
        let r = JiraCloudClient.request(site: credentials.site, path: "rest/api/3/issue/CPAS-1/transitions", method: "POST",
                                        json: ["transition": ["id": "21"]], credentials: credentials)
        #expect(r.httpMethod == "POST" && r.url?.path == "/rest/api/3/issue/CPAS-1/transitions")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(r.httpBody)) as? [String: [String: String]]
        #expect(body == ["transition": ["id": "21"]])
        // Jira's refusals are read from its error body.
        let refusal = Data(#"{"errorMessages":["Transition is not valid"],"errors":{"resolution":"Resolution is required."}}"#.utf8)
        #expect(JiraCloudClient.rejection(in: refusal) == "Transition is not valid resolution: Resolution is required.")
        #expect(JiraClientError.rejected("x").message == "Jira said: x")
    }

    @Test func decodesTransitionsAndSprints() throws {
        let transitions = try JSONDecoder().decode(JiraTransitionsPage.self, from: Data("""
        {"transitions":[{"id":"21","name":"In Progress","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},
                        {"id":"51","name":"Resolved","to":{"name":"Resolved","statusCategory":{"key":"done"}}}]}
        """.utf8)).transitions.map(JiraTransition.init)
        #expect(transitions.map(\.id) == ["21", "51"] && transitions[1].toCategory == .done && transitions[0].toStatusName == "In Progress")
        let sprints = try JSONDecoder().decode(JiraSprintPage.self, from: Data(#"{"values":[{"id":13779,"name":"2026Q3","state":"active"}]}"#.utf8))
        #expect(sprints.values.first?.id == 13779)
        let types = try JSONDecoder().decode(JiraIssueTypesPage.self, from: Data(#"{"issueTypes":[{"id":"10000","name":"Epic"},{"id":"10008","name":"Task"}]}"#.utf8))
        #expect(types.issueTypes.first { $0.name == "Task" }?.id == "10008")
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

    @Test func statusChangeCreateAndCommentWriteThrough() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-jira-writes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        let client = FakeJiraClient()
        let engine = JiraSyncEngine(client: client, stateURL: tmp.appendingPathComponent("state.json"),
                                    sink: LibraryJiraTaskSink(library: library), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let fix = issue("CPAS-1027", "Fix the thing", status: "Open")
        client.open = [fix]
        client.byKey[fix.key] = fix
        client.transitionsByKey[fix.key] = [JiraTransition(id: "21", name: "In Progress", toStatusName: "In Progress", toCategory: .indeterminate),
                                            JiraTransition(id: "51", name: "Resolved", toStatusName: "Resolved", toCategory: .done)]
        _ = try await engine.syncOnce(credentials)
        _ = await engine.pull(fix, site: credentials.site)

        // Into In Progress: the row follows Jira's answer.
        try await engine.setStatus(fix, to: client.transitionsByKey[fix.key]![0], credentials)
        #expect(client.transitioned.map(\.id) == ["21"] && client.transitioned[0].resolution == nil)
        let moved = await engine.state
        #expect(moved.issues.first?.statusName == "In Progress")

        // Into Resolved: a resolution goes with it, the Today task is ticked and the issue leaves the list.
        try await engine.setStatus(fix, to: client.transitionsByKey[fix.key]![1], credentials)
        #expect(client.transitioned.last?.resolution == "Done")
        let resolved = await engine.state
        #expect(resolved.issues.isEmpty && resolved.ledger[fix.key]?.resolvedAt != nil)
        #expect(try String(contentsOf: folder.tasksFile, encoding: .utf8).contains("- [x] CPAS-1027 Fix the thing #jira"))

        // A new task takes the defaults, the user's account and the open sprint, and heads the list.
        let made = try await engine.create(summary: "  Rotate   the secret ", defaults: JiraNewTaskDefaults(projectKey: "CPAS", epicKey: "CPAS-2", boardID: 1045), credentials)
        #expect(client.created == [JiraTaskDraft(summary: "Rotate the secret", projectKey: "CPAS", issueTypeID: "10008", epicKey: "CPAS-2",
                                                 assigneeAccountID: "acc-1", sprintID: 13779)])
        let created = await engine.state
        #expect(made.key == "CPAS-101" && created.issues.first?.key == "CPAS-101")
        #expect(created.accountID == "acc-1" && created.issueTypeIDs?["CPAS"] == "10008")

        // A comment is posted and counted.
        try await engine.comment(made, body: "On it.\n", credentials)
        let commented = await engine.state
        #expect(client.comments.map(\.body) == ["On it."] && commented.issues.first?.commentCount == 1)
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

    @Test func aRouteNamesAnIssueToReveal() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-jira-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (section, _) = try makeSection(tmp, client: FakeJiraClient(), store: MemoryTokenStore())
        section.navigate(to: SectionRoute(path: "Daily/2026-10-11.md", line: 3))
        #expect(section.pendingKey == nil)
        section.navigate(to: SectionRoute(path: "CPAS-3"))
        #expect(section.pendingKey == "CPAS-3")
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

    @Test func rejectedWritesShowJirasReason() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-jira-reject-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let client = FakeJiraClient(), store = MemoryTokenStore()
        var state = JiraState()
        let fix = issue("CPAS-7", "Seven", status: "Open")
        state.issues = [fix]
        let (section, defaults) = try makeSection(tmp, client: client, store: store, state: state)
        try section.saveCredentials(site: "x.atlassian.net", email: "a@b.c", token: "tok")
        await section.runSync()
        client.byKey[fix.key] = fix
        client.transitionsByKey[fix.key] = [JiraTransition(id: "21", name: "In Progress", toStatusName: "In Progress", toCategory: .indeterminate)]
        client.open = [fix]
        await section.runSync()
        client.rejectTransition = "Transition is not valid"
        #expect(await section.setStatus(fix, to: client.transitionsByKey[fix.key]![0]).value == false)
        #expect(section.status.lastError == "Jira said: Transition is not valid" && section.state.issues.first?.statusName == "Open")
        #expect(section.busyKeys.isEmpty)

        client.rejectTransition = nil
        #expect(await section.setStatus(fix, to: client.transitionsByKey[fix.key]![0]).value)
        #expect(section.status.lastError == nil && section.state.issues.first?.statusName == "In Progress")

        defaults.set("", forKey: JiraSection.epicKey)
        defaults.set(0, forKey: JiraSection.boardKey)
        #expect(section.newTaskDefaults == JiraNewTaskDefaults(projectKey: "CPAS", epicKey: nil, boardID: nil))
        #expect(await section.createTask(summary: "A task").value && section.state.issues.first?.summary == "A task" && !section.isCreating)
        #expect(await section.comment(fix, body: "hi").value && client.comments.count == 1)
    }
}
