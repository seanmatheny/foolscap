import SwiftUI
import FoolscapCore
import FoolscapUI

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

    var theme: NotebookTheme { NotebookTheme.builtIn(id: themeID) ?? .classicBlack }
    var tabs: [NotebookTabItem] { sections.map { NotebookTabItem(id: $0.id, appearance: $0.tab) } }

    init() {
        let defaults = UserDefaults.standard
        themeID = defaults.string(forKey: "themeID") ?? NotebookTheme.classicBlack.id
        selectedSectionID = defaults.string(forKey: "selectedSection") ?? "daily"
        sections = [PlaceholderSection(id: "daily", label: "Daily Notes", symbol: "calendar"),
                    PlaceholderSection(id: "tasks", label: "Tasks", symbol: "checklist")]
        if section(id: selectedSectionID) == nil { selectedSectionID = sections.first?.id ?? "" }
    }

    func section(id: String) -> (any NotebookSection)? { sections.first { $0.id == id } }
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
    let label: String
    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(label).font(.system(size: 26, weight: .bold, design: .serif))
                Text("Coming in the next phase.").font(.system(size: 15, design: .serif)).opacity(0.6)
                Spacer()
            }
            .foregroundStyle(theme.ink.color)
            .padding(EdgeInsets(top: 34, leading: 64, bottom: 24, trailing: 40))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
