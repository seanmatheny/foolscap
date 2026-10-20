import SwiftUI
import UniformTypeIdentifiers
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI
import FoolscapSections

/// The iPhone app: the shared app model over the notebook folder the Files picker
/// granted (the app's own Documents until one is chosen), the Daily Notes and
/// Tasks sections on the notebook chrome sized for a phone, and a Settings tab.
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

/// The shared wiring plus the folder the Files picker granted and the Mac's look.
@MainActor @Observable
final class PhoneModel: AppModelCore {
    static let followKey = "followMacAppearance"
    /// No folder has been chosen yet: the notebook is the app's own Documents.
    private(set) var usingLocalFolder: Bool
    @ObservationIgnored private var changeWatch: Task<Void, Never>?

    init() {
        let bookmarked = BookmarkedFolder.resolve()
        usingLocalFolder = bookmarked == nil
        super.init(notesFolder: bookmarked ?? NotesFolder.defaultRoot)
        followSettingChanged()
        watchForChanges()
    }

    /// "Follow the Mac's appearance" (on unless turned off): the look comes from
    /// the file the Mac writes into the notebook folder.
    var followsMac: Bool { UserDefaults.standard.object(forKey: Self.followKey) as? Bool ?? true }

    func followSettingChanged() {
        appearanceRole = followsMac ? .follower : .independent
        if followsMac { Task { await applyMacAppearance() } }
    }

    /// Take the look from the file: at launch, when the app comes to the front and
    /// whenever the folder changes (iCloud landing the Mac's new file among them).
    func applyMacAppearance() async {
        await applyFollowedAppearance(fontAvailable: { UIFont.familyNames.contains($0) })
    }

    private func watchForChanges() {
        guard let library else { return }
        changeWatch = Task { [weak self] in
            for await _ in library.changes {
                guard let self else { return }
                await self.applyMacAppearance()
            }
        }
    }

    override func defaultsChanged() {
        super.defaultsChanged()
        let role: AppearanceRole = followsMac ? .follower : .independent
        if role != appearanceRole { followSettingChanged() }
    }

    /// Keep the folder the picker granted and open the notebook there.
    func useFolder(_ url: URL) {
        do {
            let resolved = try BookmarkedFolder.remember(url)
            changeNotesFolder(to: resolved)
            usingLocalFolder = false
        } catch {
            startupError = "Could not keep access to \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = PhoneModel()
    @State private var choosingFolder = false
    @State private var offeringFolder = false
    /// The first-run offer to pick the iCloud folder has been shown.
    @AppStorage("folderOffered") private var folderOffered = false
    private static let settingsTab = NotebookTabItem(id: "settings", appearance: TabAppearance(label: "Settings", systemImage: "gearshape", colorIndex: 5))

    var body: some View {
        @Bindable var model = model
        let tabsLeft = model.tabEdge == .left
        GeometryReader { geo in
            NotebookView(tabs: model.tabs + [Self.settingsTab], selection: $model.selectedSectionID) { id in
                if id == Self.settingsTab.id {
                    PhoneSettingsPage(model: model, choosingFolder: $choosingFolder)
                } else if let section = model.section(id: id) {
                    section.makeRootView()
                } else {
                    Text("No section").foregroundStyle(.secondary)
                }
            }
            // The leather runs under the status bar and the home indicator; the page does not.
            .environment(\.notebookMetrics, NotebookMetrics.compact.insetBy(safeArea: geo.safeAreaInsets, tabsLeft: tabsLeft))
            .overlay(alignment: .top) { SearchOverlay(coordinator: model.search).padding(.top, geo.safeAreaInsets.top) }
        }
        .environment(\.notebookTheme, model.theme)
        .environment(\.notebookTabEdge, model.tabEdge)
        .environment(\.showsElasticBand, model.elasticBand)
        .environment(\.taskPens, model.pens)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.useFolder(url) }
        }
        .sheet(isPresented: $offeringFolder) {
            FolderOffer(choose: { offeringFolder = false; choosingFolder = true }, later: { offeringFolder = false })
                .environment(\.notebookTheme, model.theme)
        }
        .onAppear {
            if !folderOffered, model.usingLocalFolder { folderOffered = true; offeringFolder = true }
        }
        .onChange(of: scenePhase) { _, phase in
            // The app may be killed in the background: write what is dirty now.
            if phase == .background { model.flush() }
            if phase == .active { Task { await model.library?.checkForExternalChanges(); await model.applyMacAppearance() } }
        }
    }
}

/// Settings on a page of the notebook: the sections both apps share, the pens,
/// the notebook folder and the index.
struct PhoneSettingsPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var model: PhoneModel
    @Binding var choosingFolder: Bool

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    @AppStorage(PhoneModel.followKey) private var followsMac = true

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Follow the Mac's appearance", isOn: $followsMac)
                Text(followsMac
                     ? (model.followedAppearance == nil
                        ? "The Mac's Settings (theme, paper, type, pens) come with the notebook folder; none have arrived yet."
                        : "Theme, paper, type and pens are the Mac's; turn this off to choose them here.")
                     : "This phone keeps a look of its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                NotebookSettingsSections(themeID: $model.themeID)
                PensSettings(knownTags: model.library?.knownTags ?? [])
            }
            .disabled(followsMac)
            .opacity(followsMac ? 0.55 : 1)
            Section("Notebook folder") {
                Text(model.usingLocalFolder ? "This phone's own copy (not synced)" : model.notesFolderPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                Button("Choose Folder in Files…") { choosingFolder = true }
                Text("Pick the Foolscap folder in iCloud Drive to share the notebook with the Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.startupError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Index") {
                Button("Rebuild Index") { model.rebuildIndex() }
                Text(version).font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .tint(theme.accent.color)
    }
}

/// The first-run card: pick the iCloud folder now, or write in the phone's own copy for now.
struct FolderOffer: View {
    @Environment(\.notebookTheme) private var theme
    let choose: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 40)).foregroundStyle(theme.accent.color)
            Text("Where is your notebook?")
                .font(theme.type.heading.face(22, weight: .bold))
            Text("Choose the Foolscap folder in iCloud Drive and the phone writes the same notes as the Mac. Until then it keeps a copy of its own on this phone.")
                .font(theme.type.body.face(15))
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.dimInk.color)
            Button("Choose Folder in Files…", action: choose)
                .buttonStyle(.borderedProminent)
            Button("Later", action: later)
                .buttonStyle(.plain)
                .foregroundStyle(theme.dimInk.color)
        }
        .padding(28)
        .foregroundStyle(theme.ink.color)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.page.paperColor.color.ignoresSafeArea())
        .tint(theme.accent.color)
        .presentationDetents([.medium])
    }
}
