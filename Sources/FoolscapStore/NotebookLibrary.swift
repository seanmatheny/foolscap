import AppKit
import FoolscapCore

/// The store's front door: the folder, the index, the open documents and the
/// watcher, plus autosave.
@MainActor
@Observable
public final class NotebookLibrary {
    public private(set) var folder: NotesFolder
    public private(set) var index: SearchIndex
    public private(set) var documents: [String: NoteDocument] = [:]
    /// Days that have a note on disk (or a placeholder), newest last.
    public private(set) var days: [DayKey] = []
    /// Bumped whenever the index changed (rescan, save).
    public private(set) var indexVersion = 0
    public private(set) var lastError: String?

    private var watcher: FolderWatcher?
    private var saveTask: Task<Void, Never>?
    private var rescanTask: Task<Void, Never>?
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(folder: NotesFolder) throws {
        self.folder = folder
        try folder.ensureLayout()
        index = try SearchIndex(path: SearchIndex.defaultPath(for: folder))
        startWatching()
        Task { await rescan() }
    }

    /// Switch to another folder (contents are not moved here; see `migrate`).
    public func open(folder newFolder: NotesFolder) throws {
        flushAll()
        watcher?.stop()
        try newFolder.ensureLayout()
        folder = newFolder
        index = try SearchIndex(path: SearchIndex.defaultPath(for: newFolder))
        documents.removeAll()
        startWatching()
        Task { await rescan() }
    }

    private func startWatching() {
        watcher = FolderWatcher(root: folder.root, watchedSubdirectories: [folder.dailyDirectory]) { [weak self] in
            Task { @MainActor in await self?.externalChange() }
        }
        watcher?.start()
    }

    /// A stream that yields whenever notes or tasks may have changed.
    public var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let id = UUID()
            changeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.changeContinuations[id] = nil }
            }
        }
    }

    private func notifyChanged() {
        indexVersion += 1
        for c in changeContinuations.values { c.yield() }
    }

    // MARK: Documents

    public func document(forDay day: DayKey) -> NoteDocument {
        let url = folder.url(for: day)
        let path = folder.relativePath(of: url)
        if let d = documents[path] { return d }
        let d = NoteDocument(path: path, url: url, day: day)
        d.load(template: "# \(day.longTitle)\n\n")
        documents[path] = d
        return d
    }

    public func document(atRelativePath path: String) -> NoteDocument {
        if let d = documents[path] { return d }
        let url = folder.url(forRelativePath: path)
        let d = NoteDocument(path: path, url: url, day: folder.day(forRelativePath: path))
        d.load(template: path == NotesFolder.tasksFileName ? NotesFolder.tasksTemplate : "")
        documents[path] = d
        return d
    }

    /// The standalone tasks file (created on first use).
    public var tasksDocument: NoteDocument { document(atRelativePath: NotesFolder.tasksFileName) }

    /// Add a task to the Tasks file and save. With `skipIfPresent`, a task whose
    /// content key already appears in the file is not added again (the Scribe
    /// sync relies on this after its own state is lost). Returns whether a line
    /// was written.
    @discardableResult
    public func addStandaloneTask(_ text: String, notes: String? = nil, skipIfPresent: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let doc = tasksDocument
        if skipIfPresent, doc.containsTask(withKey: TaskItem.contentKey(for: trimmed)) { return false }
        doc.appendTaskLine(trimmed, notes: notes)
        flushAll()
        return true
    }

    /// Whether `rescan` indexes the Scribe transcripts under `Scribe/`. Off by
    /// default; the Scribe section switches it on, and switching it off purges
    /// the rows on the next scan.
    public var indexesScribe = false {
        didSet { if oldValue != indexesScribe { Task { await rescan() } } }
    }

    /// Drop documents that are saved and not the given ones, to bound memory.
    public func releaseDocuments(except keep: Set<String>) {
        for (path, doc) in documents where !keep.contains(path) && !doc.isDirty {
            documents[path] = nil
        }
    }

    // MARK: Saving

    /// Call after any edit; saves one second after the last call.
    public func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flushAll()
        }
    }

    public func flushAll() {
        saveTask?.cancel()
        var changed: [NoteDocument] = []
        for doc in documents.values where doc.isDirty {
            do {
                if try doc.save() { changed.append(doc) }
            } catch {
                lastError = "Could not save \(doc.path): \(error.localizedDescription)"
            }
        }
        for doc in changed { indexDocument(doc) }
        if !changed.isEmpty { refreshDays(); notifyChanged() }
    }

    private func indexDocument(_ doc: NoteDocument) {
        guard let stat = FileIO.stat(doc.url) else { return }
        do {
            try index.index(path: doc.path, day: doc.day, text: doc.text, stat: stat, hash: doc.lastSavedHash ?? "")
        } catch {
            lastError = "Index error: \(error.localizedDescription)"
        }
    }

    // MARK: Scanning

    private func externalChange() async {
        for doc in documents.values {
            doc.reloadIfChanged()
            doc.checkConflicts()
        }
        await rescan()
    }

    /// Copy the notebook into a new folder, verify, and switch to it. The old
    /// folder is left untouched.
    public func migrate(to newRoot: URL) async throws {
        flushAll()
        let source = folder
        let target = NotesFolder(root: newRoot)
        try target.ensureLayout()
        try await Task.detached(priority: .userInitiated) {
            try Self.copyNotebookFiles(from: source, to: target)
        }.value
        try open(folder: target)
    }

    /// Synchronous copy with read-back verification (runs off the main actor).
    nonisolated private static func copyNotebookFiles(from source: NotesFolder, to target: NotesFolder) throws {
        let fm = FileManager.default
        for sub in ["Daily", "Attachments", "Scribe"] {
            let from = source.root.appendingPathComponent(sub, isDirectory: true).resolvingSymlinksInPath()
            let to = target.root.appendingPathComponent(sub, isDirectory: true)
            guard let items = fm.enumerator(at: from, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let raw as URL in items {
                let file = raw.resolvingSymlinksInPath()
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      !file.lastPathComponent.hasSuffix(".icloud"), file.path.hasPrefix(from.path) else { continue }
                let rel = file.path.dropFirst(from.path.count + 1)
                let dest = to.appendingPathComponent(String(rel))
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try FileIO.read(file)
                if let existing = try? FileIO.read(dest), FileIO.hash(existing) == FileIO.hash(data) { continue }
                try FileIO.write(data, to: dest)
                guard let back = try? FileIO.read(dest), FileIO.hash(back) == FileIO.hash(data) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
    }

    /// Bring the index up to date with the folder. File IO and hashing run off
    /// the main actor; the index is thread-safe.
    public func rescan(full: Bool = false) async {
        rescanTask?.cancel()
        let folder = self.folder
        let index = self.index
        let includeScribe = indexesScribe
        let task = Task.detached(priority: .utility) { () -> Bool in
            var changed = false
            let known = Dictionary(uniqueKeysWithValues: ((try? index.allNoteRecords()) ?? []).map { ($0.path, $0) })
            var seen = Set<String>()
            for entry in folder.listIndexableNotes(includingScribe: includeScribe) {
                if Task.isCancelled { return changed }
                let path = folder.relativePath(of: entry.url)
                seen.insert(path)
                guard let stat = FileIO.stat(entry.url) else { continue }
                if !full, let k = known[path], k.mtime == stat.mtime, k.size == stat.size { continue }
                guard let data = try? FileIO.read(entry.url) else { continue }
                let hash = FileIO.hash(data)
                if !full, let k = known[path], k.hash == hash {
                    // Touched but identical: refresh the stat only.
                    try? index.index(path: path, day: entry.day, text: String(decoding: data, as: UTF8.self), stat: stat, hash: hash)
                    continue
                }
                try? index.index(path: path, day: entry.day, text: String(decoding: data, as: UTF8.self), stat: stat, hash: hash)
                changed = true
            }
            for path in known.keys where !seen.contains(path) {
                try? index.remove(path: path)
                changed = true
            }
            return changed
        }
        rescanTask = Task { _ = await task.value }
        let changed = await task.value
        refreshDays()
        if changed || full { notifyChanged() }
    }

    public func rebuildIndex() async {
        try? index.removeAll()
        await rescan(full: true)
    }

    private func refreshDays() {
        days = folder.listDailyNotes().map(\.day)
    }
}
