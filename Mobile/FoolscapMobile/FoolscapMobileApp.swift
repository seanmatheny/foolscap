import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

/// The iPhone app. The notebook chrome sized for a phone, today's note in the
/// shared editor over a notebook in the app's own Documents folder (the iCloud
/// folder comes with the Files picker), and a placeholder for the Tasks tab until
/// the sections compile for iOS.
@main
struct FoolscapMobileApp: App {
    init() {
        // The page's text column: narrower leather on a phone leaves it this much.
        PageRuling.textLeft = 36
        PageRuling.textRight = 16
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The notebook and the sections it opens at.
@MainActor @Observable
final class PhoneModel {
    let library: NotebookLibrary?
    var startupError: String?

    init() {
        do {
            library = try NotebookLibrary(folder: NotesFolder(root: NotesFolder.defaultRoot))
        } catch {
            library = nil
            startupError = error.localizedDescription
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = PhoneModel()
    private let theme = NotebookTheme.classicBlack
    private let tabs = [
        NotebookTabItem(id: "daily", appearance: TabAppearance(label: "Daily Notes", systemImage: "calendar")),
        NotebookTabItem(id: "tasks", appearance: TabAppearance(label: "Tasks", systemImage: "checklist")),
    ]
    @State private var selection = "daily"

    var body: some View {
        GeometryReader { geo in
            NotebookView(tabs: tabs, selection: $selection) { id in
                if id == "daily", let library = model.library {
                    DailyPage(library: library)
                } else {
                    PlaceholderPage(title: tabs.first { $0.id == id }?.appearance.label ?? id, note: model.startupError)
                }
            }
            // The leather runs under the status bar and the home indicator; the page does not.
            .environment(\.notebookMetrics, NotebookMetrics.compact.insetBy(safeArea: geo.safeAreaInsets, tabsLeft: true))
        }
        .environment(\.notebookTheme, theme)
        .environment(\.notebookTabEdge, .left)
        .onChange(of: scenePhase) { _, phase in
            // The app may be killed in the background: write what is dirty now.
            if phase == .background { model.library?.flushAll() }
            if phase == .active { Task { await model.library?.checkForExternalChanges() } }
        }
    }
}

/// Today's note in the editor.
struct DailyPage: View {
    let library: NotebookLibrary

    var body: some View {
        let document = library.document(forDay: .today)
        MarkdownEditor(document: document) { library.scheduleSave() }
            .id(document.path)
    }
}

/// Stands in for a section's page.
struct PlaceholderPage: View {
    @Environment(\.notebookTheme) private var theme
    let title: String
    var note: String?

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(theme.type.heading.face(22, weight: .bold))
                .foregroundStyle(theme.accent.color)
            Text(version)
                .font(theme.type.body.face(15))
                .foregroundStyle(theme.dimInk.color)
            if let note {
                Text(note)
                    .font(theme.type.body.face(13))
                    .foregroundStyle(theme.dimInk.color)
            }
            Spacer()
        }
        .padding(.leading, 36)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
