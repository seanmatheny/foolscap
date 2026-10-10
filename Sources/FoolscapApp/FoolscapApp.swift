import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI
import FoolscapSections
import FoolscapHighlights
import FoolscapEditor

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
            CommandMenu("Format") {
                Button(EditorCommand.bold.title) { EditorCommand.bold.perform() }.keyboardShortcut("b")
                Button(EditorCommand.italic.title) { EditorCommand.italic.perform() }.keyboardShortcut("i")
                Button(EditorCommand.strikethrough.title) { EditorCommand.strikethrough.perform() }.keyboardShortcut("x", modifiers: [.command, .shift])
                Button(EditorCommand.code.title) { EditorCommand.code.perform() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button(EditorCommand.link.title) { EditorCommand.link.perform() }.keyboardShortcut("k")
                Divider()
                Menu("Heading") {
                    Button(EditorCommand.heading1.title) { EditorCommand.heading1.perform() }.keyboardShortcut("1")
                    Button(EditorCommand.heading2.title) { EditorCommand.heading2.perform() }.keyboardShortcut("2")
                    Button(EditorCommand.heading3.title) { EditorCommand.heading3.perform() }.keyboardShortcut("3")
                    Button(EditorCommand.heading4.title) { EditorCommand.heading4.perform() }.keyboardShortcut("4")
                    Button(EditorCommand.heading5.title) { EditorCommand.heading5.perform() }.keyboardShortcut("5")
                    Button(EditorCommand.heading6.title) { EditorCommand.heading6.perform() }.keyboardShortcut("6")
                }
                Button(EditorCommand.bulletList.title) { EditorCommand.bulletList.perform() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button(EditorCommand.numberedList.title) { EditorCommand.numberedList.perform() }.keyboardShortcut("l", modifiers: [.command, .option])
                Button(EditorCommand.task.title) { EditorCommand.task.perform() }.keyboardShortcut("t", modifiers: [.command, .option])
                Button(EditorCommand.toggleTaskDone.title) { EditorCommand.toggleTaskDone.perform() }.keyboardShortcut(.return, modifiers: [.command])
                Button(EditorCommand.quote.title) { EditorCommand.quote.perform() }.keyboardShortcut("'", modifiers: [.command])
                Button(EditorCommand.codeBlock.title) { EditorCommand.codeBlock.perform() }.keyboardShortcut("c", modifiers: [.command, .option])
                Button(EditorCommand.horizontalRule.title) { EditorCommand.horizontalRule.perform() }.keyboardShortcut("-", modifiers: [.command, .option])
                Divider()
                Button(EditorCommand.foldSection.title) { EditorCommand.foldSection.perform() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button(EditorCommand.unfoldSection.title) { EditorCommand.unfoldSection.perform() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button(EditorCommand.foldAll.title) { EditorCommand.foldAll.perform() }.keyboardShortcut(.leftArrow, modifiers: [.command, .option, .shift])
                Button(EditorCommand.unfoldAll.title) { EditorCommand.unfoldAll.perform() }.keyboardShortcut(.rightArrow, modifiers: [.command, .option, .shift])
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
            CommandMenu("Secrets") {
                Button("Lock Secrets") { model.secretsSection?.lockNow() }
                    .keyboardShortcut("l", modifiers: [.command, .control])
                    .disabled(!(model.secretsSection?.isUnlocked ?? false))
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
        NotebookView(tabs: model.tabs, selection: $model.selectedSectionID, looseLeaf: $model.flyleafPresented) { id in
            if let section = model.section(id: id) {
                section.makeRootView()
            } else {
                Text("No section").foregroundStyle(.secondary)
            }
        }
        // The flyleaf lies on the notebook; the cover opens above both.
        .overlay {
            if model.flyleafPresented, let highlights = model.highlightsSection {
                PageTurnOverlay(isPresented: $model.flyleafPresented) { highlights.makeFlyleafView() }
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
