import Foundation
import FoolscapCore

/// A notebook as the transcript writer sees it: Amazon id, display name and
/// its path under `Scribe/` without the extension.
public struct ScribeNotebookRef: Hashable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public init(id: String, name: String, path: String) { self.id = id; self.name = name; self.path = path }
}

/// The transcript markdown written next to each notebook PDF, and its reverse
/// for the viewer. The file is the source of truth for display and search.
public enum ScribeTranscript {
    public static let rootTag = "scribe"
    /// Bumped when the layout of the file changes, so every transcript is
    /// rewritten on the next sync (from the OCR cache, not re-recognised).
    public static let formatVersion = "transcript/2"

    /// Sanitize notebook/folder names for the file system.
    public static func sanitizeName(_ name: String) -> String { FileNames.sanitize(name) }

    /// Keep recognised text literal: a stray "#word" would otherwise become a
    /// tag, and OCR noise is full of stray symbols.
    public static func escapeMarkdown(_ text: String) -> String { MarkdownEscaping.escape(text) }

    /// The inverse of `escapeMarkdown`: every escape is a backslash before one character.
    public static func unescapeMarkdown(_ text: String) -> String { MarkdownEscaping.unescape(text) }

    static let todoMark = "**TODO:**"

    public static func renderLine(_ text: String) -> String {
        guard let found = ScribeTodos.splitTodo(text) else { return escapeMarkdown(text) }
        let rendered = "\(escapeMarkdown(found.before))\(todoMark) \(escapeMarkdown(found.task))"
        return String(rendered.reversed().drop(while: { $0.isWhitespace }).reversed())
    }

    /// Plain notebook names where they are unique, "Folder / Name" where they collide.
    public static func noteTitles(_ notebooks: [ScribeNotebookRef]) -> [String: String] {
        var counts: [String: Int] = [:]
        for n in notebooks { counts[n.name, default: 0] += 1 }
        return Dictionary(uniqueKeysWithValues: notebooks.map { n in
            (n.id, counts[n.name] == 1 ? n.name : n.path.split(separator: "/").joined(separator: " / "))
        })
    }

    public static func syncMarker(_ id: String) -> String { "Sync ID \(id)" }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// Build the transcript. Identical input gives identical output, so a hash
    /// of it decides whether the file needs rewriting.
    public static func render(notebook: ScribeNotebookRef, title: String, pages: [[[TextLine]]], modified: Date) -> String {
        // One flat tag: the Scribe tab browses by folder, so per-folder tags would
        // only crowd the tag suggestions.
        var out = ["# \(escapeMarkdown(title))", "#" + rootTag, ""]
        for (index, paragraphs) in pages.enumerated() {
            out += ["## Page \(index + 1)", ""]
            if paragraphs.isEmpty { out += ["*No handwriting recognised on this page.*", ""] }
            for paragraph in paragraphs {
                out += paragraph.map { renderLine($0.text) }
                out.append("")
            }
        }
        out += [
            "---",
            "*Recognised from the handwriting in Kindle Scribe notebook “\(escapeMarkdown(notebook.path))” "
                + "(\(pages.count) page\(pages.count == 1 ? "" : "s"), last changed \(stamp(modified))). "
                + "The notebook is the source of truth: edits made to this file are overwritten.*",
            "*\(syncMarker(notebook.id))*",
            "",
        ]
        return out.joined(separator: "\n")
    }

    // MARK: Reading a transcript back

    /// One transcript line for display: the task text is split out when the
    /// line carries a TODO marker.
    public struct Line: Equatable, Sendable {
        public var before: String
        public var task: String?
        public var text: String { task.map { before + "TODO: " + $0 } ?? before }
    }

    public struct Page: Equatable, Sendable {
        public var number: Int
        public var paragraphs: [[Line]]
        /// Line index of the `## Page N` heading in the file.
        public var headingLine: Int
        public var isEmpty: Bool { paragraphs.isEmpty }
    }

    public struct Parsed: Equatable, Sendable {
        public var title: String
        public var pages: [Page]
        public var syncID: String?
        /// Every recognised line as plain text, for the copy affordance.
        public var plainText: String {
            pages.map { page in
                (["Page \(page.number)"] + page.paragraphs.map { $0.map(\.text).joined(separator: "\n") }).joined(separator: "\n\n")
            }.joined(separator: "\n\n")
        }
    }

    public static func parse(_ text: String) -> Parsed {
        var title = ""
        var pages: [Page] = []
        var syncID: String?
        var current: Page?
        var paragraph: [Line] = []
        var inFooter = false
        func closeParagraph() {
            if !paragraph.isEmpty { current?.paragraphs.append(paragraph); paragraph = [] }
        }
        func closePage() {
            closeParagraph()
            if let p = current { pages.append(p) }
            current = nil
        }
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            if inFooter {
                if let r = raw.range(of: #"Sync ID (\S+)"#, options: .regularExpression) {
                    syncID = String(raw[r].dropFirst("Sync ID ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                }
                continue
            }
            if index == 0, raw.hasPrefix("# ") { title = unescapeMarkdown(String(raw.dropFirst(2))); continue }
            if raw == "---" { closePage(); inFooter = true; continue }
            if raw.hasPrefix("## Page "), let n = Int(raw.dropFirst("## Page ".count)) {
                closePage()
                current = Page(number: n, paragraphs: [], headingLine: index)
                continue
            }
            guard current != nil else { continue }
            if raw.isEmpty { closeParagraph(); continue }
            if raw == "*No handwriting recognised on this page.*" { continue }
            paragraph.append(parseLine(raw))
        }
        closePage()
        return Parsed(title: title, pages: pages, syncID: syncID)
    }

    static func parseLine(_ raw: String) -> Line {
        if let r = raw.range(of: todoMark) {
            let task = raw[r.upperBound...].drop(while: { $0 == " " })
            return Line(before: unescapeMarkdown(String(raw[..<r.lowerBound])), task: unescapeMarkdown(String(task)))
        }
        return Line(before: unescapeMarkdown(raw), task: nil)
    }

    /// The page a file line belongs to (1-based), for search hits.
    public static func pageNumber(forLine line: Int, in parsed: Parsed) -> Int? {
        parsed.pages.last { $0.headingLine <= line }?.number
    }
}
