import Foundation

/// What a markdown line is, decided by a single forward scan of the document.
public enum BlockKind: Equatable, Sendable {
    case blank
    case plain
    case heading(level: Int)
    case listItem
    case task(status: TaskStatus)
    case quote
    case fenceOpen(language: String)
    case fenceInside
    case fenceClose
    /// A line that is only an image reference: `![alt](path)`.
    case imageLine(alt: String, path: String)
    /// A line that is only a bare URL.
    case urlLine(String)
    case rule
}

public struct ScannedLine: Equatable, Sendable {
    public var index: Int
    /// UTF-16 range of the line's content, excluding the newline.
    public var range: NSRange
    public var kind: BlockKind
    public var text: String
}

/// Line-level structure of a note. Cheap enough to rebuild on every edit for
/// day-sized files; the editor uses it for paragraph styling and the parser
/// for tasks.
public struct BlockMap: Sendable {
    public private(set) var lines: [ScannedLine]

    public init(lines: [ScannedLine]) { self.lines = lines }

    private static let imageRegex = try! NSRegularExpression(pattern: #"^\s*!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$"#)
    private static let urlRegex = try! NSRegularExpression(pattern: #"^\s*<?(https?://[^\s<>]+)>?\s*$"#)
    private static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})\s+\S"#)
    private static let listRegex = try! NSRegularExpression(pattern: #"^\s*([-*+]|\d+[.)])\s+\S"#)
    private static let fenceRegex = try! NSRegularExpression(pattern: #"^\s{0,3}(```+|~~~+)\s*([\w+#.-]*)"#)
    private static let ruleRegex = try! NSRegularExpression(pattern: #"^\s{0,3}([-*_])(\s*\1){2,}\s*$"#)

    public static func scan(_ text: String) -> BlockMap {
        let ns = text as NSString
        var lines: [ScannedLine] = []
        var location = 0
        var index = 0
        var fence: String? = nil
        let length = ns.length
        while true {
            if location >= length {
                // Empty document, or the empty line after a trailing newline.
                lines.append(ScannedLine(index: index, range: NSRange(location: length, length: 0),
                                         kind: classify("", fence: &fence), text: ""))
                break
            }
            var lineEnd = 0, contentsEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            let range = NSRange(location: location, length: contentsEnd - location)
            let line = ns.substring(with: range)
            lines.append(ScannedLine(index: index, range: range, kind: classify(line, fence: &fence), text: line))
            index += 1
            if lineEnd == contentsEnd { break }   // last line has no newline terminator
            location = lineEnd
        }
        return BlockMap(lines: lines)
    }

    private static func classify(_ line: String, fence: inout String?) -> BlockKind {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let open = fence {
            if let m = fenceRegex.firstMatch(in: line, range: full),
               ns.substring(with: m.range(at: 1)).hasPrefix(String(open.first!)),
               m.range(at: 1).length >= open.count,
               ns.substring(with: m.range(at: 2)).isEmpty {
                fence = nil
                return .fenceClose
            }
            return .fenceInside
        }
        if let m = fenceRegex.firstMatch(in: line, range: full) {
            fence = ns.substring(with: m.range(at: 1))
            return .fenceOpen(language: ns.substring(with: m.range(at: 2)))
        }
        if line.trimmingCharacters(in: .whitespaces).isEmpty { return .blank }
        if let m = headingRegex.firstMatch(in: line, range: full) { return .heading(level: m.range(at: 1).length) }
        if ruleRegex.firstMatch(in: line, range: full) != nil { return .rule }
        if let m = imageRegex.firstMatch(in: line, range: full) {
            return .imageLine(alt: ns.substring(with: m.range(at: 1)), path: ns.substring(with: m.range(at: 2)))
        }
        if let m = urlRegex.firstMatch(in: line, range: full) { return .urlLine(ns.substring(with: m.range(at: 1))) }
        if line.hasPrefix(">") { return .quote }
        if let task = TaskLineParser.parse(line) { return .task(status: task.status) }
        if listRegex.firstMatch(in: line, range: full) != nil { return .listItem }
        return .plain
    }

    /// The line containing a UTF-16 offset.
    public func line(at offset: Int) -> ScannedLine? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = lines[mid].range
            if offset < r.location { hi = mid - 1 }
            else if offset > r.location + r.length { lo = mid + 1 }
            else { return lines[mid] }
        }
        return lines.last
    }
}
