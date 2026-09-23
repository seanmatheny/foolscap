import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI
import FoolscapSections

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
            CommandGroup(after: .textEditing) {
                Button("Find in Note…") { FindCommands.perform(.showFindInterface) }.keyboardShortcut("f")
                Button("Find Next") { FindCommands.perform(.nextMatch) }.keyboardShortcut("g")
                Button("Find Previous") { FindCommands.perform(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Search Notebook…") { model.search.open() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
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
        .overlay(alignment: .top) {
            if model.search.isPresented {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001).contentShape(Rectangle())
                        .onTapGesture { model.search.isPresented = false }
                    SearchPalette(coordinator: model.search).padding(.top, 70)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.search.isPresented)
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
