import Foundation
import FoolscapStore

/// Where recognised TODOs go. Returns false when the task was already there
/// (the sync state was lost), so it is not counted as added.
public protocol TaskSink: Sendable {
    func add(_ todo: Todo, source: String) async -> Bool
}

/// Decides which recognised TODOs are new. A task is delivered once: ticking
/// it off, rewording or deleting it afterwards never brings it back.
public enum TodoLedger {
    public struct Outcome: Equatable, Sendable {
        public var added: Int
        public var known: [String: TodoRecord]
    }

    /// `source` names the notebook in the task's note line ("From <source>, p. N").
    public static func sync(found todos: [Todo], known previous: [String: TodoRecord], source: String,
                            sink: any TaskSink, now: Date = Date()) async -> Outcome {
        var known = previous
        var found: [(key: String, todo: Todo)] = []
        for todo in todos {
            let key = ScribeTodos.todoKey(todo.text)
            if !found.contains(where: { $0.key == key }) { found.append((key, todo)) }
        }
        let foundKeys = Set(found.map(\.key))
        var vanished = known.keys.filter { !foundKeys.contains($0) }.sorted()
        var added = 0
        for (key, todo) in found {
            if key.isEmpty || known[key] != nil { continue }
            // Re-rendered handwriting can be read a little differently. If a known
            // TODO has just vanished and this one is nearly identical, it is the same line.
            if let twin = vanished.first(where: { SequenceMatcher.ratio($0, key) >= sameTodoRatio }) {
                vanished.removeAll { $0 == twin }
                known[key] = known.removeValue(forKey: twin)
                continue
            }
            if await sink.add(todo, source: source) { added += 1 }
            known[key] = TodoRecord(text: todo.text, page: todo.page, addedAt: now)
        }
        return Outcome(added: added, known: known)
    }
}

/// Appends tasks to the notebook's `Tasks.md`, tagged `#scribe`, with a note
/// line saying where they came from.
public struct LibraryTaskSink: TaskSink {
    public static let tag = "scribe"
    let library: NotebookLibrary
    public init(library: NotebookLibrary) { self.library = library }

    public func add(_ todo: Todo, source: String) async -> Bool {
        await MainActor.run {
            library.addStandaloneTask("\(todo.text) #\(Self.tag)", notes: "From \(source), p. \(todo.page)", skipIfPresent: true)
        }
    }
}
