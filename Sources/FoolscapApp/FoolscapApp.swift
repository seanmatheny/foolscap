import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var flush: (() -> Void)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.flush?()
        return .terminateNow
    }
    func applicationDidResignActive(_ notification: Notification) { AppDelegate.flush?() }
}

@main
struct FoolscapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Foolscap") {
            RootView()
                .environment(model)
                .onAppear { AppDelegate.flush = { model.flush() } }
                .environment(\.notebookTheme, model.theme)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Go") {
                Button("Today") { model.showDailyNotes(); model.dailyNotes?.goToday() }.keyboardShortcut("t")
                Button("Previous Day") { model.showDailyNotes(); model.dailyNotes?.go(days: -1) }.keyboardShortcut("[")
                Button("Next Day") { model.showDailyNotes(); model.dailyNotes?.go(days: 1) }.keyboardShortcut("]")
                Divider()
                Button("Daily Notes") { model.selectedSectionID = "daily" }.keyboardShortcut("1")
                Button("Tasks") { model.selectedSectionID = "tasks" }.keyboardShortcut("2")
            }
            CommandMenu("Debug") {
                Button("Rebuild Index") { model.rebuildIndex() }
                Button("Save Now") { model.flush() }.keyboardShortcut("s")
            }
        }

        Settings {
            PreferencesRoot()
                .environment(model)
                .environment(\.notebookTheme, model.theme)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NotebookView(tabs: model.tabs, selection: $model.selectedSectionID) { id in
            if let section = model.section(id: id) {
                section.makeRootView()
            } else {
                Text("No section").foregroundStyle(.secondary)
            }
        }
    }
}

struct PreferencesRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Picker("Theme", selection: $model.themeID) {
                ForEach(NotebookTheme.builtIn) { Text($0.name).tag($0.id) }
            }
            LabeledContent("Notebook folder") {
                HStack {
                    Text(model.notesFolderPath).truncationMode(.middle).lineLimit(1)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        panel.directoryURL = URL(fileURLWithPath: model.notesFolderPath)
                        if panel.runModal() == .OK, let url = panel.url { model.changeNotesFolder(to: url) }
                    }
                }
            }
        }
        .onAppear { AppDelegate.flush = { model.flush() } }
        .padding(20)
        .frame(width: 420)
    }
}
