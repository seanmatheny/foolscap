import SwiftUI

/// Where a change to a task's state registers its undo: the notebook window's
/// undo manager, which the editor shares, so ⌘Z (Edit ▸ Undo) steps back through
/// task moves, ticks and Jira suns the same way as through typing.
@MainActor
public enum TaskUndo {
    public static var manager: UndoManager? {
        override ?? NSApp?.mainWindow?.undoManager ?? NSApp?.keyWindow?.undoManager
    }
    /// Tests, which have no window, hand in a manager of their own.
    public static var override: UndoManager?

    /// The Edit menu's wording for a move into `status`.
    public static func actionName(for status: TaskStatus, from previous: TaskStatus? = nil) -> String {
        switch status {
        case .completed: return "Mark Done"
        case .notStarted: return previous == .completed ? "Mark Not Done" : "Move to To do"
        default: return "Move to \(status.title)"
        }
    }
}
