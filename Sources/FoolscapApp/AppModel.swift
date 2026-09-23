import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI
import FoolscapSections
import FoolscapScribe

/// Wires the store, the section registry and user preferences together.
@MainActor
@Observable
final class AppModel {
    var sections: [any NotebookSection] = []
    var selectedSectionID: String {
        didSet { UserDefaults.standard.set(selectedSectionID, forKey: "selectedSection") }
    }
    var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: "themeID") }
    }
    private(set) var library: NotebookLibrary?
    private(set) var startupError: String?
    let search = SearchCoordinator()
    var showExport = false

    var theme: NotebookTheme { NotebookTheme.builtIn(id: themeID) ?? .classicBlack }
    var tabs: [NotebookTabItem] { sections.map { NotebookTabItem(id: $0.id, appearance: $0.tab) } }
    var notesFolderPath: String { library?.folder.root.path ?? "" }

    init() {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: "themeID") ?? NotebookTheme.classicBlack.id
        selectedSectionID = defaults.string(forKey: "selectedSection") ?? "daily"
        let root = defaults.string(forKey: "notesFolder").map { URL(fileURLWithPath: $0) } ?? NotesFolder.defaultRoot
        do {
            library = try NotebookLibrary(folder: NotesFolder(root: root))
        } catch {
            startupError = "Could not open notebook folder \(root.path): \(error.localizedDescription)"
        }
        if let library {
            let daily = DailyNotesSection(library: library)
            let tasks = TasksSection(library: library) { [weak self] route in
                guard let self else { return }
                self.selectedSectionID = "daily"
                daily.navigate(to: route)
            }
            sections = [daily, tasks]
            // The Scribe seam is opt-in until the real module lands.
            if CommandLine.arguments.contains("--scribe-stub") || defaults.bool(forKey: "scribeStub") {
                sections.append(ScribeSection())
            }
            tasks.aggregator.setProviders(sections.compactMap(\.taskProvider))
            search.setSections(sections)
            search.navigate = { [weak self] sectionID, route in
                guard let self else { return }
                self.selectedSectionID = sectionID
                self.section(id: sectionID)?.navigate(to: route)
            }
        }
        if section(id: selectedSectionID) == nil { selectedSectionID = sections.first?.id ?? "" }
        // `Foolscap --day 2026-09-22` opens on a given day (handy for scripted screenshots).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--day"), i + 1 < args.count, let day = DayKey(args[i + 1]) {
            dailyNotes?.selectedDay = day
            selectedSectionID = "daily"
        }
        if let i = args.firstIndex(of: "--search"), i + 1 < args.count {
            search.open(with: args[i + 1])
        }
        if args.contains("--export") { showExport = true }
    }

    func section(id: String) -> (any NotebookSection)? { sections.first { $0.id == id } }

    func changeNotesFolder(to url: URL) {
        do {
            if let library {
                try library.open(folder: NotesFolder(root: url))
            } else {
                library = try NotebookLibrary(folder: NotesFolder(root: url))
                startupError = nil
            }
            UserDefaults.standard.set(url.path, forKey: "notesFolder")
        } catch {
            startupError = "Could not open \(url.path): \(error.localizedDescription)"
        }
    }

    var dailyNotes: DailyNotesSection? { section(id: "daily") as? DailyNotesSection }

    func showDailyNotes() { selectedSectionID = "daily" }

    func moveNotesFolder(to url: URL) {
        guard let library else { changeNotesFolder(to: url); return }
        Task {
            do {
                try await library.migrate(to: url)
                UserDefaults.standard.set(url.path, forKey: "notesFolder")
            } catch {
                startupError = "Could not move the notebook: \(error.localizedDescription)"
            }
        }
    }

    func rebuildIndex() {
        Task { await library?.rebuildIndex() }
    }

    func flush() { library?.flushAll() }
}

/// Phase 0 stand-in until the real sections exist.
@MainActor
final class PlaceholderSection: NotebookSection {
    let id: String
    let tab: TabAppearance
    init(id: String, label: String, symbol: String) {
        self.id = id
        self.tab = TabAppearance(label: label, systemImage: symbol)
    }
    func makeRootView() -> AnyView {
        AnyView(PlaceholderPage(label: tab.label))
    }
}

private struct PlaceholderPage: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(AppModel.self) private var model
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 26, weight: .bold, design: .serif))
            Text("Coming in the next phase.").font(.system(size: 15, design: .serif)).opacity(0.6)
            if let lib = model.library {
                Text("\(lib.days.count) daily notes in \(lib.folder.root.path) · index v\(lib.indexVersion)")
                    .font(.system(size: 12, design: .monospaced)).opacity(0.5)
            }
            if let err = model.startupError ?? model.library?.lastError {
                Text(err).foregroundStyle(.red)
            }
            Spacer()
        }
        .foregroundStyle(theme.ink.color)
        .padding(EdgeInsets(top: 34, leading: 64, bottom: 24, trailing: 40))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
