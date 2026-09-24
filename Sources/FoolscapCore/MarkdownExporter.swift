import Foundation
import Markdown

/// Converts note markdown to HTML using swift-markdown, with Foolscap's task
/// marks (`[/]`) understood.
public enum MarkdownExporter {
    public static func html(fromMarkdown text: String, title: String) -> String {
        let document = Document(parsing: text)
        var walker = HTMLWalker()
        walker.visit(document)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body { font-family: Charter, Georgia, serif; max-width: 42em; margin: 3em auto; padding: 0 1em; line-height: 1.5; color: #2a2622; }
        code, pre { font-family: Menlo, monospace; font-size: 0.92em; }
        pre { background: #f2ede2; padding: 0.8em 1em; border-radius: 6px; overflow-x: auto; }
        blockquote { color: #6b645c; border-left: 3px solid #d8d0c0; margin-left: 0; padding-left: 1em; font-style: italic; }
        img { max-width: 100%; border-radius: 6px; }
        .task { list-style: none; margin-left: -1.2em; }
        .task.done { color: #8a847a; text-decoration: line-through; }
        .task.doing { background: rgba(247,216,66,0.45); }
        .tag { color: #9a3b2e; background: rgba(154,59,46,0.12); border-radius: 8px; padding: 0 0.4em; }
        hr { border: 0; border-top: 1px solid #d8d0c0; }
        </style></head><body>
        \(walker.output)
        </body></html>
        """
    }

    /// Markdown for a range of days joined with horizontal rules.
    public static func combinedMarkdown(_ notes: [(title: String, text: String)]) -> String {
        notes.map { $0.text.hasSuffix("\n") ? $0.text : $0.text + "\n" }.joined(separator: "\n---\n\n")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A small HTML renderer over swift-markdown's tree.
struct HTMLWalker: MarkupWalker {
    var output = ""

    mutating func defaultVisit(_ markup: Markup) { descendInto(markup) }

    mutating func visitDocument(_ d: Document) { descendInto(d) }
    mutating func visitHeading(_ h: Heading) { output += "<h\(h.level)>"; descendInto(h); output += "</h\(h.level)>\n" }
    mutating func visitParagraph(_ p: Paragraph) {
        // A paragraph that is only a URL becomes a link.
        if p.childCount == 1, let t = p.child(at: 0) as? Text, let url = URL(string: t.string.trimmingCharacters(in: .whitespaces)),
           ["http", "https"].contains(url.scheme ?? "") {
            output += "<p><a href=\"\(MarkdownExporter.escape(url.absoluteString))\">\(MarkdownExporter.escape(url.absoluteString))</a></p>\n"
            return
        }
        output += "<p>"; descendInto(p); output += "</p>\n"
    }
    mutating func visitText(_ t: Text) { output += tagged(MarkdownExporter.escape(t.string)) }
    mutating func visitEmphasis(_ e: Emphasis) { output += "<em>"; descendInto(e); output += "</em>" }
    mutating func visitStrong(_ s: Strong) { output += "<strong>"; descendInto(s); output += "</strong>" }
    mutating func visitStrikethrough(_ s: Strikethrough) { output += "<del>"; descendInto(s); output += "</del>" }
    mutating func visitInlineCode(_ c: InlineCode) { output += "<code>\(MarkdownExporter.escape(c.code))</code>" }
    mutating func visitCodeBlock(_ c: CodeBlock) {
        let lang = c.language.map { " class=\"language-\(MarkdownExporter.escape($0))\"" } ?? ""
        output += "<pre><code\(lang)>\(MarkdownExporter.escape(c.code))</code></pre>\n"
    }
    mutating func visitLink(_ l: Link) {
        output += "<a href=\"\(MarkdownExporter.escape(l.destination ?? ""))\">"; descendInto(l); output += "</a>"
    }
    mutating func visitImage(_ i: Image) {
        let alt = i.plainText
        output += "<img src=\"\(MarkdownExporter.escape(i.source ?? ""))\" alt=\"\(MarkdownExporter.escape(alt))\">"
    }
    mutating func visitSoftBreak(_ b: SoftBreak) { output += "\n" }
    mutating func visitLineBreak(_ b: LineBreak) { output += "<br>\n" }
    mutating func visitThematicBreak(_ b: ThematicBreak) { output += "<hr>\n" }
    mutating func visitBlockQuote(_ q: BlockQuote) { output += "<blockquote>\n"; descendInto(q); output += "</blockquote>\n" }
    mutating func visitUnorderedList(_ l: UnorderedList) { output += "<ul>\n"; descendInto(l); output += "</ul>\n" }
    mutating func visitOrderedList(_ l: OrderedList) { output += "<ol>\n"; descendInto(l); output += "</ol>\n" }
    mutating func visitListItem(_ item: ListItem) {
        // Task items: GFM gives us [ ] and [x]; our [/] arrives as literal text.
        var status: String? = nil
        var body = ""
        if let checkbox = item.checkbox { status = checkbox == .checked ? "done" : "todo" }
        var inner = HTMLWalker()
        for child in item.children { inner.visit(child) }
        body = inner.output
        if status == nil, body.hasPrefix("<p>[/] ") { status = "doing"; body = "<p>" + body.dropFirst("<p>[/] ".count) }
        if let status {
            let box = status == "done" ? "☑" : status == "doing" ? "◐" : "☐"
            output += "<li class=\"task \(status)\">\(box) \(body)</li>\n"
        } else {
            output += "<li>\(body)</li>\n"
        }
    }

    /// Wrap #tags in spans.
    nonisolated(unsafe) private static let tagPattern = try! NSRegularExpression(pattern: #"(?<![\w/#])#([\p{L}\p{N}_][\p{L}\p{N}_\-/]*)"#)

    private func tagged(_ escaped: String) -> String {
        Self.tagPattern.stringByReplacingMatches(in: escaped, range: NSRange(location: 0, length: (escaped as NSString).length),
                                              withTemplate: "<span class=\"tag\">#$1</span>")
    }
}
