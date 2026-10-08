import SwiftUI
import Network
import FoolscapCore
import FoolscapStore

/// Sync progress and outcome, for the page and the settings pane.
@MainActor
@Observable
public final class JiraSyncStatus {
    public var isRunning = false
    public var phase: String?
    public var lastRun: Date?
    public var lastReport: JiraSyncReport?
    public var lastError: String?
    /// The last pass found no connection; the next one runs when it returns.
    public var isOffline = false
    /// No site, email or token yet: the page points at Settings.
    public var needsCredentials = false
    public init() {}
}

/// Where the API token lives. The site and email are not secrets and sit in
/// the defaults; only the token goes somewhere backups never copy.
public protocol JiraTokenStore: Sendable {
    func token(for email: String) throws -> String?
    func save(token: String, for email: String) throws
    func forget(email: String) throws
}

/// The login keychain: one generic password per email, so it can also be
/// seeded from a Terminal with
/// `security add-generic-password -s com.seanmatheny.foolscap.jira -a <email> -l "Foolscap Jira" -w`.
public struct KeychainTokenStore: JiraTokenStore {
    public static let service = "com.seanmatheny.foolscap.jira"
    public init() {}
    private func item(_ email: String) -> KeychainItem { KeychainItem(service: Self.service, account: email, label: "Foolscap Jira") }
    public func token(for email: String) throws -> String? {
        try item(email).read().map { String(decoding: $0, as: UTF8.self) }
    }
    public func save(token: String, for email: String) throws { try item(email).write(Data(token.utf8)) }
    public func forget(email: String) throws { try item(email).delete() }
}

/// The Jira tab: the issues assigned to the user, grouped by their Jira
/// status, each with a sun that pulls it into Today as a `#jira` task.
@MainActor
@Observable
public final class JiraSection: NotebookSection {
    public static let sectionID = "jira"
    public static let tag = JiraSyncEngine.tag
    public static let defaultSyncMinutes = 60
    public static let siteKey = "jiraSite", emailKey = "jiraEmail", minutesKey = "jiraSyncMinutes"

    public let id = JiraSection.sectionID
    /// The fifth tab colour is its own: the others are taken by the built-in tabs.
    public let tab = TabAppearance(label: "Jira", systemImage: "checkmark.rectangle.stack", colorIndex: 4, shortcut: "j")

    let library: NotebookLibrary
    public let status = JiraSyncStatus()
    public private(set) var state: JiraState
    public private(set) var credentials: JiraCredentials?

    @ObservationIgnored private let client: any JiraClient
    @ObservationIgnored private let store: any JiraTokenStore
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var engine: JiraSyncEngine?
    @ObservationIgnored private var scheduler: PeriodicScheduler?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    /// Bumped by every pass and by stop, so a cancelled pass reports nothing when it unwinds.
    @ObservationIgnored private var passID = 0

    public init(library: NotebookLibrary, client: any JiraClient = JiraCloudClient(), store: any JiraTokenStore = KeychainTokenStore(),
                stateURL: URL = JiraPaths.stateURL, defaults: UserDefaults = .standard) {
        self.library = library; self.client = client; self.store = store; self.stateURL = stateURL; self.defaults = defaults
        state = JiraState.load(from: stateURL)
    }

    // MARK: Settings

    public var site: String { defaults.string(forKey: Self.siteKey) ?? "" }
    public var email: String { defaults.string(forKey: Self.emailKey) ?? "" }

    /// Minutes between checks; 0 means only when asked.
    public var syncMinutes: Int {
        defaults.object(forKey: Self.minutesKey) == nil ? Self.defaultSyncMinutes : defaults.integer(forKey: Self.minutesKey)
    }

    /// Called by the settings pane after the interval changes.
    public func settingsChanged() {
        guard scheduler != nil || pathMonitor != nil else { return }
        applySchedule()
    }

    private func applySchedule() {
        scheduler?.stop()
        scheduler = nil
        guard syncMinutes > 0 else { return }
        let s = PeriodicScheduler(identifier: "com.seanmatheny.foolscap.jira-sync") { [weak self] in await self?.runSync() }
        s.start(minutes: syncMinutes)
        scheduler = s
    }

    /// The site is normalised to `https://host`; an empty token keeps the one on file.
    public func saveCredentials(site rawSite: String, email rawEmail: String, token: String) throws {
        var host = rawSite.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.contains("://") { host = "https://" + host }
        while host.hasSuffix("/") { host.removeLast() }
        guard let url = URL(string: host), url.host != nil else { throw JiraClientError.invalidResponse("not a site address") }
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = token.isEmpty ? (try? store.token(for: email)) ?? nil : nil
        guard let secret = token.isEmpty ? kept : token, !secret.isEmpty else { throw JiraClientError.unauthorised }
        if !token.isEmpty { try store.save(token: token, for: email) }
        defaults.set(url.absoluteString, forKey: Self.siteKey)
        defaults.set(email, forKey: Self.emailKey)
        credentials = JiraCredentials(site: url, email: email, token: secret)
        status.needsCredentials = false
        status.lastError = nil
        syncNow()
    }

    public func clearCredentials() {
        cancelSync()
        if !email.isEmpty { try? store.forget(email: email) }
        credentials = nil
        status.needsCredentials = true
    }

    /// The credentials on file, read from the defaults and the keychain.
    private func loadCredentials() {
        guard let url = URL(string: site), url.host != nil, !email.isEmpty,
              let token = try? store.token(for: email), !token.isEmpty else {
            credentials = nil
            status.needsCredentials = true
            return
        }
        credentials = JiraCredentials(site: url, email: email, token: token)
        status.needsCredentials = false
    }

    // MARK: Lifecycle

    public func start() {
        guard pathMonitor == nil else { return }
        loadCredentials()
        applySchedule()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let self, self.status.isOffline else { return }
                self.syncNow()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        if credentials != nil {
            startupTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.syncNow()
            }
        }
    }

    public func stop() {
        scheduler?.stop()
        scheduler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        cancelSync()
        engine = nil
    }

    private func engineForSync() -> JiraSyncEngine {
        if let engine { return engine }
        let made = JiraSyncEngine(client: client, stateURL: stateURL, sink: LibraryJiraTaskSink(library: library))
        engine = made
        return made
    }

    public func syncNow() { startSync() }

    /// One pass from the schedule, awaited (it needs to know when it finished).
    func runSync() async { await startSync().value }

    /// Every pass runs as `syncTask`; asking while one runs joins it.
    @discardableResult
    private func startSync() -> Task<Void, Never> {
        if let syncTask { return syncTask }
        passID += 1
        let pass = passID
        let task = Task { [weak self] in
            await self?.performSync(pass: pass)
            guard let self, self.passID == pass else { return }
            self.syncTask = nil
        }
        syncTask = task
        return task
    }

    private func cancelSync() {
        startupTask?.cancel()
        startupTask = nil
        syncTask?.cancel()
        syncTask = nil
        passID += 1
        status.isRunning = false
        status.phase = nil
    }

    private func performSync(pass: Int) async {
        guard let credentials else { status.needsCredentials = true; return }
        let engine = engineForSync()
        status.isRunning = true
        status.lastError = nil
        defer {
            if passID == pass { status.isRunning = false; status.phase = nil }
        }
        let progress: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor in
                guard let self, self.passID == pass, self.status.isRunning else { return }
                self.status.phase = message
            }
        }
        do {
            let report = try await engine.syncOnce(credentials, progress: progress)
            let newState = await engine.state
            guard passID == pass else { return }
            state = newState
            status.lastRun = Date()
            status.lastReport = report
            status.isOffline = false
            if report.resolved > 0 { await library.rescan() }
        } catch JiraClientError.unauthorised {
            guard passID == pass else { return }
            status.isOffline = false
            status.lastError = "Jira rejected the email or API token."
        } catch is CancellationError {
            // Stopped: nothing to report.
        } catch where JiraClientError.isOffline(error) {
            guard passID == pass else { return }
            status.isOffline = true
        } catch {
            guard passID == pass else { return }
            status.isOffline = false
            status.lastError = "\(error)"
        }
    }

    // MARK: Issues

    /// The sun button: the issue joins Today as a task in Tasks.md.
    public func pull(_ issue: JiraIssue) {
        guard let site = credentials?.site ?? URL(string: self.site) else { return }
        let engine = engineForSync()
        Task { [weak self] in
            _ = await engine.pull(issue, site: site)
            guard let self else { return }
            self.state = await engine.state
            await self.library.rescan()
        }
    }

    /// Whether the issue has a task in Today that Jira has not closed yet.
    public func isPulled(_ issue: JiraIssue) -> Bool {
        state.ledger[issue.key].map { $0.resolvedAt == nil } ?? false
    }

    public func open(_ issue: JiraIssue) {
        guard let site = credentials?.site ?? URL(string: self.site) else { return }
        NSWorkspace.shared.open(issue.url(site: site))
    }

    public struct Group: Identifiable, Equatable {
        public var name: String
        /// Jira's "in progress" category: the group the page highlights.
        public var isActive: Bool
        public var issues: [JiraIssue]
        public var id: String { name }
    }

    /// Issues by Jira status, the in-progress statuses first, then the rest in
    /// the order Jira listed them; epics are containers, not work, and are left
    /// out. Within a group, priority first, then the latest change.
    public var groups: [Group] {
        var order: [String] = []
        var byStatus: [String: [JiraIssue]] = [:]
        var active: Set<String> = []
        for issue in state.issues where !issue.isEpic {
            if byStatus[issue.statusName] == nil { order.append(issue.statusName) }
            byStatus[issue.statusName, default: []].append(issue)
            if issue.statusCategory == .indeterminate { active.insert(issue.statusName) }
        }
        let sorted = order.sorted { a, b in
            let aa = active.contains(a), ba = active.contains(b)
            return aa != ba ? aa : order.firstIndex(of: a)! < order.firstIndex(of: b)!
        }
        return sorted.map { name in
            let issues = byStatus[name]!.sorted { a, b in
                a.priorityRank != b.priorityRank ? a.priorityRank < b.priorityRank
                    : (a.updated ?? .distantPast) > (b.updated ?? .distantPast)
            }
            return Group(name: name, isActive: active.contains(name), issues: issues)
        }
    }

    public var openCount: Int { state.issues.filter { !$0.isEpic }.count }

    // MARK: NotebookSection

    public func makeRootView() -> AnyView { AnyView(JiraPage(section: self)) }
    public func makeSettingsPane() -> AnyView? { AnyView(JiraSettingsPane(section: self)) }
}
