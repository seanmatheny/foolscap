import Foundation
import FoolscapCore

/// The user-chosen folder that holds the notebook.
public struct NotesFolder: Hashable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var dailyDirectory: URL { root.appendingPathComponent("Daily", isDirectory: true) }
    public var attachmentsDirectory: URL { root.appendingPathComponent("Attachments", isDirectory: true) }

    public func url(for day: DayKey) -> URL { dailyDirectory.appendingPathComponent(day.fileName) }
    public func attachmentsDirectory(for day: DayKey) -> URL {
        attachmentsDirectory.appendingPathComponent(day.string, isDirectory: true)
    }

    /// Path relative to the root, used as the note's identity in the index.
    public func relativePath(of url: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(rootPath) ? String(p.dropFirst(rootPath.count)) : p
    }

    public func url(forRelativePath path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    public func day(forRelativePath path: String) -> DayKey? {
        guard path.hasPrefix("Daily/") else { return nil }
        return DayKey.fromFileName(String(path.dropFirst("Daily/".count)))
    }

    public func ensureLayout() throws {
        let fm = FileManager.default
        for dir in [root, dailyDirectory, attachmentsDirectory] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// The default location: iCloud Drive when it exists, else ~/Documents.
    public static var defaultRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        if FileManager.default.fileExists(atPath: icloud.path) {
            return icloud.appendingPathComponent("Foolscap", isDirectory: true)
        }
        return home.appendingPathComponent("Documents/Foolscap", isDirectory: true)
    }

    /// A daily note present on disk, or an iCloud placeholder not yet downloaded.
    public struct DailyEntry: Hashable, Sendable {
        public var day: DayKey
        public var url: URL
        public var isPlaceholder: Bool
    }

    public func listDailyNotes() -> [DailyEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dailyDirectory.path) else { return [] }
        var out: [DailyEntry] = []
        for name in names {
            if let day = DayKey.fromFileName(name) {
                out.append(DailyEntry(day: day, url: dailyDirectory.appendingPathComponent(name), isPlaceholder: false))
            } else if let real = ICloudPlaceholders.realName(forPlaceholder: name), let day = DayKey.fromFileName(real) {
                out.append(DailyEntry(day: day, url: dailyDirectory.appendingPathComponent(real), isPlaceholder: true))
            }
        }
        return out.sorted { $0.day < $1.day }
    }
}

public enum ICloudPlaceholders {
    /// `.Foo.md.icloud` → `Foo.md`
    public static func realName(forPlaceholder name: String) -> String? {
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }

    public static func isPlaceholder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + name + ".icloud")
        return !FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: placeholder.path)
    }

    public static func startDownload(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
