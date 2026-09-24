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
    /// Bumped when every open document was thrown away (folder switch, restore):
    /// editors keyed on it rebuild instead of keeping a stale text storage.
    public private(set) var generation = 0
    public private(set) var lastError: String?
    /// Every tag in the index, most used first; refreshed off the main actor
    /// whenever the index changes, so completion never queries SQLite on a keystroke.
    public private(set) var knownTags: [String] = []

    private var watcher: FolderWatcher?
    private var saveTask: Task<Void, Never>?
    /// The save in progress; the next one waits for it.
    private var saveChain: Task<Void, Never>?
    private let writer = NoteWriter()
    /// The last scan requested; the next one waits for it.
    private var scanChain: Task<Void, Never>?
    /// A scan waiting for the one before it, which new requests can join.
    private var queuedScan: (id: Int, full: Bool, task: Task<Void, Never>)?
    private var scanID = 0
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
        knownTags = []
        generation += 1
        startWatching()
        Task { await rescan() }
    }

    // MARK: Restore

    /// Before a backup is unpacked over the folder: save everything, stop
    /// reacting to file changes and forget the open documents.
    public func suspendForRestore() {
        flushAll()
        watcher?.stop()
        watcher = nil
        documents.removeAll()
    }

    /// After the files (and index) were replaced: watch again, make every
    /// editor reload, and reconcile the index with what is now on disk.
    public func resumeAfterRestore() async {
        generation += 1
        startWatching()
        await rescan()
        await refreshDays()
        notifyChanged()
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
        refreshTags()
    }

    private func refreshTags() {
        let index = self.index
        let version = indexVersion
        Task { [weak self] in
            let tags = await Task.detached(priority: .utility) { (try? index.allTags()) ?? [] }.value
            guard let self, self.indexVersion == version, self.knownTags != tags else { return }
            self.knownTags = tags
        }
    }

    // MARK: Documents

    /// The document for a day, loading in the background if it is new: show it
    /// once `isLoaded` (or `isDownloading`) is set.
    public func document(forDay day: DayKey) -> NoteDocument {
        let url = folder.url(for: day)
        let path = folder.relativePath(of: url)
        if let d = documents[path] { return d }
        let d = NoteDocument(path: path, url: url, day: day)
        documents[path] = d
        Task { await d.loadIfNeeded(template: Self.template(for: day)) }
        return d
    }

    /// The document for a day with its text in place.
    public func loadedDocument(forDay day: DayKey) async -> NoteDocument {
        let d = document(forDay: day)
        await d.loadIfNeeded(template: Self.template(for: day))
        return d
    }

    /// Any note by relative path, with its text in place (for task write-backs).
    public func loadedDocument(atRelativePath path: String) async -> NoteDocument {
        let d: NoteDocument
        if let existing = documents[path] {
            d = existing
        } else {
            d = NoteDocument(path: path, url: folder.url(forRelativePath: path), day: folder.day(forRelativePath: path))
            documents[path] = d
        }
        await d.loadIfNeeded(template: path == NotesFolder.tasksFileName ? NotesFolder.tasksTemplate : (d.day.map(Self.template) ?? ""))
        return d
    }

    private static func template(for day: DayKey) -> String { "# \(day.longTitle)\n\n" }

    /// Add a task to the Tasks file and save. With `skipIfPresent`, a task whose
    /// content key already appears in the file is not added again (the Scribe
    /// sync relies on this after its own state is lost). Returns whether a line
    /// was written.
    @discardableResult
    public func addStandaloneTask(_ text: String, notes: String? = nil, skipIfPresent: Bool = false) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let doc = await loadedDocument(atRelativePath: NotesFolder.tasksFileName)
        if skipIfPresent, doc.containsTask(withKey: TaskItem.contentKey(for: trimmed)) { return false }
        doc.appendTaskLine(trimmed, notes: notes)
        await save()
        return true
    }

    /// Whether `rescan` indexes the Scribe transcripts under `Scribe/`. Off by
    /// default; the Scribe section switches it on, and switching it off purges
    /// the rows on the next scan.
    public var indexesScribe = false {
        didSet { if oldValue != indexesScribe { Task { await rescan() } } }
    }

    /// Drop documents that are saved and not the given ones, to bound memory and
    /// the work each folder change does.
    public func releaseDocuments(except keep: Set<String>) {
        for (path, doc) in documents where !keep.contains(path) && !doc.isDirty && doc.isLoaded {
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
            await self?.save()
        }
    }

    /// Write and index every dirty document off the main actor. Saves run one
    /// after another, so the index sees them in order.
    public func save() async {
        saveTask?.cancel()
        let previous = saveChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performSave()
        }
        saveChain = task
        await task.value
    }

    private func performSave() async {
        let pending = documents.values.compactMap { doc in doc.prepareSave().map { (doc, $0) } }
        guard !pending.isEmpty else { return }
        let outcomes = await writer.write(pending.map(\.1), presenter: watcher, index: index)
        finish(pending, outcomes)
    }

    /// Synchronous save, for app termination, folder switches and restores:
    /// waits for any write in progress, then writes on the calling thread.
    public func flushAll() {
        saveTask?.cancel()
        let pending = documents.values.compactMap { doc in doc.prepareSave().map { (doc, $0) } }
        guard !pending.isEmpty else { return }
        finish(pending, writer.writeNow(pending.map(\.1), presenter: watcher, index: index))
    }

    private func finish(_ pending: [(NoteDocument, SaveSnapshot)], _ outcomes: [NoteWriter.Outcome]) {
        var wrote = false
        for ((doc, snapshot), outcome) in zip(pending, outcomes) {
            switch outcome {
            case .written(let stat, let indexError):
                doc.finishSave(snapshot, stat: stat)
                wrote = true
                if let indexError { lastError = "Index error: \(indexError)" }
            case .failed(let error):
                doc.failSave(snapshot)
                lastError = "Could not save \(doc.path): \(error)"
            }
        }
        if wrote { Task { await refreshDays() }; notifyChanged() }
    }

    // MARK: Scanning

    /// Something changed in the folder. Every open document is checked off the
    /// main actor (a stat first, a coordinated read only when it moved), then
    /// the index catches up.
    private func externalChange() async {
        let docs = Array(documents.values)
        let targets = docs.map { (url: $0.url, known: $0.knownStat, loaded: $0.isLoaded || $0.isDownloading) }
        let presenter = watcher
        let checks = await Task.detached(priority: .utility) {
            targets.map { t -> (DiskRead?, ConflictVersions) in
                let conflicts = ConflictVersions(NSFileVersion.unresolvedConflictVersionsOfItem(at: t.url) ?? [])
                guard t.loaded else { return (nil, conflicts) }
                if let known = t.known, FileIO.stat(t.url) == known { return (nil, conflicts) }
                return (DiskRead.read(t.url, presenter: presenter), conflicts)
            }
        }.value
        for (doc, check) in zip(docs, checks) {
            if let read = check.0 { doc.applyExternal(read) }
            doc.setConflicts(check.1.versions)
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
    /// Covers the note directories and the root-level files such as Tasks.md.
    nonisolated private static func copyNotebookFiles(from source: NotesFolder, to target: NotesFolder) throws {
        let fm = FileManager.default
        for (file, rel) in NotesFolder.notebookFiles(under: source.root) {
            let dest = target.root.appendingPathComponent(rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try FileIO.read(file)
            if let existing = try? FileIO.read(dest), FileIO.hash(existing) == FileIO.hash(data) { continue }
            try FileIO.write(data, to: dest)
            guard let back = try? FileIO.read(dest), FileIO.hash(back) == FileIO.hash(data) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    /// Bring the index up to date with the folder. File IO and hashing run off
    /// the main actor; the index is thread-safe. Scans run one after another,
    /// and a request joins a scan that is queued but not yet started, so a
    /// burst of change notifications costs one extra scan, and every caller
    /// returns with the index and day list current.
    public func rescan(full: Bool = false) async {
        if let queued = queuedScan, queued.full || !full { return await queued.task.value }
        let previous = scanChain
        scanID += 1
        let id = scanID
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if self.queuedScan?.id == id { self.queuedScan = nil }
            await self.performRescan(full: full)
        }
        queuedScan = (id, full, task)
        scanChain = task
        await task.value
    }

    private func performRescan(full: Bool) async {
        let folder = self.folder
        let index = self.index
        let includeScribe = indexesScribe
        let task = Task.detached(priority: .utility) { () -> Bool in
            var changed = false
            let known = Dictionary(uniqueKeysWithValues: ((try? index.allNoteRecords()) ?? []).map { ($0.path, $0) })
            var seen = Set<String>()
            for entry in folder.listIndexableNotes(includingScribe: includeScribe) {
                let path = folder.relativePath(of: entry.url)
                seen.insert(path)
                guard let stat = FileIO.stat(entry.url) else { continue }
                if !full, let k = known[path], k.mtime == stat.mtime, k.size == stat.size { continue }
                guard let data = try? FileIO.read(entry.url) else { continue }
                let hash = FileIO.hash(data)
                if !full, let k = known[path], k.hash == hash {
                    // Touched but identical: refresh the stat only.
                    try? index.updateStat(path: path, stat: stat)
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
        let changed = await task.value
        await refreshDays()
        if changed || full {
            notifyChanged()
        } else if knownTags.isEmpty {
            refreshTags()   // first scan after launch or a folder switch found nothing new
        }
    }

    public func rebuildIndex() async {
        let index = self.index
        await Task.detached(priority: .userInitiated) { try? index.removeAll() }.value
        await rescan(full: true)
    }

    /// The day list, from a directory listing off the main actor.
    private func refreshDays() async {
        let folder = self.folder
        let days = await Task.detached(priority: .utility) { folder.listDailyNotes().map(\.day) }.value
        guard self.folder == folder, self.days != days else { return }
        self.days = days
    }
}

/// Writes and indexes documents on one serial queue, in the order asked, so an
/// async save and a later synchronous flush can never land out of order.
final class NoteWriter: Sendable {
    enum Outcome: Sendable {
        case written(FileIO.Stat?, indexError: String?)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "foolscap.writer", qos: .userInitiated)

    func write(_ snapshots: [SaveSnapshot], presenter: FolderWatcher?, index: SearchIndex) async -> [Outcome] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.perform(snapshots, presenter: presenter, index: index)) }
        }
    }

    func writeNow(_ snapshots: [SaveSnapshot], presenter: FolderWatcher?, index: SearchIndex) -> [Outcome] {
        queue.sync { Self.perform(snapshots, presenter: presenter, index: index) }
    }

    private static func perform(_ snapshots: [SaveSnapshot], presenter: FolderWatcher?, index: SearchIndex) -> [Outcome] {
        snapshots.map { s in
            do {
                try FileIO.write(s.data, to: s.url, presenter: presenter)
            } catch {
                return .failed(error.localizedDescription)
            }
            let stat = FileIO.stat(s.url)
            guard let stat else { return .written(nil, indexError: nil) }
            do {
                try index.index(path: s.path, day: s.day, text: String(decoding: s.data, as: UTF8.self), stat: stat, hash: s.hash)
                return .written(stat, indexError: nil)
            } catch {
                return .written(stat, indexError: error.localizedDescription)
            }
        }
    }
}

/// NSFileVersion is not Sendable; these are only read on the main actor after
/// being looked up elsewhere.
struct ConflictVersions: @unchecked Sendable {
    let versions: [NSFileVersion]
    init(_ versions: [NSFileVersion]) { self.versions = versions }
}
