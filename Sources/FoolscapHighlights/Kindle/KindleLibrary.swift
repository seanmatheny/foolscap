import Foundation
import GRDB

/// The Kindle app's library: `BookData.sqlite` in its container. Read in
/// place, read-only: the database is in WAL mode and the app leaves recent
/// rows in the WAL for days, so a copy of the main file alone would be stale.
public enum KindleLibrary {
    /// The Mac App Store Kindle app (bundle id com.amazon.Lassen).
    public static var defaultDataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.amazon.Lassen/Data", isDirectory: true)
    }

    public static func databaseURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("Library/Protected/BookData.sqlite")
    }

    /// Whether the Kindle app has a library on this Mac at all.
    public static func isInstalled(dataDirectory: URL = defaultDataDirectory) -> Bool {
        FileManager.default.fileExists(atPath: dataDirectory.path)
    }

    public static func books(dataDirectory: URL = defaultDataDirectory) throws -> [KindleBook] {
        let url = databaseURL(dataDirectory: dataDirectory)
        let db = try openReadOnly(url)
        let rows: [Row]
        do {
            rows = try db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ZBOOKID, ZDISPLAYTITLE, ZPATH, ZMIMETYPE, ZRAWMAXPOSITION, ZRAWISDICTIONARY, ZRAWBOOKSTATE, ZSYNCMETADATAATTRIBUTES
                    FROM ZBOOK WHERE ZDISPLAYTITLE IS NOT NULL AND ZPATH IS NOT NULL
                    """)
            }
        } catch {
            throw Self.failure(for: error, at: url)
        }
        return rows.compactMap { row -> KindleBook? in
            guard let rawID: String = row["ZBOOKID"], let displayTitle: String = row["ZDISPLAYTITLE"], let path: String = row["ZPATH"] else { return nil }
            let metadata = SyncMetadata(archive: row["ZSYNCMETADATAATTRIBUTES"])
            let (title, author) = cleanTitleAndAuthor(metadata.title?.isEmpty == false ? metadata.title! : displayTitle, metadata.author ?? "")
            let fileURL = dataDirectory.appendingPathComponent(path)
            let state: Int = row["ZRAWBOOKSTATE"] ?? 0
            return KindleBook(id: bookID(rawID), title: title, author: author,
                              format: KindleFormat(mimeType: row["ZMIMETYPE"] ?? ""), fileURL: fileURL,
                              maxPosition: row["ZRAWMAXPOSITION"],
                              isDictionary: (row["ZRAWISDICTIONARY"] ?? 0) != 0,
                              isDownloaded: state == 3 && FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    /// Read-only, seeing the WAL; the busy timeout covers the app writing.
    static func openReadOnly(_ url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(2)
        do {
            return try DatabaseQueue(path: url.path, configuration: config)
        } catch {
            throw failure(for: error, at: url)
        }
    }

    /// The user-facing reason a database could not be read: missing, or protected.
    static func failure(for error: Error, at url: URL) -> ExtractionFailure {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            return .unreadable("\(url.lastPathComponent) was not found; is the Kindle app installed and signed in?")
        }
        if !fm.isReadableFile(atPath: url.path) {
            return .accessDenied(Self.accessDeniedMessage)
        }
        if let dbError = error as? DatabaseError, dbError.resultCode == .SQLITE_CANTOPEN || dbError.resultCode == .SQLITE_AUTH {
            return .accessDenied(Self.accessDeniedMessage)
        }
        return .unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
    }

    static let accessDeniedMessage = "macOS keeps other apps' data private. Under Privacy & Security ▸ Files & Folders, turn on Kindle for Foolscap (or add Foolscap under Full Disk Access), then import again."

    /// "A:<id>-0" → "<id>"; the first part of every annotation's dataset id.
    static func bookID(_ raw: String) -> String {
        var id = Substring(raw)
        if id.hasPrefix("A:") { id = id.dropFirst(2) }
        if id.hasSuffix("-0") { id = id.dropLast(2) }
        return String(id)
    }

    /// Sideloaded books arrive with junk tails: "Title -- Author -- 2025 -- ... Anna's Archive".
    static func cleanTitle(_ title: String) -> String {
        let cut = title.replacingOccurrences(of: #"\s*--.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cut.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : cut
    }

    /// Sideloaded documents are named after their files ("Demon_Copperhead_-_Barbara_Kingsolver",
    /// "Stalin_ The Court of the Red Tsar", "Capital And Ideology - Thomas Piketty") and credit
    /// whoever sent them as the author. Undo what can be undone.
    static func cleanTitleAndAuthor(_ rawTitle: String, _ rawAuthor: String, user: String = NSFullUserName()) -> (title: String, author: String) {
        var title = cleanTitle(rawTitle)
        if !title.contains(" "), title.contains("_") { title = title.replacingOccurrences(of: "_", with: " ") }
        title = title.replacingOccurrences(of: "_ ", with: ": ")
        title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var author = rawAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorIsSender = !user.isEmpty && author.caseInsensitiveCompare(user) == .orderedSame
        // "Title - Author Name" tails: the author when it agrees or when the Kindle only knew the sender.
        if let range = title.range(of: #"\s+-\s+([^-]+)$"#, options: .regularExpression) {
            let tail = String(title[range]).replacingOccurrences(of: #"^\s+-\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let looksLikeName = tail.split(separator: " ").count <= 4 && tail.first?.isUppercase == true
            if tail.caseInsensitiveCompare(author) == .orderedSame || ((author.isEmpty || authorIsSender) && looksLikeName) {
                author = tail
                title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        } else if authorIsSender {
            author = ""
        }
        return (title, author)
    }
}

/// `ZSYNCMETADATAATTRIBUTES`: an NSKeyedArchiver plist whose root is the
/// app's own `SyncMetadataAttributes` (an `attributes` dictionary). The
/// author lives only here; the author columns are opaque blobs.
struct SyncMetadata {
    var title: String?
    var author: String?

    init(archive: Data?) {
        guard let archive, let attributes = Self.attributes(from: archive) else { return }
        title = attributes["title"] as? String
        author = Self.authorName(attributes["authors"])
    }

    private static func attributes(from data: Data) -> [String: Any]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        unarchiver.setClass(StandIn.self, forClassName: "SyncMetadataAttributes")
        let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? StandIn
        unarchiver.finishDecoding()
        return root?.attributes
    }

    /// `{"author": "Name"}`, `["Name", …]` or `[{"author": …}, …]`.
    private static func authorName(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let d as [String: Any]: return authorName(d["author"] ?? d.values.first)
        case let list as [Any]:
            let names = list.compactMap(authorName)
            return names.isEmpty ? nil : names.joined(separator: ", ")
        default: return nil
        }
    }

    @objc(FoolscapSyncMetadataStandIn)
    final class StandIn: NSObject, NSCoding {
        let attributes: [String: Any]
        init?(coder: NSCoder) {
            attributes = coder.decodeObject(forKey: "attributes") as? [String: Any] ?? [:]
            super.init()
        }
        func encode(with coder: NSCoder) {}
    }
}
