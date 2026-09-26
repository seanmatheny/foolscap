import Foundation
import GRDB
import FoolscapCore

/// A rebuildable SQLite cache of the notes folder: note metadata, full text
/// (FTS5), tasks and tags. Lives outside the synced folder.
public final class SearchIndex: Sendable {
    public let db: DatabaseQueue

    public init(path: String) throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        db = try DatabaseQueue(path: path, configuration: config)
        try migrate()
    }

    /// In-memory index, for tests.
    public init(inMemory: Void) throws {
        db = try DatabaseQueue()
        try migrate()
    }

    /// Where the index for a given notes folder lives.
    public static func defaultPath(for folder: NotesFolder) -> String {
        let support = AppSupport.directory
        let key = FileIO.hash(Data(folder.root.path.utf8)).prefix(12)
        return support.appendingPathComponent("index-\(key).sqlite").path
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "notes") { t in
                t.primaryKey("path", .text)
                t.column("day", .text).indexed()
                t.column("mtime", .double).notNull()
                t.column("size", .integer).notNull()
                t.column("hash", .text).notNull()
                t.column("title", .text).notNull()
            }
            try db.create(virtualTable: "notes_fts", using: FTS5()) { t in
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("path").notIndexed()
                t.column("title")
                t.column("body")
            }
            try db.create(table: "tasks") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull().indexed()
                t.column("line", .integer).notNull()
                t.column("status", .text).notNull()
                t.column("title", .text).notNull()
                t.column("content_key", .text).notNull()
                t.column("indent", .integer).notNull()
                t.column("day", .text)
                t.column("provider", .text).notNull()
            }
            try db.create(table: "task_tags") { t in
                t.column("task_id", .text).notNull().references("tasks", onDelete: .cascade)
                t.column("tag", .text).notNull().indexed()
            }
            try db.create(table: "link_previews") { t in
                t.primaryKey("url", .text)
                t.column("title", .text)
                t.column("summary", .text)
                t.column("image_path", .text)
                t.column("fetched_at", .double).notNull()
                t.column("failures", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }
        migrator.registerMigration("v2-task-notes") { db in
            try db.alter(table: "tasks") { t in t.add(column: "notes", .text) }
        }
        migrator.registerMigration("v3-note-tags") { db in
            try db.create(table: "note_tags") { t in
                t.column("path", .text).notNull().indexed()
                t.column("tag", .text).notNull().indexed()
            }
            // Existing notes are re-indexed on the next full scan.
            try db.execute(sql: "UPDATE notes SET hash = ''")
        }
        migrator.registerMigration("v4-highlights") { db in
            try db.create(table: "highlight_books") { t in
                t.primaryKey("path", .text)
                t.column("title", .text).notNull()
                t.column("author", .text).notNull().defaults(to: "")
            }
            try db.create(table: "highlights") { t in
                t.primaryKey("id", .text)
                t.column("path", .text).notNull().indexed()
                t.column("line", .integer).notNull()
                t.column("meta_line", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("note", .text)
                t.column("position", .integer).notNull()
                t.column("added", .double)
                t.column("favourite", .boolean).notNull().defaults(to: false)
                t.column("hidden", .boolean).notNull().defaults(to: false)
                t.column("content_key", .text).notNull()
            }
            try db.create(table: "highlight_tags") { t in
                t.column("highlight_id", .text).notNull().references("highlights", onDelete: .cascade)
                t.column("tag", .text).notNull().indexed()
            }
            // Book files indexed before this version (a restored backup) are re-read on the next scan.
            try db.execute(sql: "UPDATE notes SET hash = '' WHERE path LIKE 'Highlights/%'")
        }
        try migrator.migrate(db)
    }

    // MARK: - Backup

    /// Copy the whole database to a file (SQLite's online backup API, so it is
    /// consistent even while the index is in use).
    public func backup(toFileAt path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let dest = try DatabaseQueue(path: path)
        try db.backup(to: dest)
        try dest.close()
    }

    /// Replace this database's contents with a backed-up file, then bring the
    /// schema up to date. On any failure the index is emptied instead; it is
    /// only a cache and the next scan rebuilds it.
    public func restore(fromFileAt path: String) throws {
        do {
            let source = try DatabaseQueue(path: path)
            try source.backup(to: db)
            try source.close()
            try migrate()
        } catch {
            try removeAll()
            throw error
        }
    }

    // MARK: - Notes

    public struct NoteRecord: Equatable, Sendable {
        public var path: String
        public var day: String?
        public var mtime: Double
        public var size: Int
        public var hash: String
        public var title: String
    }

    public func noteRecord(path: String) throws -> NoteRecord? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM notes WHERE path = ?", arguments: [path]).map(Self.record)
        }
    }

    public func allNoteRecords() throws -> [NoteRecord] {
        try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM notes ORDER BY path").map(Self.record) }
    }

    private static func record(_ r: Row) -> NoteRecord {
        NoteRecord(path: r["path"], day: r["day"], mtime: r["mtime"], size: r["size"], hash: r["hash"], title: r["title"])
    }

    /// Replace everything the index knows about one note.
    public func index(path: String, day: DayKey?, text: String, stat: FileIO.Stat, hash: String) throws {
        let parsed = NoteParser.parse(text, path: path, day: day)
        let body = NoteParser.indexableBody(text)
        let highlights = Self.isHighlightsFile(path) ? HighlightParser.parse(text, path: path) : nil
        try db.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM notes_fts WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM tasks WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM note_tags WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM highlights WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM highlight_books WHERE path = ?", arguments: [path])
            if let highlights {
                try db.execute(sql: "INSERT INTO highlight_books (path, title, author) VALUES (?,?,?)",
                               arguments: [path, highlights.title, highlights.author])
                for h in highlights.items {
                    try db.execute(sql: """
                        INSERT INTO highlights (id, path, line, meta_line, text, note, position, added, favourite, hidden, content_key)
                        VALUES (?,?,?,?,?,?,?,?,?,?,?)
                        """, arguments: [h.id, h.path, h.line, h.metaLine, h.paragraphs.joined(separator: "\n\n"), h.note, h.meta.position,
                                         h.meta.added?.timeIntervalSince1970, h.meta.isFavourite, h.meta.isHidden, h.contentKey])
                    for tag in h.meta.tags {
                        try db.execute(sql: "INSERT INTO highlight_tags (highlight_id, tag) VALUES (?,?)", arguments: [h.id, tag])
                    }
                }
            }
            for tag in parsed.tags {
                try db.execute(sql: "INSERT INTO note_tags (path, tag) VALUES (?,?)", arguments: [path, tag])
            }
            try db.execute(sql: "INSERT INTO notes (path, day, mtime, size, hash, title) VALUES (?,?,?,?,?,?)",
                           arguments: [path, day?.string, stat.mtime, stat.size, hash, parsed.title])
            try db.execute(sql: "INSERT INTO notes_fts (path, title, body) VALUES (?,?,?)",
                           arguments: [path, parsed.title, body])
            for t in parsed.tasks {
                try db.execute(sql: """
                    INSERT INTO tasks (id, path, line, status, title, content_key, indent, day, provider, notes)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [t.id, t.source.path, t.source.line, t.status.rawValue, t.title, t.contentKey,
                                     t.indent, t.source.day, t.providerID, t.notes])
                for tag in t.tags {
                    try db.execute(sql: "INSERT INTO task_tags (task_id, tag) VALUES (?,?)", arguments: [t.id, tag])
                }
            }
        }
    }

    /// A file was touched but its bytes are unchanged: keep the rows, refresh the stat.
    public func updateStat(path: String, stat: FileIO.Stat) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE notes SET mtime = ?, size = ? WHERE path = ?", arguments: [stat.mtime, stat.size, path])
        }
    }

    public func remove(path: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM notes_fts WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM tasks WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM note_tags WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM highlights WHERE path = ?", arguments: [path])
            try db.execute(sql: "DELETE FROM highlight_books WHERE path = ?", arguments: [path])
        }
    }

    public func removeAll() throws {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM notes; DELETE FROM notes_fts; DELETE FROM tasks; DELETE FROM note_tags;
                DELETE FROM highlights; DELETE FROM highlight_books;
                """)
        }
    }

    // MARK: - Highlights

    /// Book files live at the top of `Highlights/`; their blockquotes are highlights.
    public static func isHighlightsFile(_ path: String) -> Bool {
        path.hasPrefix(NotesFolder.highlightsDirectoryName + "/") && path.hasSuffix(".md")
    }

    public struct HighlightBookRecord: Equatable, Sendable, Identifiable {
        public var path: String
        public var title: String
        public var author: String
        public var count: Int
        public var hiddenCount: Int
        public var id: String { path }
    }

    /// Every highlight (or one book's), in reading order.
    public func highlights(inBook path: String? = nil) throws -> [HighlightItem] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT h.*, b.title AS book_title, b.author AS book_author
                FROM highlights h LEFT JOIN highlight_books b ON b.path = h.path
                \(path == nil ? "" : "WHERE h.path = ?") ORDER BY h.path, h.position, h.line
                """, arguments: path.map { [$0] } ?? [])
            let tagRows = try Row.fetchAll(db, sql: "SELECT highlight_id, tag FROM highlight_tags")
            var tags: [String: [String]] = [:]
            for r in tagRows { tags[r["highlight_id"], default: []].append(r["tag"]) }
            return rows.map { r in
                let text: String = r["text"]
                let added: Double? = r["added"]
                return HighlightItem(path: r["path"], line: r["line"], metaLine: r["meta_line"],
                                     bookTitle: r["book_title"] ?? "", bookAuthor: r["book_author"] ?? "",
                                     paragraphs: text.components(separatedBy: "\n\n"), note: r["note"],
                                     meta: HighlightMeta(position: r["position"], added: added.map { Date(timeIntervalSince1970: $0) },
                                                         tags: tags[r["id"]] ?? [], isFavourite: r["favourite"], isHidden: r["hidden"]))
            }
        }
    }

    /// Every book with highlights, by title.
    public func highlightBooks() throws -> [HighlightBookRecord] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT b.path AS path, b.title AS title, b.author AS author,
                       COUNT(h.id) AS count, COALESCE(SUM(h.hidden), 0) AS hidden_count
                FROM highlight_books b LEFT JOIN highlights h ON h.path = b.path
                GROUP BY b.path ORDER BY b.title COLLATE NOCASE, b.path
                """).map {
                HighlightBookRecord(path: $0["path"], title: $0["title"], author: $0["author"], count: $0["count"], hiddenCount: $0["hidden_count"])
            }
        }
    }

    // MARK: - Tags

    /// Every tag used anywhere (notes and tasks), most used first.
    public func allTags() throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT tag FROM (SELECT tag FROM note_tags UNION ALL SELECT tag FROM task_tags)
                GROUP BY tag ORDER BY COUNT(*) DESC, tag
                """)
        }
    }

    /// Paths of notes carrying every complete tag, and (while one is being typed)
    /// at least one tag starting with the partial text.
    func paths(matching query: SearchQuery, db: Database) throws -> Set<String> {
        var result: Set<String>? = nil
        if !query.tags.isEmpty {
            let marks = Array(repeating: "?", count: query.tags.count).joined(separator: ",")
            result = Set(try String.fetchAll(db, sql: """
                SELECT path FROM note_tags WHERE tag IN (\(marks)) GROUP BY path HAVING COUNT(DISTINCT tag) = ?
                """, arguments: StatementArguments(query.tags + [query.tags.count])))
        }
        if let partial = query.pendingTag, !partial.isEmpty {
            let prefixed = Set(try String.fetchAll(db, sql: "SELECT DISTINCT path FROM note_tags WHERE tag LIKE ?",
                                                   arguments: [partial.replacingOccurrences(of: "%", with: "") + "%"]))
            result = result.map { $0.intersection(prefixed) } ?? prefixed
        }
        return result ?? []
    }

    /// Does a task's own tag list satisfy the query's tag constraints?
    private static func taskTagsMatch(_ tags: [String], _ query: SearchQuery) -> Bool {
        guard query.tags.allSatisfy({ tags.contains($0) }) else { return false }
        if let partial = query.pendingTag, !partial.isEmpty { return tags.contains { $0.hasPrefix(partial) } }
        return true
    }

    // MARK: - Tasks

    public func tasks(provider: String? = nil) throws -> [TaskItem] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM tasks \(provider == nil ? "" : "WHERE provider = ?") ORDER BY day DESC, path, line
                """, arguments: provider.map { [$0] } ?? [])
            let tagRows = try Row.fetchAll(db, sql: "SELECT task_id, tag FROM task_tags")
            var tags: [String: [String]] = [:]
            for r in tagRows { tags[r["task_id"], default: []].append(r["tag"]) }
            return rows.map { r in
                TaskItem(providerID: r["provider"], title: r["title"], status: TaskStatus(rawValue: r["status"]) ?? .notStarted,
                         tags: tags[r["id"]] ?? [], indent: r["indent"],
                         source: TaskSource(path: r["path"], line: r["line"], day: r["day"]), notes: r["notes"])
            }
        }
    }

    public func tags() throws -> [String] {
        try db.read { db in
            try String.fetchAll(db, sql: "SELECT tag FROM task_tags GROUP BY tag ORDER BY COUNT(*) DESC, tag")
        }
    }

    // MARK: - Search

    /// Which notes a search covers, by path prefix. Sections that share the
    /// index (Daily Notes, Scribe) use disjoint scopes so a hit is reported once.
    public enum PathScope: Equatable, Sendable {
        case all
        case under(String)
        case notUnder(String)
        /// Everything outside several prefixes (Daily Notes leave out every other section's folder).
        case notUnderAny([String])

        func includes(_ path: String) -> Bool {
            switch self {
            case .all: return true
            case .under(let p): return path.hasPrefix(p)
            case .notUnder(let p): return !path.hasPrefix(p)
            case .notUnderAny(let ps): return !ps.contains { path.hasPrefix($0) }
            }
        }

        /// An SQL condition on `column` plus its argument (empty for `.all`).
        func sql(column: String) -> (clause: String, arguments: [any DatabaseValueConvertible]) {
            func pattern(_ p: String) -> String {
                p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
            }
            switch self {
            case .all: return ("1", [])
            case .under(let p): return ("\(column) LIKE ? ESCAPE '\\'", [pattern(p)])
            case .notUnder(let p): return ("\(column) NOT LIKE ? ESCAPE '\\'", [pattern(p)])
            case .notUnderAny(let ps):
                guard !ps.isEmpty else { return ("1", []) }
                return (ps.map { _ in "\(column) NOT LIKE ? ESCAPE '\\'" }.joined(separator: " AND "), ps.map(pattern))
            }
        }
    }

    public struct NoteHit: Equatable, Sendable {
        public var path: String
        public var day: String?
        public var title: String
        public var snippet: String
    }

    /// Turn free text into an FTS5 query that never throws on odd input:
    /// each word becomes a quoted prefix term.
    public static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
    }

    public func searchNotes(_ text: String, limit: Int = 50, scope: PathScope = .all) throws -> [NoteHit] {
        let query = SearchQuery(text)
        let q = Self.ftsQuery(query.wordText)
        guard !q.isEmpty || query.hasTagFilter else { return [] }
        let scoped = scope.sql(column: "n.path")
        return try db.read { db in
            let tagged = try paths(matching: query, db: db)
            if q.isEmpty {
                // Tags only: every note carrying them, newest first, first line as the snippet.
                let marks = Array(repeating: "?", count: tagged.count).joined(separator: ",")
                guard !tagged.isEmpty else { return [] }
                var arguments: [any DatabaseValueConvertible] = Array(tagged)
                arguments += scoped.arguments
                arguments.append(limit)
                return try Row.fetchAll(db, sql: """
                    SELECT n.path AS path, n.day AS day, n.title AS title, substr(f.body, 1, 140) AS snippet
                    FROM notes n JOIN notes_fts f ON f.path = n.path
                    WHERE n.path IN (\(marks)) AND \(scoped.clause) ORDER BY n.day DESC LIMIT ?
                    """, arguments: StatementArguments(arguments))
                .map { NoteHit(path: $0["path"], day: $0["day"], title: $0["title"], snippet: $0["snippet"]) }
            }
            var arguments: [any DatabaseValueConvertible] = [q]
            arguments += scoped.arguments
            arguments.append(query.hasTagFilter ? limit * 4 : limit)
            let hits = try Row.fetchAll(db, sql: """
                SELECT n.path AS path, n.day AS day, n.title AS title,
                       snippet(notes_fts, 2, '\u{1}', '\u{2}', '…', 14) AS snippet
                FROM notes_fts JOIN notes n ON n.path = notes_fts.path
                WHERE notes_fts MATCH ? AND \(scoped.clause) ORDER BY bm25(notes_fts), n.day DESC LIMIT ?
                """, arguments: StatementArguments(arguments))
            .map { NoteHit(path: $0["path"], day: $0["day"], title: $0["title"], snippet: $0["snippet"]) }
            return query.hasTagFilter ? Array(hits.filter { tagged.contains($0.path) }.prefix(limit)) : hits
        }
    }

    public func searchTasks(_ text: String, limit: Int = 50, scope: PathScope = .all) throws -> [TaskItem] {
        let query = SearchQuery(text)
        let words = query.words.map { $0.lowercased() }
        guard !words.isEmpty || query.hasTagFilter else { return [] }
        let tagged = try db.read { db in try paths(matching: query, db: db) }
        return try tasks().filter { t in
            guard scope.includes(t.source.path) else { return false }
            let hay = t.title.lowercased()
            guard words.allSatisfy({ hay.contains($0) }) else { return false }
            guard query.hasTagFilter else { return true }
            return Self.taskTagsMatch(t.tags, query) || tagged.contains(t.source.path)
        }.prefix(limit).map { $0 }
    }

    // MARK: - Link previews

    public struct LinkPreviewRecord: Equatable, Sendable {
        public var url: String
        public var title: String?
        public var summary: String?
        public var imagePath: String?
        public var fetchedAt: Double
        public var failures: Int
    }

    public func linkPreview(for url: String) throws -> LinkPreviewRecord? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM link_previews WHERE url = ?", arguments: [url]).map {
                LinkPreviewRecord(url: $0["url"], title: $0["title"], summary: $0["summary"], imagePath: $0["image_path"],
                                  fetchedAt: $0["fetched_at"], failures: $0["failures"])
            }
        }
    }

    public func saveLinkPreview(_ r: LinkPreviewRecord) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO link_previews (url, title, summary, image_path, fetched_at, failures)
                VALUES (?,?,?,?,?,?)
                """, arguments: [r.url, r.title, r.summary, r.imagePath, r.fetchedAt, r.failures])
        }
    }
}
