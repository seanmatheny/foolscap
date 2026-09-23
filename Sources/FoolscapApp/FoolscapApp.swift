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
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--prefs") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // Trigger the app menu's Settings… item, wherever SwiftUI wired it.
                let items = NSApp.mainMenu?.items.first?.submenu?.items ?? []
                if let item = items.first(where: { $0.title.hasPrefix("Settings") || $0.title.hasPrefix("Preferences") }) {
                    NSApp.sendAction(item.action ?? Selector(("showSettingsWindow:")), to: item.target, from: item)
                }
            }
        }
    }
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
        PreferencesView(themeID: $model.themeID, notesFolderPath: model.notesFolderPath) { model.changeNotesFolder(to: $0) }
            .onAppear { AppDelegate.flush = { model.flush() } }
    }
}
