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

    private var observer: NSObjectProtocol?

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

    private func didEdit() {
        isDirty = true
        editCount += 1
        blockMap = BlockMap.scan(textStorage.string)
    }

    // MARK: Loading and saving

    public func load(template: String = "") {
        if ICloudPlaceholders.isPlaceholder(url) {
            isDownloading = true
            ICloudPlaceholders.startDownload(url)
            return
        }
        isDownloading = false
        templateText = template
        let exists = FileManager.default.fileExists(atPath: url.path)
        let data = (exists ? try? FileIO.read(url) : nil) ?? Data(template.utf8)
        setText(String(decoding: data, as: UTF8.self))
        lastSavedHash = exists ? FileIO.hash(data) : nil
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
    /// text was replaced.
    @discardableResult
    public func reloadIfChanged() -> Bool {
        guard !isDownloading || !ICloudPlaceholders.isPlaceholder(url) else { return false }
        guard let data = try? FileIO.read(url) else { return false }
        let hash = FileIO.hash(data)
        guard hash != lastSavedHash else { return false }
        if isDirty {
            externalChangePending = true
            return false
        }
        isDownloading = false
        setText(String(decoding: data, as: UTF8.self))
        lastSavedHash = hash
        return true
    }

    // MARK: iCloud conflicts

    /// Look for unresolved conflict versions (iCloud writes them when two
    /// devices edited the same file).
    public func checkConflicts() {
        conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
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
        let map = blockMap.lines.isEmpty ? BlockMap.scan(textStorage.string) : blockMap
        func matches(_ l: ScannedLine) -> Bool {
            guard let p = TaskLineParser.parse(l.text) else { return false }
            return TaskItem.contentKey(for: p.title) == expectedKey
        }
        var target: ScannedLine?
        if line < map.lines.count, matches(map.lines[line]) {
            target = map.lines[line]
        } else {
            let candidates = map.lines.filter(matches)
            guard candidates.count == 1 else { throw TaskWriteError.moved }
            target = candidates[0]
        }
        guard let t = target, let replaced = TaskLineParser.replacingStatus(in: t.text, with: status) else {
            throw TaskWriteError.moved
        }
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
