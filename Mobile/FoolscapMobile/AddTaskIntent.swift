import AppIntents
import FoolscapCore
import FoolscapStore

/// "Add a Task to Foolscap": the phone's quick task, the twin of the Mac's hot-key panel.
/// It runs in the app's own process (Shortcuts launches the app in the background when
/// it is not running; a widget would need an App Group the free team lacks), so Siri, the
/// Action button, Back Tap, a Control Center shortcut or the Lock Screen can jot a task
/// into Tasks.md without opening Foolscap. `#tags` and `!!` priority are taken as typed.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a Task"
    static let description = IntentDescription("Adds a task to Foolscap's Tasks tab. #tags and !! for priority are welcome.")
    static let openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: "What is the task?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to Foolscap")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AddTaskError.empty }
        let library: NotebookLibrary
        if let open = PhoneModel.current?.library {
            // The app is up (in front or in the background): its own library writes, so the
            // page and the index see the line at once.
            library = open
        } else {
            // The app's own copy stands in until a folder is chosen, as it does for the app.
            let root = BookmarkedFolder.resolve() ?? NotesFolder.defaultRoot
            library = try NotebookLibrary(folder: NotesFolder(root: root))
        }
        guard await library.addStandaloneTask(trimmed) else { throw AddTaskError.empty }
        return .result(dialog: "Added to Foolscap: \(trimmed)")
    }
}

enum AddTaskError: Error, CustomLocalizedStringResourceConvertible {
    case empty
    var localizedStringResource: LocalizedStringResource { "The task is empty." }
}

/// The phrases Siri and the Shortcuts app offer for the task.
struct FoolscapShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(),
                    phrases: ["Add a task to \(.applicationName)", "Add \(.applicationName) task", "New task in \(.applicationName)"],
                    shortTitle: "Add a Task",
                    systemImageName: "checklist")
    }
}
