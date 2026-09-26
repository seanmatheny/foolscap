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
    public var coversWritten = 0
    public var empties = 0
    public var skipped: [SkippedBook] = []

    public init() {}

    public var skippedHighlights: Int { skipped.reduce(0) { $0 + $1.count } }

    public var summary: String {
        var parts: [String] = []
        if highlightsAdded > 0 { parts.append("\(highlightsAdded) added") }
        if highlightsUpdated > 0 { parts.append("\(highlightsUpdated) updated") }
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

        var work: [(book: KindleBook, pending: [KindleAnnotation], wantsCover: Bool)] = []
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
            if pending.isEmpty && !wantsCover { continue }
            work.append((book, pending, wantsCover))
        }
        let kfxBooks = work.map(\.book).filter { $0.format == .kfx }
        if !kfxBooks.isEmpty { await extractor.prepare(kfxBooks, progress: progress) }

        for (book, pending, wantsCover) in work {
            try Task.checkCancellation()
            progress("Reading \(book.title)…")
            let extracted: ExtractedBook
            do {
                extracted = try await extractor.extract(book, annotations: pending, wantsCover: wantsCover)
            } catch let failure as ExtractionFailure {
                report.skipped.append(SkippedBook(title: book.title, count: pending.count, reason: failure.message)); continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.skipped.append(SkippedBook(title: book.title, count: pending.count, reason: error.localizedDescription)); continue
            }
            report.empties += extracted.emptyCount
            try await write(extracted, pending: pending, report: &report)
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

    private func write(_ extracted: ExtractedBook, pending: [KindleAnnotation], report: inout ImportReport) async throws {
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
        for h in extracted.highlights {
            extractedIDs.insert(h.annotationID)
            let key = HighlightsState.key(book: book.id, annotation: h.annotationID)
            let contentKey = HighlightItem.contentKey(for: h.paragraphs)
            // A known annotation with new text replaces its old block; a new one
            // replaces an identical quote if the file already has it (a lost
            // ledger), else is appended.
            let known = state.annotations[key]
            if known != nil { report.highlightsUpdated += 1 } else { report.highlightsAdded += 1 }
            blocks.append(HighlightMarkdown.NewBlock(paragraphs: h.paragraphs, note: h.note,
                                                    meta: HighlightMeta(position: h.position, added: h.created),
                                                    replacingKey: known?.contentKey ?? contentKey))
            state.annotations[key] = HighlightsState.Annotation(contentKey: contentKey, modified: h.modified, empty: false)
        }
        // Ranges without text are remembered too, so they are not retried every pass.
        for a in pending where !extractedIDs.contains(a.id) {
            let key = HighlightsState.key(book: book.id, annotation: a.id)
            if state.annotations[key] == nil { state.annotations[key] = HighlightsState.Annotation(contentKey: "", modified: a.modified, empty: true) }
        }
        if !blocks.isEmpty {
            let doc = await library.loadedDocument(atRelativePath: path)
            let header = HighlightMarkdown.renderHeader(title: book.title, author: book.author)
            let current = await MainActor.run { doc.text }
            let base = current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? header : current
            let updated = HighlightMarkdown.inserting(blocks, into: base, path: path)
            await MainActor.run { doc.replaceWholeText(updated) }
            report.booksWritten += 1
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
