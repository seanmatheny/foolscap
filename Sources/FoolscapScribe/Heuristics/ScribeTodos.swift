import Foundation

/// A handwritten task and the page it was found on.
public struct Todo: Equatable, Sendable {
    public var text: String
    public var page: Int
    public init(_ text: String, page: Int) { self.text = text; self.page = page }
}

public enum ScribeTodos {
    // Handwriting costs the recogniser the odd O (read as 0 or o), and a "TO DO" written
    // with a gap comes back as two words whose colon language correction drops
    // (none of Vision's ten readings kept it). So the marker is matched loosely where
    // the intent is unmistakable:
    //   "TODO: x", "TO DO x", "To Do - x", "T0DO; x", or a bare "TODO" heading, opening a
    //   line, delimiter optional: a capital T and a capital D tell it from "To do this",
    //   "Today" or "Todd";
    //   "to do: x" in any case opening a line, colon required;
    //   "... TODO: x" anywhere, upper case and colon required.
    // "TODO list…" is a heading: `extractTodos` takes the lines under it.
    private static let markers: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^(?<lead>\W*)T[Oo0][ \-]?D[Oo0]\b(?:\s*[:;.,\-–—]+)?\s*"#),
        try! NSRegularExpression(pattern: #"^(?<lead>\W*)to[\s-]?do\s*[:;]\s*"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"(?<lead>)\bT[O0][ \-]?D[O0]\s*[:;]\s*"#),
    ]
    private static let listHeading = try! NSRegularExpression(pattern: #"^lists?\b"#, options: .caseInsensitive)

    /// Bumped whenever the rules change, so notebooks are transcribed again (from
    /// the OCR cache) and tasks the old rules missed are found.
    public static let rulesVersion = "todo-rules/2"
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*(?:[-–—•*·▪◦‣+=]|\d{1,2}[.)])\s+"#)
    private static let whitespaceRun = try! NSRegularExpression(pattern: #"\s+"#)
    private static let keyNoise = try! NSRegularExpression(pattern: "[^a-z0-9]+")

    /// Split a line around its TODO marker: (text before, task text), or nil when
    /// the line carries no marker.
    public static func splitTodo(_ text: String) -> (before: String, task: String)? {
        let ns = text as NSString
        for marker in markers {
            if let m = marker.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                let lead = m.range(withName: "lead")
                let before = ns.substring(to: m.range.location) + (lead.location == NSNotFound ? "" : ns.substring(with: lead))
                return (before, ns.substring(from: m.range.location + m.range.length))
            }
        }
        return nil
    }

    static func isBulleted(_ text: String) -> Bool {
        bullet.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    public static func cleanTask(_ text: String) -> String {
        var out = bullet.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
        out = whitespaceRun.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: " ")
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—:;,"))
    }

    /// Find the tasks on every page:
    ///   - "TODO: wash the car" is one task;
    ///   - a TODO line that runs to the right-hand margin continues onto the next line;
    ///   - a bare "TODO:" (or "TODO list…") makes tasks of the bullets under it, or of
    ///     the one line under it.
    public static func extractTodos(_ pages: [[[TextLine]]]) -> [Todo] {
        var todos: [Todo] = []
        for (pageIndex, paragraphs) in pages.enumerated() {
            let pageNumber = pageIndex + 1
            for paragraph in paragraphs {
                var index = 0
                while index < paragraph.count {
                    let line = paragraph[index]
                    index += 1
                    guard let found = splitTodo(line.text) else { continue }

                    var tasks = [found.task]
                    let following = Array(paragraph[index...])
                    let isHeading = cleanTask(found.task).isEmpty
                        || listHeading.firstMatch(in: found.task, range: NSRange(location: 0, length: (found.task as NSString).length)) != nil
                    if isHeading {
                        tasks = []
                        let bulleted = following.first.map { isBulleted($0.text) } ?? false
                        for candidate in following {
                            if splitTodo(candidate.text) != nil || isBulleted(candidate.text) != bulleted { break }
                            tasks.append(candidate.text)
                            index += 1
                            if !bulleted { break }
                        }
                    } else if line.right >= wrapMargin, let candidate = following.first {
                        if splitTodo(candidate.text) == nil && !isBulleted(candidate.text) {
                            tasks = ["\(found.task) \(candidate.text)"]
                            index += 1
                        }
                    }

                    for task in tasks {
                        let cleaned = cleanTask(task)
                        let letters = cleaned.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
                        if letters >= 2 { todos.append(Todo(cleaned, page: pageNumber)) }
                    }
                }
            }
        }
        return todos
    }

    /// The identity of a task across OCR runs: lower case, letters and digits only.
    public static func todoKey(_ text: String) -> String {
        let lower = text.lowercased()
        return keyNoise.stringByReplacingMatches(in: lower, range: NSRange(location: 0, length: (lower as NSString).length), withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
