import Foundation
import FoolscapStore

/// What one sync pass did.
public struct SyncReport: Equatable, Sendable {
    public var rendered = 0
    public var transcribed = 0
    public var tasksAdded = 0
    public var pruned = 0
    /// Items whose path changed (renamed or moved on the Kindle).
    public var moved = 0
    public var errors: [String] = []
    public init() {}

    /// Whether the pass changed any file the notes index covers.
    public var changedFiles: Bool { rendered + transcribed + pruned + moved > 0 }
}

/// One pass: list the Kindle's notebooks, fetch what changed, build PDFs,
/// recognise the handwriting, write transcripts and hand new TODOs to the
/// task sink. State is saved after every notebook so an interrupted pass
/// loses at most one.
public actor ScribeSyncEngine {
    public static let recheckWindow: TimeInterval = 72 * 60 * 60
    /// Passes after an edit that fetch again regardless of the interval.
    static let eagerRechecks = 2
    /// After those, how often a recently edited notebook is fetched again.
    public static let recheckInterval: TimeInterval = 2 * 60 * 60
    static let renderAttempts = 3

    let client: any ScribeClient
    let ocr: any OCRRunning
    let cache: OCRCache
    let stateURL: URL
    let sink: any TaskSink
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async -> Void
    public private(set) var state: ScribeState
    public private(set) var isRunning = false

    public init(client: any ScribeClient, ocr: any OCRRunning, cache: OCRCache, stateURL: URL, sink: any TaskSink,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.client = client; self.ocr = ocr; self.cache = cache; self.stateURL = stateURL; self.sink = sink
        self.now = now; self.sleep = sleep
        state = ScribeState.load(from: stateURL)
    }

    /// `notesRoot` is the notebook folder; files go under `<root>/Scribe/`.
    public func syncOnce(notesRoot: URL, languages: [String],
                         progress: (@Sendable (String) -> Void)? = nil) async throws -> SyncReport {
        guard !isRunning else { return SyncReport() }
        isRunning = true
        defer { isRunning = false }
        var report = SyncReport()
        let scribeRoot = notesRoot.appendingPathComponent(NotesFolder.scribeDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: scribeRoot, withIntermediateDirectories: true)

        progress?("Listing notebooks…")
        let listing = try await client.listNotebooks()
        var seen = Set<String>()
        walk(listing, parentID: nil, parentPath: "", root: scribeRoot, seen: &seen, report: &report)
        try? state.save(to: stateURL)

        let titles = ScribeTranscript.noteTitles(state.notebooks.map(\.ref))
        for notebook in state.notebooks where seen.contains(notebook.id) {
            try Task.checkCancellation()
            do {
                try await sync(notebook: notebook, title: titles[notebook.id] ?? notebook.name, root: scribeRoot,
                               languages: languages, report: &report, progress: progress)
            } catch ScribeClientError.signedOut {
                throw ScribeClientError.signedOut
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.errors.append("\(notebook.path): \(error)")
            }
            try? state.save(to: stateURL)
        }

        if !listing.isEmpty {
            report.pruned = prune(keeping: seen, root: scribeRoot)
        }
        state.lastSync = now()
        try? state.save(to: stateURL)
        return report
    }

    // MARK: Tree

    private func walk(_ items: [RemoteItem], parentID: String?, parentPath: String, root: URL, seen: inout Set<String>,
                      report: inout SyncReport) {
        for (order, item) in items.enumerated() {
            let safe = ScribeTranscript.sanitizeName(item.title)
            let path = parentPath.isEmpty ? safe : parentPath + "/" + safe
            seen.insert(item.id)
            if var existing = state.items[item.id] {
                if existing.path != path {
                    move(existing, to: path, root: root)
                    existing.path = path
                    report.moved += 1
                }
                existing.name = item.title
                existing.parentID = parentID
                existing.order = order
                existing.isFolder = item.isFolder
                state.items[item.id] = existing
            } else {
                state.items[item.id] = ScribeItem(id: item.id, name: item.title, path: path, isFolder: item.isFolder,
                                                  parentID: parentID, order: order)
            }
            if item.isFolder {
                try? FileManager.default.createDirectory(at: root.appendingPathComponent(path, isDirectory: true),
                                                         withIntermediateDirectories: true)
                walk(item.items ?? [], parentID: item.id, parentPath: path, root: root, seen: &seen, report: &report)
            }
        }
    }

    /// A rename on the Kindle moves the local files rather than re-rendering them.
    private func move(_ item: ScribeItem, to newPath: String, root: URL) {
        let fm = FileManager.default
        let pairs: [(URL, URL)] = item.isFolder
            ? [(root.appendingPathComponent(item.path, isDirectory: true), root.appendingPathComponent(newPath, isDirectory: true))]
            : ["pdf", "md"].map { (root.appendingPathComponent(item.path + "." + $0), root.appendingPathComponent(newPath + "." + $0)) }
        for (from, to) in pairs where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            var moveError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: .forReplacing,
                                           error: &moveError) { src, dst in
                try? fm.moveItem(at: src, to: dst)
            }
        }
    }

    // MARK: One notebook

    private func sync(notebook: ScribeItem, title: String, root: URL, languages: [String],
                      report: inout SyncReport, progress: (@Sendable (String) -> Void)?) async throws {
        var entry = notebook
        let pdfURL = root.appendingPathComponent(entry.path + ".pdf")
        let mdURL = root.appendingPathComponent(entry.path + ".md")
        let fm = FileManager.default

        progress?("Checking \(entry.path)…")
        let opened = try await client.openNotebook(id: entry.id)
        await sleep(.seconds(1))
        let placeholder = ICloudPlaceholders.isPlaceholder(pdfURL)
        let pdfMissing = !fm.fileExists(atPath: pdfURL.path) && !placeholder
        let pagesChanged = entry.totalPages != nil && entry.totalPages != opened.metadata.totalPages
        let nowSeconds = Int(now().timeIntervalSince1970)
        // A new edit on the Kindle starts the recheck over.
        if opened.modificationTime != entry.modificationTime { entry.unchangedFetches = 0 }
        // No content hash means the PDF was adopted from elsewhere: fetch once so the
        // transcript and cache can key on the real page images.
        let shouldRender = opened.modificationTime > entry.updateTime || pdfMissing || pagesChanged || entry.contentHash == nil
        // Amazon stamps modificationTime the moment a page is edited, but can go on
        // serving the old page images for a while afterwards. A recently modified
        // notebook is fetched again and rebuilt only when its page images differ:
        // on the next couple of passes, then at most every `recheckInterval`.
        let recheckDue = (entry.unchangedFetches ?? 0) < Self.eagerRechecks
            || nowSeconds - (entry.lastFetch ?? 0) >= Int(Self.recheckInterval)
        let recheck = !shouldRender && !placeholder && recheckDue
            && Double(nowSeconds - opened.modificationTime) < Self.recheckWindow

        if shouldRender || recheck {
            progress?("Fetching \(entry.path)…")
            let pages = try await fetchPages(token: opened.renderingToken, pageCount: opened.metadata.totalPages)
            let hash = PDFBuilder.contentHash(pages)
            entry.lastFetch = nowSeconds
            if hash == entry.contentHash && (fm.fileExists(atPath: pdfURL.path) || placeholder) {
                // The PDF already holds these images. Rebuilding it would change only
                // its embedded dates, yet upload it to iCloud and redraw the viewer.
                entry.unchangedFetches = (entry.unchangedFetches ?? 0) + 1
                if shouldRender {
                    entry.updateTime = nowSeconds
                    entry.totalPages = opened.metadata.totalPages
                }
            } else {
                let pdf = try PDFBuilder.makePDF(pages: pages)
                try FileIO.write(pdf, to: pdfURL)
                entry.updateTime = nowSeconds
                entry.totalPages = opened.metadata.totalPages
                entry.contentHash = hash
                entry.pdfHash = PDFBuilder.sha256(pdf)
                entry.unchangedFetches = 0
                report.rendered += 1
            }
        }
        entry.modificationTime = opened.modificationTime

        if let hash = entry.contentHash, !placeholder, fm.fileExists(atPath: pdfURL.path) {
            try await transcribe(&entry, contentHash: hash, title: title, pdfURL: pdfURL, mdURL: mdURL,
                                 modified: opened.modificationTime, languages: languages, report: &report, progress: progress)
        }
        state.items[entry.id] = entry
    }

    /// What a transcript is written from besides the page images, so changing the
    /// handwriting languages or the OCR engine re-reads it, and a rename or move
    /// rewrites its title, tag and footer.
    static func transcriptKey(contentHash: String, languages: [String], path: String, title: String) -> String {
        let parts = [contentHash, languages.joined(separator: ","), ScribeOCR.engineVersion, path, title]
        return PDFBuilder.sha256(Data(parts.joined(separator: "\n").utf8))
    }

    /// Recognise the handwriting (or reuse the cached result), write the transcript
    /// if its bytes changed and hand new TODOs to the sink.
    private func transcribe(_ entry: inout ScribeItem, contentHash hash: String, title: String, pdfURL: URL, mdURL: URL,
                            modified modificationTime: Int, languages: [String],
                            report: inout SyncReport, progress: (@Sendable (String) -> Void)?) async throws {
        let transcriptKey = Self.transcriptKey(contentHash: hash, languages: languages, path: entry.path, title: title)
        if entry.transcribedHash == transcriptKey && FileManager.default.fileExists(atPath: mdURL.path) { return }
        progress?("Reading \(entry.path)…")
        let key = OCRCacheKey(contentHash: hash, languages: languages)
        let result: OCRResult
        if let cached = cache.load(id: entry.id, key: key) {
            result = cached
        } else {
            result = try await ocr.recognise(pdf: pdfURL, languages: languages)
            try? cache.store(result, id: entry.id, key: key)
        }
        let pages = ScribeLayout.layoutPages(result)
        let modified = Date(timeIntervalSince1970: Double(modificationTime))
        let text = ScribeTranscript.render(notebook: entry.ref, title: title, pages: pages, modified: modified)
        let data = Data(text.utf8)
        if (try? FileIO.read(mdURL)) != data { try FileIO.write(data, to: mdURL) }
        report.transcribed += 1

        let outcome = await TodoLedger.sync(found: ScribeTodos.extractTodos(pages), known: entry.todos,
                                            source: entry.path, sink: sink, now: now())
        entry.todos = outcome.known
        report.tasksAdded += outcome.added
        entry.transcribedHash = transcriptKey
    }

    private func fetchPages(token: String, pageCount: Int) async throws -> [Data] {
        var lastError: Error = ScribeClientError.notATar
        for attempt in 0..<Self.renderAttempts {
            let data = try await client.renderPages(token: token, pageCount: pageCount)
            do {
                return PDFBuilder.orderedPages(try TarReader.members(in: data))
            } catch {
                lastError = ScribeClientError.notATar
                if attempt + 1 < Self.renderAttempts { await sleep(.seconds(2)) }
            }
        }
        throw lastError
    }

    // MARK: Prune

    /// Drop items that vanished from the Kindle: their files, OCR cache and state.
    private func prune(keeping seen: Set<String>, root: URL) -> Int {
        let fm = FileManager.default
        var count = 0
        for item in state.items.values where !seen.contains(item.id) {
            if item.isFolder {
                let dir = root.appendingPathComponent(item.path, isDirectory: true)
                if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty { remove(dir) }
            } else {
                for ext in ["pdf", "md"] { remove(root.appendingPathComponent(item.path + "." + ext)) }
                cache.remove(id: item.id)
            }
            state.items[item.id] = nil
            count += 1
        }
        return count
    }

    /// A coordinated delete, like the coordinated `move`, so the file provider
    /// behind iCloud Drive is not caught mid-write.
    private func remove(_ url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
            try? FileManager.default.removeItem(at: target)
        }
    }
}
