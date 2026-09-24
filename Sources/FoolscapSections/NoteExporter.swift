import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, textbundle, html, pdf
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .markdown: return "Markdown"
        case .textbundle: return "TextBundle"
        case .html: return "HTML"
        case .pdf: return "PDF"
        }
    }
    var fileExtension: String { self == .markdown ? "md" : rawValue }
    /// TextBundles are one package per note, so ranges always go into a folder.
    var isPerNote: Bool { self == .textbundle }
}

public enum ExportScope: Hashable, Sendable {
    case day(DayKey)
    case range(DayKey, DayKey)
    case all
}

/// Writes notes out as files. Markdown copies attachments alongside; HTML and
/// PDF are self-contained documents.
@MainActor
public enum NoteExporter {
    public struct Result: Sendable { public var files: [URL] }

    public static func export(library: NotebookLibrary, scope: ExportScope, format: ExportFormat,
                              includeAttachments: Bool, theme: NotebookTheme, to destination: URL) async throws -> Result {
        await library.save()
        // Listing and reading the notes (one coordinated read each) happen off the
        // main actor; only laying out a PDF needs it.
        let folder = library.folder
        let notes: [(day: DayKey, text: String)] = await Task.detached(priority: .userInitiated) {
            selectDays(folder: folder, scope: scope).compactMap { day in
                guard let data = try? FileIO.read(folder.url(for: day)) else { return nil }
                return (day, String(decoding: data, as: UTF8.self))
            }
        }.value
        guard !notes.isEmpty else { return Result(files: []) }
        if format == .textbundle {
            let dir = isDirectoryURL(destination) ? destination : destination.deletingLastPathComponent()
            var files: [URL] = []
            for note in notes {
                let bundleURL = notes.count == 1 && !isDirectoryURL(destination)
                    ? destination : dir.appendingPathComponent("\(note.day.string).textbundle", isDirectory: true)
                try writeTextBundle(note: note, library: library, to: bundleURL)
                files.append(bundleURL)
            }
            return Result(files: files)
        }
        let single = notes.count == 1
        let title = single ? notes[0].day.longTitle : "Foolscap \(notes.first!.day) to \(notes.last!.day)"
        let baseName = single ? notes[0].day.string : "foolscap-\(notes.first!.day)-to-\(notes.last!.day)"
        // `destination` is a file when exporting one document, a directory otherwise.
        let isDirectory = (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let outFile = isDirectory ? destination.appendingPathComponent("\(baseName).\(format.fileExtension)") : destination
        let outDir = outFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var files: [URL] = []
        switch format {
        case .markdown:
            var texts = notes.map(\.text)
            if includeAttachments {
                // Copy referenced images next to the export and rewrite their paths.
                let attachmentsDir = outDir.appendingPathComponent("Attachments", isDirectory: true)
                for i in notes.indices {
                    texts[i] = try copyingAttachments(in: notes[i].text, from: library.folder.url(for: notes[i].day),
                                                      to: attachmentsDir, filesOut: &files)
                }
            }
            let combined = single ? texts[0] : MarkdownExporter.combinedMarkdown(zip(notes, texts).map { ($0.day.longTitle, $1) })
            try FileIO.write(Data(combined.utf8), to: outFile)
            files.insert(outFile, at: 0)
        case .html:
            var texts = notes.map(\.text)
            let attachmentsDir = outDir.appendingPathComponent("Attachments", isDirectory: true)
            for i in notes.indices {
                texts[i] = try copyingAttachments(in: notes[i].text, from: library.folder.url(for: notes[i].day),
                                                  to: attachmentsDir, filesOut: &files)
            }
            let combined = single ? texts[0] : MarkdownExporter.combinedMarkdown(zip(notes, texts).map { ($0.day.longTitle, $1) })
            try FileIO.write(Data(MarkdownExporter.html(fromMarkdown: combined, title: title).utf8), to: outFile)
            files.insert(outFile, at: 0)
        case .pdf:
            let data = try pdf(notes: notes, library: library, theme: theme)
            try FileIO.write(data, to: outFile)
            files = [outFile]
        case .textbundle:
            break   // handled above
        }
        return Result(files: files)
    }

    static func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// TextBundle (textbundle.org) v2: text.md, info.json and assets/.
    static func writeTextBundle(note: (day: DayKey, text: String), library: NotebookLibrary, to bundleURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleURL.path) { try fm.removeItem(at: bundleURL) }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let assets = bundleURL.appendingPathComponent("assets", isDirectory: true)
        var copied: [URL] = []
        var text = try copyingAttachments(in: note.text, from: library.folder.url(for: note.day), to: assets, filesOut: &copied)
        text = text.replacingOccurrences(of: "](Attachments/", with: "](assets/")
        try Data(text.utf8).write(to: bundleURL.appendingPathComponent("text.md"), options: .atomic)
        let info: [String: Any] = [
            "version": 2,
            "type": "net.daringfireball.markdown",
            "transient": false,
            "creatorIdentifier": "com.seanmatheny.foolscap",
        ]
        let json = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: bundleURL.appendingPathComponent("info.json"), options: .atomic)
    }

    nonisolated static func selectDays(folder: NotesFolder, scope: ExportScope) -> [DayKey] {
        let all = folder.listDailyNotes().filter { !$0.isPlaceholder }.map(\.day)
        switch scope {
        case .day(let d): return all.contains(d) ? [d] : []
        case .range(let a, let b): return all.filter { $0 >= min(a, b) && $0 <= max(a, b) }
        case .all: return all
        }
    }

    private static let imageRefRegex = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)

    /// Copy local images referenced by a note into `dir`, returning the note
    /// with references rewritten to `Attachments/<name>`.
    static func copyingAttachments(in text: String, from noteURL: URL, to dir: URL, filesOut: inout [URL]) throws -> String {
        let ns = text as NSString
        var out = text
        for m in imageRefRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let ref = ns.substring(with: m.range(at: 2))
            guard !ref.hasPrefix("http") else { continue }
            let src = ref.hasPrefix("/") ? URL(fileURLWithPath: ref) : noteURL.deletingLastPathComponent().appendingPathComponent(ref).standardizedFileURL
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.copyItem(at: src, to: dst) }
            filesOut.append(dst)
            let alt = ns.substring(with: m.range(at: 1))
            out = (out as NSString).replacingCharacters(in: m.range, with: "![\(alt)](Attachments/\(src.lastPathComponent))")
        }
        return out
    }

    /// Render the notes through the real editor styling and paginate with AppKit printing.
    static func pdf(notes: [(day: DayKey, text: String)], library: NotebookLibrary, theme: NotebookTheme) throws -> Data {
        let combined = notes.count == 1 ? notes[0].text : MarkdownExporter.combinedMarkdown(notes.map { ($0.day.longTitle, $0.text) })
        let doc = NoteDocument(path: "export.md", url: library.folder.url(for: notes[0].day), day: notes[0].day)
        doc.setText(combined)
        var palette = EditorPalette(theme: theme)
        palette.ruling = .blank
        palette.showMarginRule = false
        let textView = MarkdownTextView(document: doc, palette: palette)
        let pageWidth: CGFloat = 612 - 2 * 54
        textView.frame = NSRect(x: 0, y: 0, width: pageWidth, height: 10)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.size = NSSize(width: pageWidth, height: CGFloat.greatestFiniteMagnitude)
        // Never touch `layoutManager` here: reading it downgrades the view to TextKit 1.
        guard let tlm = textView.textLayoutManager else { throw CocoaError(.fileWriteUnknown) }
        tlm.ensureLayout(for: tlm.documentRange)
        let used = tlm.usageBoundsForTextContainer
        textView.frame.size.height = max(used.maxY + 20, 10)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.jobDisposition = .save
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-\(UUID().uuidString).pdf")
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp
        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Data(contentsOf: tmp)
    }
}
