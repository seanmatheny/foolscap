import SwiftUI
import FoolscapCore
import FoolscapUI

/// The iPhone app. For now the notebook chrome around placeholder pages: the
/// leather, the index tabs, the page and its curl, sized for a phone, until the
/// editor and the sections compile for iOS. The version shows on the page so a
/// glance tells whether the latest refresh landed.
@main
struct FoolscapMobileApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    private let theme = NotebookTheme.classicBlack
    private let tabs = [
        NotebookTabItem(id: "daily", appearance: TabAppearance(label: "Daily Notes", systemImage: "calendar")),
        NotebookTabItem(id: "tasks", appearance: TabAppearance(label: "Tasks", systemImage: "checklist")),
    ]
    @State private var selection = "daily"

    var body: some View {
        GeometryReader { geo in
            NotebookView(tabs: tabs, selection: $selection) { id in
                PlaceholderPage(title: tabs.first { $0.id == id }?.appearance.label ?? id)
            }
            // The leather runs under the status bar and the home indicator; the page does not.
            .environment(\.notebookMetrics, NotebookMetrics.compact.insetBy(safeArea: geo.safeAreaInsets, tabsLeft: true))
        }
        .environment(\.notebookTheme, theme)
        .environment(\.notebookTabEdge, .left)
    }
}

/// Stands in for a section's page.
struct PlaceholderPage: View {
    @Environment(\.notebookTheme) private var theme
    let title: String

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
            Spacer()
        }
        .padding(.leading, 36)
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
