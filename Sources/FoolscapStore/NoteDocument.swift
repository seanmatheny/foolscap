import AppKit
import FoolscapCore

/// One open note. The `NSTextStorage` is the single in-memory copy of the file:
/// the editor edits it directly and task write-backs edit it too, so the two
/// can never disagree.
@MainActor
@Observable
public final class NoteDocument: Identifiable {
    public let path: String
    public let url: URL
    public let day: DayKey?
    public let textStorage = NSTextStorage()
    public private(set) var isDirty = false
    public private(set) var lastSavedHash: String?
    public private(set) var loadError: Error?
    /// True while iCloud is still downloading the file.
    public private(set) var isDownloading = false
    /// Set when the file changed on disk while we had unsaved edits.
    public var externalChangePending = false
    /// iCloud conflict versions waiting for a decision.
    public private(set) var conflictVersions: [NSFileVersion] = []
    public var blockMap: BlockMap = BlockMap(lines: [])
    /// Bumped on every edit so views can observe cheaply.
    public private(set) var editCount = 0
    /// The text a new file starts with; saving is skipped while the text still equals it.
    private var templateText = ""

    nonisolated public var id: String { path }
    public var text: String { textStorage.string }

    // Removed in deinit; nonisolated(unsafe) because deinit is not on the main actor.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    public init(path: String, url: URL, day: DayKey?) {
        self.path = path
        self.url = url
        self.day = day
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                                          object: textStorage, queue: nil) { [weak self] note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { self?.didEdit() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func didEdit() {
        isDirty = true
        editCount += 1
        blockMap = BlockMap.scan(textStorage.string)
    }

    // MARK: Loading and saving

    /// False until the file's text is in the storage (or it was found missing
    /// and the template used). An unloaded document must not be edited.
    public private(set) var isLoaded = false
    private var loadTask: Task<Void, Never>?
    /// The file's stat when we last read or wrote it, so a change notification
    /// can skip the coordinated read of a file that did not change.
    private(set) var knownStat: FileIO.Stat?
    /// Bumped by every save; an async save that finishes after a newer one
    /// started does not overwrite the newer one's bookkeeping.
    private var saveToken = 0
    /// Hash of a write in flight: on disk already, not yet in `lastSavedHash`.
    private var pendingSaveHash: String?

    /// Synchronous load, for tests and callers already off the hot path.
    public func load(template: String = "") {
        apply(DiskRead.read(url), template: template)
    }

    /// Load off the main actor; returns once the text is in place. Concurrent
    /// callers share one read.
    public func loadIfNeeded(template: String = "") async {
        if isLoaded { return }
        if let loadTask { return await loadTask.value }
        let url = self.url
        let task = Task { [weak self] in
            let read = await Task.detached(priority: .userInitiated) { DiskRead.read(url) }.value
            guard let self, !self.isLoaded else { return }
            self.apply(read, template: template)
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func apply(_ read: DiskRead, template: String) {
        if read.isPlaceholder {
            isDownloading = true
            ICloudPlaceholders.startDownload(url)
            return
        }
        isDownloading = false
        templateText = template
        setText(String(decoding: read.data ?? Data(template.utf8), as: UTF8.self))
        lastSavedHash = read.data.map(FileIO.hash)
        knownStat = read.stat
        isLoaded = true
    }

    /// Replace the whole text without marking the document dirty.
    public func setText(_ text: String) {
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        textStorage.endEditing()
        blockMap = BlockMap.scan(text)
        isDirty = false
        editCount += 1
    }

    /// Reload from disk if the on-disk content differs. Returns true when the
    /// text was replaced. Synchronous; the library's change handler reads off
    /// the main actor and calls `applyExternal` instead.
    @discardableResult
    public func reloadIfChanged() -> Bool {
        guard !isDownloading || !ICloudPlaceholders.isPlaceholder(url) else { return false }
        return applyExternal(DiskRead.read(url))
    }

    /// Take what the library read from disk after a change notification.
    /// Returns true when the text was replaced.
    @discardableResult
    public func applyExternal(_ read: DiskRead) -> Bool {
        guard !read.isPlaceholder, let data = read.data else { return false }
        knownStat = read.stat
        let hash = FileIO.hash(data)
        guard hash != lastSavedHash, hash != pendingSaveHash else { return false }
        if isDirty {
            externalChangePending = true
            return false
        }
        isDownloading = false
        setText(String(decoding: data, as: UTF8.self))
        lastSavedHash = hash
        isLoaded = true
        return true
    }

    /// The text to write, taken on the main actor so the write itself can
    /// happen elsewhere. Nil when there is nothing to save.
    public func prepareSave() -> SaveSnapshot? {
        guard isDirty, isLoaded else { return nil }
        let data = Data(textStorage.string.utf8)
        let hash = FileIO.hash(data)
        if hash == lastSavedHash { isDirty = false; return nil }
        if lastSavedHash == nil && textStorage.string == templateText { return nil }
        saveToken += 1
        pendingSaveHash = hash
        return SaveSnapshot(path: path, url: url, day: day, data: data, hash: hash, token: saveToken, editCount: editCount)
    }

    /// Record a finished write. Edits made while it was in flight keep the
    /// document dirty.
    public func finishSave(_ snapshot: SaveSnapshot, stat: FileIO.Stat?) {
        guard snapshot.token == saveToken else { return }
        pendingSaveHash = nil
        lastSavedHash = snapshot.hash
        knownStat = stat
        externalChangePending = false
        if editCount == snapshot.editCount { isDirty = false }
    }

    public func failSave(_ snapshot: SaveSnapshot) {
        if snapshot.token == saveToken { pendingSaveHash = nil }
    }

    /// Write to disk if there are unsaved changes whose bytes differ from the
    /// last write. Returns true when a write happened. Synchronous: the
    /// library's async `save()` is the everyday path.
    @discardableResult
    public func save(presenter: NSFilePresenter? = nil) throws -> Bool {
        guard let snapshot = prepareSave() else { return false }
        do { try FileIO.write(snapshot.data, to: url, presenter: presenter) } catch { failSave(snapshot); throw error }
        finishSave(snapshot, stat: FileIO.stat(url))
        return true
    }

    // MARK: iCloud conflicts

    /// Look for unresolved conflict versions (iCloud writes them when two
    /// devices edited the same file).
    public func checkConflicts() {
        conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    }

    /// Conflict versions looked up off the main actor.
    public func setConflicts(_ versions: [NSFileVersion]) {
        if versions.map(\.url) != conflictVersions.map(\.url) { conflictVersions = versions }
    }

    public enum ConflictResolution { case keepMine, takeTheirs, keepBoth }

    public func resolveConflicts(_ resolution: ConflictResolution) throws {
        let versions = conflictVersions
        guard !versions.isEmpty else { return }
        switch resolution {
        case .keepMine:
            break
        case .takeTheirs:
            if let latest = versions.max(by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }),
               let data = try? Data(contentsOf: latest.url) {
                setText(String(decoding: data, as: UTF8.self))
                isDirty = true
            }
        case .keepBoth:
            var text = textStorage.string
            for v in versions {
                guard let data = try? Data(contentsOf: v.url) else { continue }
                let theirs = String(decoding: data, as: UTF8.self)
                if theirs != text {
                    let stamp = v.modificationDate.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "other device"
                    text += (text.hasSuffix("\n") ? "" : "\n") + "\n---\n\n<!-- conflicting copy from \(stamp) -->\n" + theirs
                }
            }
            setText(text)
            isDirty = true
        }
        try NSFileVersion.removeOtherVersionsOfItem(at: url)
        for v in versions { v.isResolved = true }
        conflictVersions = []
    }

    /// Discard local edits and take the on-disk version.
    public func takeExternalVersion() {
        isDirty = false
        externalChangePending = false
        reloadIfChanged()
    }

    /// Keep local edits: they will overwrite the external version on next save.
    public func keepLocalVersion() {
        externalChangePending = false
        isDirty = true
    }

    /// Write to disk if there are unsaved changes whose bytes differ from the
    /// last write. Returns true when a write happened.
    @discardableResult
    public func save() throws -> Bool {
        guard isDirty else { return false }
        let data = Data(textStorage.string.utf8)
        let hash = FileIO.hash(data)
        if hash == lastSavedHash { isDirty = false; return false }
        if lastSavedHash == nil && textStorage.string == templateText { return false }
        try FileIO.write(data, to: url)
        lastSavedHash = hash
        isDirty = false
        externalChangePending = false
        return true
    }

    // MARK: Tasks

    /// Change the status mark of the task on `line`, verifying that the line
    /// still holds the expected task (by content key); if the line moved, find
    /// a unique line with the same key.
    public func replaceTaskMark(line: Int, expectedKey: String, with status: TaskStatus) throws {
        let t = try locateTask(line: line, expectedKey: expectedKey)
        guard let replaced = TaskLineParser.replacingStatus(in: t.text, with: status) else { throw TaskWriteError.moved }
        textStorage.replaceCharacters(in: t.range, with: replaced)
    }

    /// Replace the text after the checkbox on a task line, keeping indent, bullet and mark.
    public func replaceTaskTitle(line: Int, expectedKey: String, with title: String) throws {
        let cleaned = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return }
        let target = try locateTask(line: line, expectedKey: expectedKey)
        guard let parsed = TaskLineParser.parse(target.text) else { throw TaskWriteError.moved }
        let prefix = (target.text as NSString).substring(to: parsed.markOffset + 2)
        textStorage.replaceCharacters(in: target.range, with: prefix + " " + cleaned)
    }

    /// Replace the indented note lines under a task (nil/empty removes them).
    public func replaceTaskNotes(line: Int, expectedKey: String, with notes: String?) throws {
        let target = try locateTask(line: line, expectedKey: expectedKey)
        let map = blockMap.lines.isEmpty ? BlockMap.scan(textStorage.string) : blockMap
        var end = target.index
        while end + 1 < map.lines.count, TaskLineParser.isContinuation(map.lines[end + 1].text) { end += 1 }
        let indent = String(repeating: " ", count: max(2, (TaskLineParser.parse(target.text)?.indent ?? 0) + 2))
        let cleaned = (notes ?? "").split(separator: "\n", omittingEmptySubsequences: true)
            .map { indent + $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let replacementLines = [target.text] + cleaned
        let start = target.range.location
        let stop = map.lines[end].range.location + map.lines[end].range.length
        textStorage.replaceCharacters(in: NSRange(location: start, length: stop - start), with: replacementLines.joined(separator: "\n"))
    }

    // MARK: Highlights

    /// Rewrite the meta line of the highlight block starting on `line`,
    /// verifying its content key; if the block moved, find a unique block with
    /// the same key.
    public func replaceHighlightMeta(line: Int, expectedKey: String, with meta: HighlightMeta) throws {
        try replaceHighlightMeta(line: line, expectedKey: expectedKey) { $0 = meta }
    }

    /// Change the meta line as it stands now, so edits queued behind each other
    /// (a ♥ then a tag) each build on the last.
    public func replaceHighlightMeta(line: Int, expectedKey: String, change: (inout HighlightMeta) -> Void) throws {
        let parsed = HighlightParser.parse(textStorage.string, path: path)
        let item: HighlightItem
        if let hit = parsed.items.first(where: { $0.line == line && $0.contentKey == expectedKey }) {
            item = hit
        } else {
            let candidates = parsed.items.filter { $0.contentKey == expectedKey }
            guard candidates.count == 1 else { throw TaskWriteError.moved }
            item = candidates[0]
        }
        let map = blockMap.lines.isEmpty ? BlockMap.scan(textStorage.string) : blockMap
        guard item.metaLine < map.lines.count else { throw TaskWriteError.moved }
        var meta = item.meta
        change(&meta)
        guard meta != item.meta else { return }
        textStorage.replaceCharacters(in: map.lines[item.metaLine].range, with: HighlightMarkdown.renderMeta(meta))
    }

    /// Replace the whole text as an edit (marks the document dirty, unlike `setText`).
    public func replaceWholeText(_ text: String) {
        guard text != textStorage.string else { return }
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
    }

    private func locateTask(line: Int, expectedKey: String) throws -> ScannedLine {
        let map = blockMap.lines.isEmpty ? BlockMap.scan(textStorage.string) : blockMap
        func matches(_ l: ScannedLine) -> Bool {
            guard let p = TaskLineParser.parse(l.text) else { return false }
            return TaskItem.contentKey(for: p.title) == expectedKey
        }
        if line < map.lines.count, matches(map.lines[line]) { return map.lines[line] }
        let candidates = map.lines.filter(matches)
        guard candidates.count == 1 else { throw TaskWriteError.moved }
        return candidates[0]
    }

    /// Append a task line at the end of the document (for the standalone Tasks
    /// file), with optional note lines indented beneath it.
    public func appendTaskLine(_ title: String, status: TaskStatus = .notStarted, notes: String? = nil) {
        var text = textStorage.string
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        text += "- [\(status.mark)] \(title)\n"
        for line in (notes ?? "").split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { text += "  \(trimmed)\n" }
        }
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
    }

    /// True when some task line in the document has this content key.
    public func containsTask(withKey key: String) -> Bool {
        let map = blockMap.lines.isEmpty ? BlockMap.scan(textStorage.string) : blockMap
        return map.lines.contains { line in
            guard let p = TaskLineParser.parse(line.text) else { return false }
            return TaskItem.contentKey(for: p.title) == key
        }
    }

    /// Append a task line under a `## Tasks` heading, creating it if needed.
    public func appendTask(_ title: String, status: TaskStatus = .notStarted) {
        var text = textStorage.string
        let line = "- [\(status.mark)] \(title)"
        let map = BlockMap.scan(text)
        if let heading = map.lines.first(where: { $0.kind == .heading(level: 2) && $0.text.lowercased().hasSuffix("tasks") }) {
            // Insert after the last task/list line following the heading.
            var insertAfter = heading.index
            var i = heading.index + 1
            while i < map.lines.count {
                switch map.lines[i].kind {
                case .task, .listItem: insertAfter = i; i += 1
                case .blank where insertAfter == heading.index: i += 1
                default: i = map.lines.count
                }
            }
            let r = map.lines[insertAfter].range
            let ns = text as NSString
            text = ns.replacingCharacters(in: NSRange(location: r.location + r.length, length: 0), with: "\n" + line)
        } else {
            if !text.hasSuffix("\n") && !text.isEmpty { text += "\n" }
            if !text.isEmpty { text += "\n" }
            text += "## Tasks\n\(line)\n"
        }
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
    }
}

/// What a coordinated read found on disk, gathered off the main actor.
public struct DiskRead: Sendable {
    public var isPlaceholder = false
    public var data: Data?
    public var stat: FileIO.Stat?

    /// A missing or unreadable file gives `data == nil`.
    public static func read(_ url: URL, presenter: NSFilePresenter? = nil) -> DiskRead {
        if ICloudPlaceholders.isPlaceholder(url) { return DiskRead(isPlaceholder: true) }
        guard FileManager.default.fileExists(atPath: url.path) else { return DiskRead() }
        return DiskRead(data: try? FileIO.read(url, presenter: presenter), stat: FileIO.stat(url))
    }
}

/// A document's text as it is being written, detached from the document.
public struct SaveSnapshot: Sendable {
    public let path: String
    public let url: URL
    public let day: DayKey?
    public let data: Data
    public let hash: String
    let token: Int
    let editCount: Int
}
