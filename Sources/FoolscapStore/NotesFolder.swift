import Foundation
import FoolscapCore

/// The user-chosen folder that holds the notebook.
public struct NotesFolder: Hashable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var dailyDirectory: URL { root.appendingPathComponent("Daily", isDirectory: true) }
    public var attachmentsDirectory: URL { root.appendingPathComponent("Attachments", isDirectory: true) }

    public func url(for day: DayKey) -> URL { dailyDirectory.appendingPathComponent(day.fileName) }

    /// Tasks created from the Tasks tab or the quick-task panel live here, not in a day.
    public static let tasksFileName = "Tasks.md"
    public var tasksFile: URL { root.appendingPathComponent(NotesFolder.tasksFileName) }
    public static let tasksTemplate = "# Tasks\n\nTasks added from the Tasks tab and the quick-task panel.\n\n"

    /// Kindle Scribe notebooks (PDF + transcript) mirror the Kindle's folders here.
    public static let scribeDirectoryName = "Scribe"
    public var scribeDirectory: URL { root.appendingPathComponent(NotesFolder.scribeDirectoryName, isDirectory: true) }

    /// Kindle highlights: one markdown file per book (with its cover beside it).
    public static let highlightsDirectoryName = "Highlights"
    public var highlightsDirectory: URL { root.appendingPathComponent(NotesFolder.highlightsDirectoryName, isDirectory: true) }

    /// Every markdown file the index should know about: daily notes plus Tasks.md,
    /// the Scribe transcripts and the highlight books when those sections are on.
    public func listIndexableNotes(includingScribe: Bool = false, includingHighlights: Bool = false) -> [(url: URL, day: DayKey?)] {
        var out: [(URL, DayKey?)] = listDailyNotes().filter { !$0.isPlaceholder }.map { ($0.url, $0.day) }
        if FileManager.default.fileExists(atPath: tasksFile.path) { out.append((tasksFile, nil)) }
        if includingScribe { out += listScribeNotes().map { ($0, nil) } }
        if includingHighlights { out += listHighlightNotes().map { ($0, nil) } }
        return out
    }

    /// Book files at the top of `Highlights/`, sorted by name; placeholders and dot files skipped.
    public func listHighlightNotes() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: highlightsDirectory.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".md") }.sorted()
            .map { highlightsDirectory.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Transcripts under `Scribe/`, any depth, sorted by path. iCloud
    /// placeholders and other dot files are skipped.
    public func listScribeNotes() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: scribeDirectory, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in items {
            guard url.pathExtension == "md",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }
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

    /// The directories and root-level files that make up a notebook.
    public static let layoutDirectories = ["Daily", "Attachments", scribeDirectoryName, highlightsDirectoryName]

    /// Every regular file that belongs to the notebook under `root`, with its
    /// path relative to the root: the layout directories at any depth plus
    /// root-level files (Tasks.md). Hidden files and iCloud placeholders are skipped.
    public static func notebookFiles(under root: URL) -> [(url: URL, relativePath: String)] {
        let fm = FileManager.default
        var out: [(URL, String)] = []
        guard let top = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        for name in top where !name.hasPrefix(".") {
            let item = root.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                // Relative paths from the path-based enumerator sidestep /private/var symlink games.
                guard layoutDirectories.contains(name), let items = fm.enumerator(atPath: item.path) else { continue }
                while let rel = items.nextObject() as? String {
                    let leaf = (rel as NSString).lastPathComponent
                    if leaf.hasPrefix(".") {
                        if items.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { items.skipDescendants() }
                        continue
                    }
                    guard items.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                    out.append((item.appendingPathComponent(rel), name + "/" + rel))
                }
            } else {
                out.append((item, name))
            }
        }
        return out.sorted { $0.1 < $1.1 }
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
