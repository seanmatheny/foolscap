import Foundation

/// One parsed task line: `- [ ] Buy milk #errands`.
public struct ParsedTaskLine: Equatable, Sendable {
    public var indent: Int
    public var bullet: String
    public var status: TaskStatus
    public var title: String
    public var tags: [String]
    /// UTF-16 offset of the mark character inside the line, for editing.
    public var markOffset: Int
}

public enum TaskLineParser {
    // ^(indent)(bullet)\s+\[(mark)\]\s+(title)
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-*+]|\d+[.)])[ \t]+\[([ xX/])\][ \t]+(.*)$"#)
    // A backslash before the # is an escape (Scribe transcripts escape OCR text), not a tag.
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"(?<![\w/#`\\])#([\p{L}\p{N}_][\p{L}\p{N}_\-/]*)"#)

    public static func parse(_ line: String) -> ParsedTaskLine? {
        let ns = line as NSString
        guard let m = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1))
        let bullet = ns.substring(with: m.range(at: 2))
        let mark = ns.substring(with: m.range(at: 3)).first!
        let title = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
        guard let status = TaskStatus(mark: mark), !title.isEmpty else { return nil }
        return ParsedTaskLine(indent: indent.count, bullet: bullet, status: status, title: title,
                              tags: tags(in: title), markOffset: m.range(at: 3).location)
    }

    public static func tags(in title: String) -> [String] {
        let stripped = stripInlineCode(title)
        let ns = stripped as NSString
        return tagRegex.matches(in: stripped, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).lowercased() }
    }

    public static func stripTags(from title: String) -> String {
        let ns = title as NSString
        let out = tagRegex.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Replace the status mark on a task line, keeping everything else byte-identical.
    public static func replacingStatus(in line: String, with status: TaskStatus) -> String? {
        guard let parsed = parse(line) else { return nil }
        let ns = line as NSString
        return ns.replacingCharacters(in: NSRange(location: parsed.markOffset, length: 1), with: String(status.mark))
    }

    // MARK: Priority

    /// `!`, `!!` or `!!!` at the very start of the title, with or without a space
    /// after it (`!Call Bob`, `!! Call Bob`); a fourth `!` makes it plain text.
    private static let priorityRegex = try! NSRegularExpression(pattern: #"^(!{1,3})(?!!)[ \t]*"#)

    public static func priority(in title: String) -> TaskPriority {
        let ns = title as NSString
        guard let m = priorityRegex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { return .none }
        return TaskPriority(marker: ns.substring(with: m.range(at: 1)))
    }

    public static func stripPriority(from title: String) -> String {
        let ns = title as NSString
        let out = priorityRegex.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The title with its marker replaced (or removed for `.none`).
    public static func settingPriority(_ priority: TaskPriority, in title: String) -> String {
        let rest = stripPriority(from: title)
        return priority == .none ? rest : priority.marker + " " + rest
    }

    /// The UTF-16 range of the marker inside a title, for styling.
    public static func priorityRange(in title: String) -> NSRange? {
        let ns = title as NSString
        return priorityRegex.firstMatch(in: title, range: NSRange(location: 0, length: ns.length))?.range(at: 1)
    }

    private static func stripInlineCode(_ s: String) -> String {
        var out = ""; var inCode = false
        for ch in s {
            if ch == "`" { inCode.toggle(); out.append(" "); continue }
            out.append(inCode ? " " : ch)
        }
        return out
    }
}

public extension TaskLineParser {
    /// A line that continues the task above it: indented, not blank, not itself a task.
    static func isContinuation(_ line: String) -> Bool {
        guard let first = line.first, first == " " || first == "\t" else { return false }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return parse(line) == nil
    }

    static func continuationText(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }
}
