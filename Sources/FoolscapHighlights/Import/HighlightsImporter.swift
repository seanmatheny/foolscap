import Foundation
import FoolscapCore
import FoolscapStore

public struct SkippedBook: Equatable, Sendable, Identifiable {
    public var title: String
    public var count: Int
    public var reason: String
    public var id: String { title + "|" + reason }
    public init(title: String, count: Int, reason: String) { self.title = title; self.count = count; self.reason = reason }
}

public struct ImportReport: Equatable, Sendable {
    /// Books with at least one highlight.
    public var booksSeen = 0
    public var booksWritten = 0
    public var highlightsAdded = 0
    public var highlightsUpdated = 0
    /// Deleted on the Kindle: marked hidden in the file, never removed.
    public var highlightsHidden = 0
    public var coversWritten = 0
    public var empties = 0
    public var skipped: [SkippedBook] = []

    public init() {}

    public var skippedHighlights: Int { skipped.reduce(0) { $0 + $1.count } }

    public var summary: String {
        var parts: [String] = []
        if highlightsAdded > 0 { parts.append("\(highlightsAdded) added") }
        if highlightsUpdated > 0 { parts.append("\(highlightsUpdated) updated") }
        if highlightsHidden > 0 { parts.append("\(highlightsHidden) hidden (deleted on the Kindle)") }
        if parts.isEmpty { parts.append("nothing new") }
        if !skipped.isEmpty { parts.append("\(skipped.count) book\(skipped.count == 1 ? "" : "s") skipped") }
        return parts.joined(separator: ", ")
    }
}

/// One pass over the Kindle app's annotations: every highlight not yet in
/// its book file is decoded and appended; the ledger keeps a highlight from
/// ever arriving twice, however it was edited, tagged or hidden since.
public actor HighlightsImporter {
    private let extractor: any KindleExtracting
    private let library: NotebookLibrary
    private let stateURL: URL
    private let now: @Sendable () -> Date
    public private(set) var state: HighlightsState

    public init(extractor: any KindleExtracting, library: NotebookLibrary, stateURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.extractor = extractor
        self.library = library
        self.stateURL = stateURL
        self.now = now
        state = HighlightsState.load(from: stateURL)
    }

    public func run(progress: @Sendable @escaping (String) -> Void) async throws -> ImportReport {
        progress("Reading the Kindle library…")
        let listing = try await extractor.listing()
        var report = ImportReport()
        let books = listing.books
            .filter { !$0.isDictionary && !(listing.annotations[$0.id] ?? []).isEmpty }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        report.booksSeen = books.count

        var work: [(book: KindleBook, pending: [KindleAnnotation], vanished: [String: HighlightsState.Annotation], wantsCover: Bool)] = []
        for book in books {
            let annotations = listing.annotations[book.id] ?? []
            if !book.isDownloaded {
                report.skipped.append(SkippedBook(title: book.title, count: annotations.count, reason: ExtractionFailure.notDownloaded.message)); continue
            }
            switch book.format {
            case .pdf: report.skipped.append(SkippedBook(title: book.title, count: annotations.count, reason: ExtractionFailure.unsupportedFormat("PDF").message)); continue
            case .other(let mime): report.skipped.append(SkippedBook(title: book.title, count: annotations.count, reason: ExtractionFailure.unsupportedFormat(mime).message)); continue
            case .mobi, .kfx: break
            }
            let pending = annotations.filter { needsWork($0, book: book) }
            let wantsCover = !(state.books[book.id]?.coverDone ?? false)
            let vanished = self.vanished(from: annotations, book: book)
            if pending.isEmpty && vanished.isEmpty && !wantsCover { continue }
            work.append((book, pending, vanished, wantsCover))
        }
        let kfxBooks = work.map(\.book).filter { $0.format == .kfx }
        if !kfxBooks.isEmpty { await extractor.prepare(kfxBooks, progress: progress) }

        for (book, pending, vanished, wantsCover) in work {
            try Task.checkCancellation()
            progress("Reading \(book.title)…")
            let extracted: ExtractedBook
            do {
                extracted = pending.isEmpty && !wantsCover
                    ? ExtractedBook(book: book, coverJPEG: nil, highlights: [], emptyCount: 0)
                    : try await extractor.extract(book, annotations: pending, wantsCover: wantsCover)
            } catch let failure as ExtractionFailure {
                report.skipped.append(SkippedBook(title: book.title, count: pending.count, reason: failure.message)); continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.skipped.append(SkippedBook(title: book.title, count: pending.count, reason: error.localizedDescription)); continue
            }
            report.empties += extracted.emptyCount
            try await write(extracted, pending: pending, vanished: vanished, report: &report)
            try? state.save(to: stateURL)
        }
        state.lastRun = now()
        try? state.save(to: stateURL)
        await library.save()
        return report
    }

    /// New to the ledger, or changed on the Kindle since it was written.
    private func needsWork(_ annotation: KindleAnnotation, book: KindleBook) -> Bool {
        guard let known = state.annotations[HighlightsState.key(book: book.id, annotation: annotation.id)] else { return true }
        if let modified = annotation.modified, let seen = known.modified, modified.timeIntervalSince(seen) > 1 { return true }
        return false
    }

    /// Ledger entries for this book whose annotation the Kindle no longer has.
    private func vanished(from annotations: [KindleAnnotation], book: KindleBook) -> [String: HighlightsState.Annotation] {
        let present = Set(annotations.map { HighlightsState.key(book: book.id, annotation: $0.id) })
        let prefix = book.id + "/"
        return state.annotations.filter { $0.key.hasPrefix(prefix) && !$0.value.empty && !present.contains($0.key) }
    }

    /// The range a ledger entry covered; older entries only know their start, from the Kindle id.
    private static func range(of entry: HighlightsState.Annotation, key: String) -> ClosedRange<Int>? {
        if let start = entry.start { return start...(entry.end ?? start) }
        guard let dash = key.lastIndex(of: "-"), let start = Int(key[key.index(after: dash)...]) else { return nil }
        return start...start
    }

    private func write(_ extracted: ExtractedBook, pending: [KindleAnnotation], vanished: [String: HighlightsState.Annotation],
                       report: inout ImportReport) async throws {
        let book = extracted.book
        var record: HighlightsState.Book
        if let existing = state.books[book.id] {
            record = existing
        } else {
            record = HighlightsState.Book(path: newPath(for: book), title: book.title, author: book.author, coverDone: false)
        }
        let path = record.path
        var blocks: [HighlightMarkdown.NewBlock] = []
        var extractedIDs = Set<String>()
        var vanished = vanished
        let ranges = Dictionary(pending.map { ($0.id, $0.start...max($0.start, $0.end)) }, uniquingKeysWith: { a, _ in a })
        for h in extracted.highlights {
            extractedIDs.insert(h.annotationID)
            let key = HighlightsState.key(book: book.id, annotation: h.annotationID)
            let contentKey = HighlightItem.contentKey(for: h.paragraphs)
            // A known annotation with new text replaces its old block. A new one
            // takes the place of a vanished highlight over the same passage (the
            // Kindle renames a highlight whose start moved), or of an identical
            // quote the file already has (a lost ledger); else it is appended.
            let known = state.annotations[key]
            var replacing = known?.contentKey
            if replacing == nil, let range = ranges[h.annotationID],
               let old = vanished.first(where: { Self.range(of: $0.value, key: $0.key)?.overlaps(range) == true }) {
                replacing = old.value.contentKey
                vanished[old.key] = nil
                state.annotations[old.key] = nil
                report.highlightsUpdated += 1
            } else if known != nil {
                report.highlightsUpdated += 1
            } else {
                report.highlightsAdded += 1
            }
            blocks.append(HighlightMarkdown.NewBlock(paragraphs: h.paragraphs, note: h.note,
                                                    meta: HighlightMeta(position: h.position, added: h.created),
                                                    replacingKey: replacing ?? contentKey))
            state.annotations[key] = HighlightsState.Annotation(contentKey: contentKey, modified: h.modified, empty: false,
                                                                start: ranges[h.annotationID]?.lowerBound, end: ranges[h.annotationID]?.upperBound)
        }
        // What the Kindle deleted outright is hidden from the day's draw, not removed.
        let hiddenKeys = Set(vanished.values.map(\.contentKey))
        for key in vanished.keys { state.annotations[key] = nil }
        // Ranges without text are remembered too, so they are not retried every pass.
        for a in pending where !extractedIDs.contains(a.id) {
            let key = HighlightsState.key(book: book.id, annotation: a.id)
            if state.annotations[key] == nil { state.annotations[key] = HighlightsState.Annotation(contentKey: "", modified: a.modified, empty: true) }
        }
        if !blocks.isEmpty || !hiddenKeys.isEmpty {
            let doc = await library.loadedDocument(atRelativePath: path)
            let header = HighlightMarkdown.renderHeader(title: book.title, author: book.author)
            let current = await MainActor.run { doc.text }
            let base = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? header : current
            var updated = HighlightMarkdown.inserting(blocks, into: base, path: path)
            if !hiddenKeys.isEmpty {
                let before = HighlightParser.parse(updated, path: path).items.filter { hiddenKeys.contains($0.contentKey) && !$0.isHidden }.count
                updated = HighlightMarkdown.hiding(hiddenKeys, in: updated, path: path)
                report.highlightsHidden += before
            }
            if updated != current {
                await MainActor.run { doc.replaceWholeText(updated) }
                report.booksWritten += 1
            }
        }
        if !record.coverDone {
            if let jpeg = extracted.coverJPEG {
                let url = await library.folder.url(forRelativePath: Self.coverPath(for: path))
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? FileIO.write(jpeg, to: url)
                    report.coversWritten += 1
                }
            }
            record.coverDone = true
        }
        state.books[book.id] = record
    }

    public static func coverPath(for bookPath: String) -> String {
        bookPath.hasSuffix(".md") ? String(bookPath.dropLast(3)) + ".jpg" : bookPath + ".jpg"
    }

    /// `Highlights/<Title>.md`, with a number when another book already has the name.
    private func newPath(for book: KindleBook) -> String {
        let base = FileNames.sanitize(book.title)
        let taken = Set(state.books.values.map(\.path))
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) (\(n))"
            let path = "\(NotesFolder.highlightsDirectoryName)/\(name).md"
            if !taken.contains(path) { return path }
            n += 1
        }
    }
}
