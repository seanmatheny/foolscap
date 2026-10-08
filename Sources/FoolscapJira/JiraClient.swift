import Foundation

/// Where to ask and who is asking. The token is an Atlassian API token.
public struct JiraCredentials: Equatable, Sendable {
    public var site: URL
    public var email: String
    public var token: String

    public init(site: URL, email: String, token: String) {
        self.site = site; self.email = email; self.token = token
    }
}

public enum JiraClientError: Error, Equatable {
    /// 401 or 403: the email or token is wrong, or the token's user cannot see the site.
    case unauthorised
    /// Jira refused the request and said why ("resolution: Resolution is required.").
    case rejected(String)
    case http(Int)
    case invalidResponse(String)

    /// Whether `error` is the Mac being offline, so the page says "Offline"
    /// rather than showing a failure. (The same list as the Scribe client's;
    /// copied because this target must not depend on that one.)
    public static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return true
        default:
            return false
        }
    }

    /// What the page shows for the error.
    public var message: String {
        switch self {
        case .unauthorised: return "Jira rejected the email or API token."
        case .rejected(let why): return "Jira said: \(why)"
        case .http(let code): return "Jira answered \(code)."
        case .invalidResponse(let what): return "Jira's answer could not be read (\(what))."
        }
    }
}

public protocol JiraClient: Sendable {
    /// Every open issue assigned to the token's user.
    func assignedIssues(_ credentials: JiraCredentials) async throws -> [JiraIssue]
    /// The named issues whatever their status (how a pulled issue's resolution is noticed).
    func issues(keys: [String], _ credentials: JiraCredentials) async throws -> [JiraIssue]
    /// One issue, read directly: a search lags a few seconds behind a write.
    func issue(key: String, _ credentials: JiraCredentials) async throws -> JiraIssue
    /// The moves the workflow allows from the issue's current status.
    func transitions(for key: String, _ credentials: JiraCredentials) async throws -> [JiraTransition]
    /// Make one of those moves; `resolution` is set on the way when given.
    func transition(_ key: String, to transitionID: String, resolution: String?, _ credentials: JiraCredentials) async throws
    func createTask(_ draft: JiraTaskDraft, _ credentials: JiraCredentials) async throws -> JiraIssue
    func comment(_ key: String, body: String, _ credentials: JiraCredentials) async throws
    /// The token's user, as an account id.
    func myself(_ credentials: JiraCredentials) async throws -> String
    func issueTypeID(named name: String, project: String, _ credentials: JiraCredentials) async throws -> String?
    func activeSprintID(board: Int, _ credentials: JiraCredentials) async throws -> Int?
}

/// Jira Cloud's REST API v3 (and the Agile API for sprints), with basic auth
/// on an API token.
public final class JiraCloudClient: JiraClient {
    public static let openJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY status, updated DESC"
    public static let fields = "summary,status,issuetype,priority,parent,updated,duedate,comment"
    public static let pageSize = 100
    static let keysPerQuery = 50

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    // MARK: Requests

    /// Any call: `path` under the site, a query, and a JSON body for writes.
    static func request(site: URL, path: String, query: [URLQueryItem] = [], method: String = "GET", json: Any? = nil,
                        credentials: JiraCredentials) -> URLRequest {
        var components = URLComponents(url: site.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var r = URLRequest(url: components.url!)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let basic = Data("\(credentials.email):\(credentials.token)".utf8).base64EncodedString()
        r.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return r
    }

    static func request(site: URL, jql: String, nextPageToken: String?, credentials: JiraCredentials) -> URLRequest {
        var items = [URLQueryItem(name: "jql", value: jql),
                     URLQueryItem(name: "fields", value: fields),
                     URLQueryItem(name: "maxResults", value: String(pageSize))]
        if let nextPageToken { items.append(URLQueryItem(name: "nextPageToken", value: nextPageToken)) }
        return request(site: site, path: "rest/api/3/search/jql", query: items, credentials: credentials)
    }

    /// Jira's refusal, from its error body, for the page to show.
    static func rejection(in data: Data) -> String? {
        (try? JSONDecoder().decode(JiraErrorBody.self, from: data))?.message
    }

    /// Perform a request; anything but success becomes a `JiraClientError`.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JiraClientError.invalidResponse("no HTTP response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw JiraClientError.unauthorised
        case 400, 404, 409, 422: throw JiraClientError.rejected(Self.rejection(in: data) ?? "request refused (\(http.statusCode))")
        default: throw JiraClientError.http(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw JiraClientError.invalidResponse(String(describing: error)) }
    }

    // MARK: Reads

    public func assignedIssues(_ credentials: JiraCredentials) async throws -> [JiraIssue] {
        try await search(Self.openJQL, credentials)
    }

    public func issues(keys: [String], _ credentials: JiraCredentials) async throws -> [JiraIssue] {
        var out: [JiraIssue] = []
        for start in stride(from: 0, to: keys.count, by: Self.keysPerQuery) {
            let chunk = keys[start..<min(keys.count, start + Self.keysPerQuery)]
            out += try await search("key in (\(chunk.joined(separator: ", ")))", credentials)
        }
        return out
    }

    private func search(_ jql: String, _ credentials: JiraCredentials) async throws -> [JiraIssue] {
        var out: [JiraIssue] = []
        var token: String?
        repeat {
            let data = try await send(Self.request(site: credentials.site, jql: jql, nextPageToken: token, credentials: credentials))
            let page = try decode(JiraSearchPage.self, from: data)
            out += page.issues.map(JiraIssue.init)
            token = page.isLast == true ? nil : page.nextPageToken
        } while token != nil
        return out
    }

    public func issue(key: String, _ credentials: JiraCredentials) async throws -> JiraIssue {
        let data = try await send(Self.request(site: credentials.site, path: "rest/api/3/issue/\(key)",
                                               query: [URLQueryItem(name: "fields", value: Self.fields)], credentials: credentials))
        return JiraIssue(try decode(JiraSearchPage.RawIssue.self, from: data))
    }

    public func transitions(for key: String, _ credentials: JiraCredentials) async throws -> [JiraTransition] {
        let data = try await send(Self.request(site: credentials.site, path: "rest/api/3/issue/\(key)/transitions", credentials: credentials))
        return try decode(JiraTransitionsPage.self, from: data).transitions.map(JiraTransition.init)
    }

    public func myself(_ credentials: JiraCredentials) async throws -> String {
        let data = try await send(Self.request(site: credentials.site, path: "rest/api/3/myself", credentials: credentials))
        return try decode(JiraMyself.self, from: data).accountId
    }

    public func issueTypeID(named name: String, project: String, _ credentials: JiraCredentials) async throws -> String? {
        let data = try await send(Self.request(site: credentials.site, path: "rest/api/3/issue/createmeta/\(project)/issuetypes",
                                               credentials: credentials))
        return try decode(JiraIssueTypesPage.self, from: data).issueTypes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    public func activeSprintID(board: Int, _ credentials: JiraCredentials) async throws -> Int? {
        let data = try await send(Self.request(site: credentials.site, path: "rest/agile/1.0/board/\(board)/sprint",
                                               query: [URLQueryItem(name: "state", value: "active")], credentials: credentials))
        return try decode(JiraSprintPage.self, from: data).values.first?.id
    }

    // MARK: Writes

    public func transition(_ key: String, to transitionID: String, resolution: String?, _ credentials: JiraCredentials) async throws {
        var body: [String: Any] = ["transition": ["id": transitionID]]
        if let resolution { body["fields"] = ["resolution": ["name": resolution]] }
        do {
            _ = try await send(Self.request(site: credentials.site, path: "rest/api/3/issue/\(key)/transitions", method: "POST",
                                            json: body, credentials: credentials))
        } catch JiraClientError.rejected(let why) where resolution != nil && why.localizedCaseInsensitiveContains("resolution") {
            // The workflow sets its own resolution and refuses one on the screen: once more without.
            try await transition(key, to: transitionID, resolution: nil, credentials)
        }
    }

    public func createTask(_ draft: JiraTaskDraft, _ credentials: JiraCredentials) async throws -> JiraIssue {
        var fields: [String: Any] = ["project": ["key": draft.projectKey],
                                     "issuetype": ["id": draft.issueTypeID],
                                     "summary": draft.summary]
        if let epic = draft.epicKey { fields["parent"] = ["key": epic] }
        if let assignee = draft.assigneeAccountID { fields["assignee"] = ["accountId": assignee] }
        let data = try await send(Self.request(site: credentials.site, path: "rest/api/3/issue", method: "POST",
                                               json: ["fields": fields], credentials: credentials))
        let key = try decode(JiraCreatedIssue.self, from: data).key
        if let sprint = draft.sprintID {
            // The Agile API moves an issue into a sprint without knowing the sprint field's id.
            _ = try await send(Self.request(site: credentials.site, path: "rest/agile/1.0/sprint/\(sprint)/issue", method: "POST",
                                            json: ["issues": [key]], credentials: credentials))
        }
        // Not a search: the search index would not have the new issue yet.
        return try await issue(key: key, credentials)
    }

    public func comment(_ key: String, body: String, _ credentials: JiraCredentials) async throws {
        _ = try await send(Self.request(site: credentials.site, path: "rest/api/3/issue/\(key)/comment", method: "POST",
                                        json: ["body": JiraADF.document(from: body)], credentials: credentials))
    }
}
