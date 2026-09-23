import Foundation

/// What the index stores about one note.
public struct ParsedNote: Sendable {
    public var title: String
    public var tasks: [TaskItem]
    public var links: [String]
    public var images: [String]
    /// Every #tag in the note (outside code), most frequent first.
    public var tags: [String]
}

public enum NoteParser {
    public static let dailyProviderID = "daily"

    public static func parse(_ text: String, path: String, day: DayKey?, providerID: String = dailyProviderID) -> ParsedNote {
        let map = BlockMap.scan(text)
        var title = day?.longTitle ?? (path as NSString).lastPathComponent
        var foundTitle = false
        var tasks: [TaskItem] = []
        var links: [String] = [], images: [String] = []
        var tagCounts: [String: Int] = [:]
        var inFence = false
        for line in map.lines {
            switch line.kind {
            case .fenceOpen: inFence = true
            case .fenceClose: inFence = false
            default: break
            }
            if !inFence, case .fenceInside = line.kind {} else if !inFence {
                for tag in TaskLineParser.tags(in: line.text) { tagCounts[tag, default: 0] += 1 }
            }
            // Indented text right under a task is its notes.
            if !inFence, let last = tasks.indices.last, tasks[last].source.line + (tasks[last].notes.map { $0.split(separator: "\n").count } ?? 0) + 1 == line.index,
               TaskLineParser.isContinuation(line.text) {
                let text = TaskLineParser.continuationText(line.text)
                tasks[last].notes = tasks[last].notes.map { $0 + "\n" + text } ?? text
                continue
            }
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
        let tags = tagCounts.keys.sorted { (tagCounts[$0]!, $1) > (tagCounts[$1]!, $0) }
        return ParsedNote(title: title, tasks: tasks, links: links, images: images, tags: tags)
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
