import Foundation

/// Inline markdown spans within one line. Ranges are UTF-16 offsets into the line.
public struct InlineToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case bold, italic, boldItalic, code, strikethrough
        case link(url: String)
        case tag(String)
        case url(String)
    }
    public var kind: Kind
    /// The whole token including delimiters.
    public var range: NSRange
    /// The visible content between delimiters.
    public var content: NSRange
    /// Delimiter/syntax ranges to dim.
    public var syntax: [NSRange]
}

public enum InlineTokenizer {
    private static let codeRegex = try! NSRegularExpression(pattern: #"(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)"#)
    private static let boldItalicRegex = try! NSRegularExpression(pattern: #"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    private static let boldRegex = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicRegex = try! NSRegularExpression(pattern: #"(?<![\*\w])(\*|_)(?=[^\s\*_])(.+?)(?<=[^\s\*_])\1(?![\*\w])"#)
    private static let strikeRegex = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let linkRegex = try! NSRegularExpression(pattern: #"(?<!!)\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
    private static let urlRegex = try! NSRegularExpression(pattern: #"(?<![\w\(\[])(https?://[^\s<>\)\]]+)"#)
    private static let tagRegex = try! NSRegularExpression(pattern: #"(?<![\w/#`])#([\p{L}\p{N}_][\p{L}\p{N}_\-/]*)"#)

    public static func tokenize(_ line: String) -> [InlineToken] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var tokens: [InlineToken] = []
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        func claim(_ t: InlineToken) { tokens.append(t); taken.append(t.range) }

        // Code spans first: nothing inside them is markup.
        for m in codeRegex.matches(in: line, range: full) {
            let d = m.range(at: 1).length
            claim(InlineToken(kind: .code, range: m.range,
                              content: NSRange(location: m.range.location + d, length: m.range.length - 2 * d),
                              syntax: [NSRange(location: m.range.location, length: d),
                                       NSRange(location: m.range.location + m.range.length - d, length: d)]))
        }
        for m in linkRegex.matches(in: line, range: full) where free(m.range) {
            let text = m.range(at: 1), url = m.range(at: 2)
            claim(InlineToken(kind: .link(url: ns.substring(with: url)), range: m.range, content: text,
                              syntax: [NSRange(location: m.range.location, length: 1),
                                       NSRange(location: text.location + text.length, length: m.range.location + m.range.length - text.location - text.length)]))
        }
        for m in urlRegex.matches(in: line, range: full) where free(m.range) {
            claim(InlineToken(kind: .url(ns.substring(with: m.range)), range: m.range, content: m.range, syntax: []))
        }
        for (regex, kind, d) in [(boldItalicRegex, InlineToken.Kind.boldItalic, 3), (boldRegex, .bold, 2), (strikeRegex, .strikethrough, 2)] {
            for m in regex.matches(in: line, range: full) where free(m.range) {
                claim(InlineToken(kind: kind, range: m.range,
                                  content: NSRange(location: m.range.location + d, length: m.range.length - 2 * d),
                                  syntax: [NSRange(location: m.range.location, length: d),
                                           NSRange(location: m.range.location + m.range.length - d, length: d)]))
            }
        }
        for m in italicRegex.matches(in: line, range: full) where free(m.range) {
            claim(InlineToken(kind: .italic, range: m.range,
                              content: NSRange(location: m.range.location + 1, length: m.range.length - 2),
                              syntax: [NSRange(location: m.range.location, length: 1),
                                       NSRange(location: m.range.location + m.range.length - 1, length: 1)]))
        }
        for m in tagRegex.matches(in: line, range: full) where free(m.range) {
            claim(InlineToken(kind: .tag(ns.substring(with: m.range(at: 1)).lowercased()), range: m.range,
                              content: m.range, syntax: []))
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }
}
