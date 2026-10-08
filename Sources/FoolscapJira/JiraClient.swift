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
}

public protocol JiraClient: Sendable {
    /// Every open issue assigned to the token's user.
    func assignedIssues(_ credentials: JiraCredentials) async throws -> [JiraIssue]
    /// The named issues whatever their status (how a pulled issue's resolution is noticed).
    func issues(keys: [String], _ credentials: JiraCredentials) async throws -> [JiraIssue]
}

/// Jira Cloud's REST API v3, with basic auth on an API token.
public final class JiraCloudClient: JiraClient {
    public static let openJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY status, updated DESC"
    public static let fields = "summary,status,issuetype,priority,parent,updated,duedate"
    public static let pageSize = 100
    static let keysPerQuery = 50

    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

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

    static func request(site: URL, jql: String, nextPageToken: String?, credentials: JiraCredentials) -> URLRequest {
        var components = URLComponents(url: site.appendingPathComponent("rest/api/3/search/jql"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "jql", value: jql),
                     URLQueryItem(name: "fields", value: fields),
                     URLQueryItem(name: "maxResults", value: String(pageSize))]
        if let nextPageToken { items.append(URLQueryItem(name: "nextPageToken", value: nextPageToken)) }
        components.queryItems = items
        var r = URLRequest(url: components.url!)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let basic = Data("\(credentials.email):\(credentials.token)".utf8).base64EncodedString()
        r.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func search(_ jql: String, _ credentials: JiraCredentials) async throws -> [JiraIssue] {
        var out: [JiraIssue] = []
        var token: String?
        repeat {
            let (data, response) = try await session.data(for: Self.request(site: credentials.site, jql: jql, nextPageToken: token,
                                                                             credentials: credentials))
            guard let http = response as? HTTPURLResponse else { throw JiraClientError.invalidResponse("no HTTP response") }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw JiraClientError.unauthorised
            default: throw JiraClientError.http(http.statusCode)
            }
            let page: JiraSearchPage
            do { page = try JSONDecoder().decode(JiraSearchPage.self, from: data) }
            catch { throw JiraClientError.invalidResponse(String(describing: error)) }
            out += page.issues.map(JiraIssue.init)
            token = page.isLast == true ? nil : page.nextPageToken
        } while token != nil
        return out
    }
}
