import Foundation

/// A folder or notebook as Amazon lists it. Folders nest; there is no parent
/// field and no modification time in the listing.
public struct RemoteItem: Decodable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var type: String
    public var items: [RemoteItem]?

    public init(id: String, title: String, type: String, items: [RemoteItem]? = nil) {
        self.id = id; self.title = title; self.type = type; self.items = items
    }
    public var isFolder: Bool { type == "folder" }
    public var isNotebook: Bool { type == "notebook" }
}

struct RemoteListing: Decodable {
    var itemsList: [RemoteItem]
}

/// What `openNotebook` returns: the token that authorises rendering plus the
/// notebook's metadata.
public struct OpenedNotebook: Decodable, Equatable, Sendable {
    public struct Metadata: Decodable, Equatable, Sendable {
        public var modificationTime: Double
        public var totalPages: Int
        public init(modificationTime: Double, totalPages: Int) { self.modificationTime = modificationTime; self.totalPages = totalPages }
    }
    public var renderingToken: String
    public var metadata: Metadata

    public init(renderingToken: String, metadata: Metadata) { self.renderingToken = renderingToken; self.metadata = metadata }

    /// Epoch seconds, whether Amazon sent seconds or milliseconds.
    public var modificationTime: Int {
        let t = metadata.modificationTime
        return Int(t > 1e11 ? t / 1000 : t)
    }
}

public enum ScribeClientError: Error, Equatable {
    /// A redirect or a sign-in page instead of data: the session has lapsed.
    case signedOut
    case http(Int)
    case invalidResponse(String)
    case notATar
}

public protocol ScribeClient: Sendable {
    func listNotebooks() async throws -> [RemoteItem]
    func openNotebook(id: String) async throws -> OpenedNotebook
    /// A tar of one PNG per page.
    func renderPages(token: String, pageCount: Int) async throws -> Data
}

/// The Kindle notebook web API, as KindleScribeSync.py drives it. Amazon only
/// serves this app to an Android browser, hence the user agent; every request
/// carries no-cache headers and a cache-busting `_t`.
public final class AmazonScribeClient: NSObject, ScribeClient, URLSessionTaskDelegate, @unchecked Sendable {
    public static let userAgent = "Mozilla/5.0 (Linux; Android 11; SAMSUNG SM-G973U) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/14.2 Chrome/87.0.4280.141 Mobile Safari/537.36"
    public static let signInURL = URL(string: "https://read.amazon.com/kindle-notebook?ref_=neo_mm_yn_na_kfa")!
    public static let listURL = "https://read.amazon.com/kindle-notebook/api/notes"
    public static let openURL = "https://read.amazon.com/openNotebook"
    public static let renderURL = "https://read.amazon.com/renderPage"
    public static let marketplace = "ATVPDKIKX0DER"
    public static let renderTokenHeader = "x-amzn-karamel-notebook-rendering-token"
    public static let cookieDomainSuffix = "amazon.com"
    static let renderWidth = 1200, renderHeight = 2500, renderDPI = 160

    private let session: URLSession
    private let sleep: @Sendable (Duration) async -> Void

    public init(sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        super.init()
    }

    // Redirects are refused: a 3xx is how a lapsed session shows itself.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func request(_ base: String, query: [String: String] = [:], headers: [String: String] = [:]) -> URLRequest {
        var components = URLComponents(string: base)!
        var items = components.queryItems ?? []
        items += query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "_t", value: String(Int(Date().timeIntervalSince1970))))
        components.queryItems = items
        var r = URLRequest(url: components.url!)
        r.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        r.setValue("no-cache", forHTTPHeaderField: "Pragma")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request, delegate: self)
        guard let http = response as? HTTPURLResponse else { throw ScribeClientError.invalidResponse("no HTTP response") }
        if (300..<400).contains(http.statusCode) { throw ScribeClientError.signedOut }
        guard http.statusCode == 200 else { throw ScribeClientError.http(http.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
            if head.contains("<html") || head.contains("<!doctype") || head.contains("signin") { throw ScribeClientError.signedOut }
            throw ScribeClientError.invalidResponse(String(describing: error))
        }
    }

    public func listNotebooks() async throws -> [RemoteItem] {
        try decode(RemoteListing.self, from: try await fetch(request(Self.listURL))).itemsList
    }

    public func openNotebook(id: String) async throws -> OpenedNotebook {
        var lastError: Error = ScribeClientError.invalidResponse("no attempts")
        for attempt in 0..<3 {
            do {
                let data = try await fetch(request(Self.openURL, query: ["notebookId": id, "marketplaceId": Self.marketplace]))
                return try decode(OpenedNotebook.self, from: data)
            } catch ScribeClientError.signedOut {
                throw ScribeClientError.signedOut
            } catch {
                lastError = error
                if attempt < 2 { await sleep(.seconds(2)) }
            }
        }
        throw lastError
    }

    public func renderPages(token: String, pageCount: Int) async throws -> Data {
        let query = ["startPage": "0", "endPage": String(max(0, pageCount - 1)),
                     "width": String(Self.renderWidth), "height": String(Self.renderHeight), "dpi": String(Self.renderDPI)]
        return try await fetch(request(Self.renderURL, query: query, headers: [Self.renderTokenHeader: token]))
    }

    // MARK: Cookies

    /// Whether a session cookie for Amazon is on file.
    public static func hasSessionCookies() -> Bool {
        (HTTPCookieStorage.shared.cookies ?? []).contains { $0.domain.hasSuffix(cookieDomainSuffix) && $0.name == "session-id" }
    }

    public static func clearCookies() {
        for cookie in HTTPCookieStorage.shared.cookies ?? [] where cookie.domain.hasSuffix(cookieDomainSuffix) {
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
    }
}
