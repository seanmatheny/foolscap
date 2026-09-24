import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI
import FoolscapSections

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the model exists: a synchronous save for quitting, an async one otherwise.
    static var flush: (() -> Void)?
    static var save: (() -> Void)?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.flush?()
        return .terminateNow
    }
    func applicationDidResignActive(_ notification: Notification) { AppDelegate.save?() }
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
        mainWindow.windowStyle(.hiddenTitleBar)
        Settings {
            PreferencesRoot()
                .environment(model)
                .environment(\.notebookTheme, model.theme)
                .environment(\.notebookTabEdge, model.tabEdge)
        }
    }

    var mainWindow: some Scene {
        WindowGroup("Foolscap") {
            RootView()
                .environment(model)
                .onAppear { AppDelegate.flush = { model.flush() }; AppDelegate.save = { model.save() } }
                .environment(\.notebookTheme, model.theme)
                .environment(\.notebookTabEdge, model.tabEdge)
                .environment(\.showsElasticBand, model.elasticBand)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .importExport) {
                Button("Export Notes…") { model.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Back Up Now…") { if let b = model.backup { BackupCommands.backUpNow(b) } }.disabled(model.backup == nil)
                Button("Restore from Backup…") { if let b = model.backup { BackupCommands.restore(b) } }.disabled(model.backup == nil)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Note…") { FindCommands.perform(.showFindInterface) }.keyboardShortcut("f")
                Button("Find Next") { FindCommands.perform(.nextMatch) }.keyboardShortcut("g")
                Button("Find Previous") { FindCommands.perform(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Search Notebook…") { model.search.open() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                ForEach(model.sections, id: \.id) { section in
                    if let c = section.tab.shortcut {
                        Button(section.tab.label) { model.selectedSectionID = section.id }
                            .keyboardShortcut(KeyEquivalent(c))
                    } else {
                        Button(section.tab.label) { model.selectedSectionID = section.id }
                    }
                }
                Divider()
                Button("Today") { model.showDailyNotes(); model.dailyNotes?.goToday() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Previous Day") { model.showDailyNotes(); model.dailyNotes?.go(days: -1) }.keyboardShortcut("[")
                Button("Next Day") { model.showDailyNotes(); model.dailyNotes?.go(days: 1) }.keyboardShortcut("]")
            }
            CommandMenu("Tasks") {
                Button("Quick Task…") { model.quickTask() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Text("Also \(HotKeyPreferences.quickTask?.display ?? "off") from any app")
            }
            CommandGroup(after: .toolbar) {
                Button("Bigger Text") { model.adjustTextScale(by: 0.1) }.keyboardShortcut("=", modifiers: [.command])
                Button("Smaller Text") { model.adjustTextScale(by: -0.1) }.keyboardShortcut("-", modifiers: [.command])
                Button("Actual Size") { model.adjustTextScale(by: 1 - model.textScale) }.keyboardShortcut("0", modifiers: [.command])
                Divider()
            }
            CommandMenu("Debug") {
                Button("Rebuild Index") { model.rebuildIndex() }
                Button("Save Now") { model.save() }
            }
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
        .overlay { CoverOpeningOverlay() }
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
        .sheet(isPresented: $model.showExport) {
            if let library = model.library {
                ExportPanel(library: library, currentDay: model.dailyNotes?.selectedDay ?? .today)
                    .environment(\.notebookTheme, model.theme)
            }
        }
    }
}

struct PreferencesRoot: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        PreferencesView(themeID: $model.themeID, notesFolderPath: model.notesFolderPath,
                        tabsSummary: model.tabsSummary, sectionPanes: model.sectionSettingsPanes,
                        backup: model.backup,
                        chooseFolder: { model.changeNotesFolder(to: $0) },
                        moveToFolder: { model.moveNotesFolder(to: $0) })
            .onAppear { AppDelegate.flush = { model.flush() }; AppDelegate.save = { model.save() } }
    }
}
