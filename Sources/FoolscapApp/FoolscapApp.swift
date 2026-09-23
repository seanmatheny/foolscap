import SwiftUI
import FoolscapCore
import FoolscapUI

@main
struct FoolscapApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Foolscap") {
            RootView()
                .environment(model)
                .environment(\.notebookTheme, model.theme)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 760)

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
        }
        .padding(20)
        .frame(width: 420)
    }
}
