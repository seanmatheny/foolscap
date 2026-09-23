import Foundation

/// What the index stores about one note.
public struct ParsedNote: Sendable {
    public var title: String
    public var tasks: [TaskItem]
    public var links: [String]
    public var images: [String]
}

public enum NoteParser {
    public static let dailyProviderID = "daily"

    public static func parse(_ text: String, path: String, day: DayKey?, providerID: String = dailyProviderID) -> ParsedNote {
        let map = BlockMap.scan(text)
        var title = day?.longTitle ?? (path as NSString).lastPathComponent
        var foundTitle = false
        var tasks: [TaskItem] = []
        var links: [String] = [], images: [String] = []
        for line in map.lines {
            switch line.kind {
            case .heading where !foundTitle:
                title = line.text.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                foundTitle = true
            case .task:
                if let t = TaskLineParser.parse(line.text) {
                    tasks.append(TaskItem(providerID: providerID, title: t.title, status: t.status, tags: t.tags,
                                          indent: t.indent, source: TaskSource(path: path, line: line.index, day: day?.string)))
                }
            case .urlLine(let url): links.append(url)
            case .imageLine(_, let p): images.append(p)
            default: break
            }
        }
        return ParsedNote(title: title, tasks: tasks, links: links, images: images)
    }

    /// Body text for full-text indexing: fence markers and image syntax stripped.
    public static func indexableBody(_ text: String) -> String {
        BlockMap.scan(text).lines.compactMap { line -> String? in
            switch line.kind {
            case .fenceOpen, .fenceClose: return nil
            case .imageLine(let alt, _): return alt
            default: return line.text
            }
        }.joined(separator: "\n")
    }
}
