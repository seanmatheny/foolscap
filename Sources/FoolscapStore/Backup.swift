import Foundation
import FoolscapCore

/// What a backup archive says about itself (`manifest.json` at its root).
public struct BackupManifest: Codable, Equatable, Sendable {
    public var format: Int
    public var createdAt: Date
    public var notesFolder: String
    public var appVersion: String?
    public var includesIndex: Bool
    public var includesSupport: Bool
    public var includesPreferences: Bool

    public static let currentFormat = 1
}

public enum BackupError: LocalizedError {
    case notABackup
    case toolFailed(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notABackup: return "That file is not a Foolscap backup (no manifest inside)."
        case .toolFailed(let s): return "The archive tool failed: \(s)"
        case .unreadable(let s): return "Could not read the backup: \(s)"
        }
    }
}

/// One backup is a zip archive. Inside, at the root:
///
///     manifest.json          what and when
///     Notebook/              the notes folder: Daily/, Attachments/, Scribe/, Tasks.md
///     Index/index.sqlite     the search index (link previews, tags, tasks) via SQLite's backup API
///     Support/               Application Support/Foolscap minus indexes and backups (Scribe state, OCR cache)
///     Preferences.plist      the app's settings, minus window frames and folder paths
///
/// Everything in it is plain files, so the notebook can be recovered by hand
/// with any unzipper if the app is gone.
public enum BackupArchive {
    public static let manifestName = "manifest.json"
    public static let notebookDirectory = "Notebook"
    public static let indexPath = "Index/index.sqlite"
    public static let supportDirectory = "Support"
    public static let preferencesName = "Preferences.plist"

    /// Write a backup of the given pieces to `destination` (a `.zip`).
    /// Runs synchronously; call it off the main actor.
    public static func create(notes: NotesFolder, index: SearchIndex?, supportDirectory: URL?, preferencesPlist: Data?,
                              appVersion: String?, to destination: URL, now: Date = Date()) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("foolscap-backup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Notes: every notebook file, read through the coordinator so iCloud is happy.
        let notebookRoot = staging.appendingPathComponent(notebookDirectory, isDirectory: true)
        try fm.createDirectory(at: notebookRoot, withIntermediateDirectories: true)
        for (file, rel) in NotesFolder.notebookFiles(under: notes.root) {
            let dest = notebookRoot.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileIO.read(file).write(to: dest)
        }
        for dir in NotesFolder.layoutDirectories {
            try fm.createDirectory(at: notebookRoot.appendingPathComponent(dir, isDirectory: true), withIntermediateDirectories: true)
        }

        var includesIndex = false
        if let index {
            let indexFile = staging.appendingPathComponent(indexPath)
            try fm.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try index.backup(toFileAt: indexFile.path)
            includesIndex = true
        }

        var includesSupport = false
        if let supportDirectory, fm.fileExists(atPath: supportDirectory.path) {
            let dest = staging.appendingPathComponent(Self.supportDirectory, isDirectory: true)
            try copyTree(from: supportDirectory, to: dest) { url in
                let name = url.lastPathComponent
                return name.hasPrefix(".") || name.contains(".sqlite") || name == "Backups"
            }
            includesSupport = true
        }

        if let preferencesPlist {
            try preferencesPlist.write(to: staging.appendingPathComponent(preferencesName))
        }

        let manifest = BackupManifest(format: BackupManifest.currentFormat, createdAt: now, notesFolder: notes.root.path,
                                      appVersion: appVersion, includesIndex: includesIndex, includesSupport: includesSupport,
                                      includesPreferences: preferencesPlist != nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent(manifestName))

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try zip(staging, to: destination)
    }

    /// An unpacked backup. `root` is a temporary directory the caller removes when done.
    public struct Contents: Sendable {
        public var manifest: BackupManifest
        public var root: URL
        public var notebook: URL
        public var indexFile: URL?
        public var support: URL?
        public var preferencesPlist: Data?
    }

    /// Read just the manifest, for a confirmation dialog.
    public static func manifest(of zip: URL) throws -> BackupManifest {
        let contents = try extract(zip)
        try? FileManager.default.removeItem(at: contents.root)
        return contents.manifest
    }

    /// Unpack an archive into a temporary directory and validate it.
    public static func extract(_ zip: URL) throws -> Contents {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("foolscap-restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try unzip(zip, to: root)
            let manifestURL = root.appendingPathComponent(manifestName)
            guard fm.fileExists(atPath: manifestURL.path) else { throw BackupError.notABackup }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest: BackupManifest
            do { manifest = try decoder.decode(BackupManifest.self, from: Data(contentsOf: manifestURL)) }
            catch { throw BackupError.unreadable(error.localizedDescription) }
            let notebook = root.appendingPathComponent(notebookDirectory, isDirectory: true)
            guard fm.fileExists(atPath: notebook.path) else { throw BackupError.notABackup }
            let indexFile = root.appendingPathComponent(indexPath)
            let support = root.appendingPathComponent(supportDirectory, isDirectory: true)
            let prefs = root.appendingPathComponent(preferencesName)
            return Contents(manifest: manifest, root: root, notebook: notebook,
                            indexFile: fm.fileExists(atPath: indexFile.path) ? indexFile : nil,
                            support: fm.fileExists(atPath: support.path) ? support : nil,
                            preferencesPlist: fm.fileExists(atPath: prefs.path) ? try? Data(contentsOf: prefs) : nil)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    /// Put the unpacked notebook in place of the one in `notes`: the layout
    /// directories and root-level files are replaced, anything else is left.
    public static func installNotebook(from contents: Contents, into notes: NotesFolder) throws {
        let fm = FileManager.default
        let root = notes.root
        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in items {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir ? NotesFolder.layoutDirectories.contains(item.lastPathComponent) : true {
                    try fm.removeItem(at: item)
                }
            }
        }
        try copyTree(from: contents.notebook, to: root) { $0.lastPathComponent.hasPrefix(".") }
        try notes.ensureLayout()
    }

    /// Replace each top-level entry of the support directory that the backup carries.
    public static func installSupport(from contents: Contents, into supportDirectory: URL) throws {
        guard let source = contents.support else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let dest = supportDirectory.appendingPathComponent(item.lastPathComponent)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: item, to: dest)
        }
    }

    // MARK: Helpers

    /// Recursive copy of regular files, creating directories as needed. Works on
    /// relative paths from the path-based enumerator: URL enumerators resolve
    /// `/var` to `/private/var` while `resolvingSymlinksInPath` strips `/private`
    /// again, so prefix arithmetic on absolute paths is not reliable.
    static func copyTree(from source: URL, to destination: URL, excluding: (URL) -> Bool) throws {
        let fm = FileManager.default
        guard let items = fm.enumerator(atPath: source.path) else { return }
        while let rel = items.nextObject() as? String {
            let url = source.appendingPathComponent(rel)
            let isDirectory = items.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            if excluding(url) {
                if isDirectory { items.skipDescendants() }
                continue
            }
            let dest = destination.appendingPathComponent(rel)
            if isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            } else if items.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: url, to: dest)
            }
        }
    }

    /// `ditto` makes zips Finder and every other tool can open, without a third-party library.
    static func zip(_ directory: URL, to destination: URL) throws {
        try runDitto(["-c", "-k", "--norsrc", directory.path, destination.path])
    }

    static func unzip(_ archive: URL, to directory: URL) throws {
        try runDitto(["-x", "-k", archive.path, directory.path])
    }

    private static func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackupError.toolFailed(String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

public enum BackupInterval: String, CaseIterable, Sendable {
    case off, daily, weekly, monthly

    public var title: String {
        switch self {
        case .off: return "Off"
        case .daily: return "Every day"
        case .weekly: return "Every week"
        case .monthly: return "Every month"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .off: return nil
        case .daily: return 24 * 3600
        case .weekly: return 7 * 24 * 3600
        case .monthly: return 30 * 24 * 3600
        }
    }
}

/// Runs backups and restores for the open library, and the automatic schedule.
/// Settings live in UserDefaults: the backup folder, the interval, how many to keep.
@MainActor
@Observable
public final class BackupManager {
    public static let folderKey = "backupFolder"
    public static let intervalKey = "backupInterval"
    public static let keepKey = "backupKeep"
    public static let lastAutomaticKey = "lastAutomaticBackup"
    public static let lastBackupKey = "lastBackup"
    /// Settings keys that describe this machine, not the notebook: never restored.
    public static let machineKeys: Set<String> = ["notesFolder", folderKey, lastAutomaticKey, lastBackupKey, "NSOSPLastRootDirectory"]

    public private(set) var isRunning = false
    public private(set) var phase: String?
    public private(set) var lastMessage: String?
    public private(set) var lastError: String?
    public private(set) var lastBackup: Date?
    public private(set) var lastFile: URL?
    /// Where automatic backups go and one-off ones start; observable so Settings follows a change.
    public var folder: URL {
        didSet { defaults.set(folder.path, forKey: Self.folderKey) }
    }
    /// Called after a restore so the app can reload sections that cache state.
    public var onRestored: (() -> Void)?

    private let library: NotebookLibrary
    private let supportDirectory: URL
    private let defaults: UserDefaults
    private var timer: Timer?

    public static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foolscap", isDirectory: true)
    }

    public static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Foolscap Backups", isDirectory: true)
    }

    public init(library: NotebookLibrary, supportDirectory: URL = BackupManager.defaultSupportDirectory,
                defaults: UserDefaults = .standard) {
        self.library = library
        self.supportDirectory = supportDirectory
        self.defaults = defaults
        lastBackup = defaults.object(forKey: Self.lastBackupKey) as? Date
        folder = defaults.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultFolder
    }

    // MARK: Settings

    public var interval: BackupInterval {
        get { BackupInterval(rawValue: defaults.string(forKey: Self.intervalKey) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Self.intervalKey); checkSchedule() }
    }

    public var keepCount: Int {
        get { let n = defaults.integer(forKey: Self.keepKey); return n > 0 ? n : 10 }
        set { defaults.set(max(1, newValue), forKey: Self.keepKey) }
    }

    public var lastAutomaticBackup: Date? { defaults.object(forKey: Self.lastAutomaticKey) as? Date }

    /// The next automatic backup, if any is scheduled.
    public var nextAutomaticBackup: Date? {
        guard let seconds = interval.seconds else { return nil }
        return (lastAutomaticBackup ?? .distantPast).addingTimeInterval(seconds)
    }

    // MARK: Backing up

    /// A file name like "Foolscap Backup 2026-09-24 14.32.zip".
    public static func fileName(for date: Date, prefix: String = "Foolscap Backup") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix) \(f.string(from: date)).zip"
    }

    /// The app's settings as a plist, minus what belongs to this machine.
    func preferencesPlist() -> Data? {
        guard let domain = Bundle.main.bundleIdentifier, var prefs = defaults.persistentDomain(forName: domain) else { return nil }
        for key in prefs.keys where Self.machineKeys.contains(key) || key.hasPrefix("NSWindow Frame") { prefs[key] = nil }
        return try? PropertyListSerialization.data(fromPropertyList: prefs, format: .xml, options: 0)
    }

    private var appVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// Write one backup to `url`.
    public func backUp(to url: URL) async throws {
        guard !isRunning else { return }
        isRunning = true
        phase = "Backing up…"
        lastError = nil
        defer { isRunning = false; phase = nil }
        library.flushAll()
        let notes = library.folder
        let index = library.index
        let support = supportDirectory
        let prefs = preferencesPlist()
        let version = appVersion
        do {
            try await Task.detached(priority: .userInitiated) {
                try BackupArchive.create(notes: notes, index: index, supportDirectory: support, preferencesPlist: prefs,
                                         appVersion: version, to: url)
            }.value
            lastBackup = Date()
            lastFile = url
            defaults.set(lastBackup, forKey: Self.lastBackupKey)
            lastMessage = "Backed up to \(url.lastPathComponent)."
        } catch {
            lastError = "Backup failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// A backup into the backup folder, named by date, keeping only the newest few.
    @discardableResult
    public func backUpToFolder(automatic: Bool = false) async -> URL? {
        let url = folder.appendingPathComponent(Self.fileName(for: Date()))
        do {
            try await backUp(to: url)
        } catch {
            return nil
        }
        if automatic { defaults.set(Date(), forKey: Self.lastAutomaticKey) }
        prune()
        return url
    }

    /// Delete the oldest backups in the folder beyond `keepCount`.
    public func prune() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return }
        let ours = items.filter { $0.pathExtension == "zip" && $0.lastPathComponent.hasPrefix("Foolscap") }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
        for old in ours.dropFirst(keepCount) { try? fm.removeItem(at: old) }
    }

    // MARK: Schedule

    /// Start the automatic schedule: a check shortly after launch (so a due
    /// backup runs "when the application is next opened") and hourly after that.
    public func startSchedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSchedule() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkSchedule() }
    }

    public func checkSchedule() {
        guard let due = nextAutomaticBackup, due <= Date(), !isRunning else { return }
        Task { await backUpToFolder(automatic: true) }
    }

    // MARK: Restoring

    /// Replace the notebook, index, support files and settings with a backup's.
    /// A safety copy of the current state goes into the backup folder first.
    public func restore(from zip: URL) async throws {
        guard !isRunning else { return }
        lastError = nil
        let contents: BackupArchive.Contents
        do {
            contents = try await Task.detached(priority: .userInitiated) { try BackupArchive.extract(zip) }.value
        } catch {
            lastError = "Restore failed: \(error.localizedDescription)"
            throw error
        }
        defer { try? FileManager.default.removeItem(at: contents.root) }
        try await backUp(to: folder.appendingPathComponent(Self.fileName(for: Date(), prefix: "Foolscap Before Restore")))

        isRunning = true
        phase = "Restoring…"
        defer { isRunning = false; phase = nil }
        library.suspendForRestore()
        let notes = library.folder
        let index = library.index
        let support = supportDirectory
        var indexProblem: String?
        do {
            indexProblem = try await Task.detached(priority: .userInitiated) { () -> String? in
                try BackupArchive.installNotebook(from: contents, into: notes)
                try BackupArchive.installSupport(from: contents, into: support)
                if let file = contents.indexFile {
                    do { try index.restore(fromFileAt: file.path) } catch { return error.localizedDescription }
                }
                return nil
            }.value
        } catch {
            lastError = "Restore failed part way: \(error.localizedDescription). A safety copy is in \(folder.path)."
            await library.resumeAfterRestore()
            throw error
        }
        if let data = contents.preferencesPlist,
           let prefs = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            for (key, value) in prefs where !Self.machineKeys.contains(key) { defaults.set(value, forKey: key) }
        }
        await library.resumeAfterRestore()
        prune()
        onRestored?()
        let when = DateFormatter.localizedString(from: contents.manifest.createdAt, dateStyle: .medium, timeStyle: .short)
        lastMessage = indexProblem.map { "Restored the backup from \(when); the search index is being rebuilt (\($0))." }
            ?? "Restored the backup from \(when)."
    }
}
