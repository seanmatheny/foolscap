import SwiftUI

/// Where a change to a task's state registers its undo: the notebook window's
/// undo manager, which the editor shares, so ⌘Z (Edit ▸ Undo) steps back through
/// task moves, ticks and Jira suns the same way as through typing.
@MainActor
public enum TaskUndo {
    /// Whose undo manager that is. On the Mac the main (else key) window's; the
    /// iPhone app, which has no windows to ask, points it at its editor's.
    public static var provider: @MainActor () -> UndoManager? = {
        #if canImport(AppKit)
        NSApp?.mainWindow?.undoManager ?? NSApp?.keyWindow?.undoManager
        #else
        nil
        #endif
    }

    public static var manager: UndoManager? { provider() }

    /// The Edit menu's wording for a move into `status`.
    public static func actionName(for status: TaskStatus, from previous: TaskStatus? = nil) -> String {
        switch status {
        case .completed: return "Mark Done"
        case .notStarted: return previous == .completed ? "Mark Not Done" : "Move to To do"
        default: return "Move to \(status.title)"
        }
    }
}
