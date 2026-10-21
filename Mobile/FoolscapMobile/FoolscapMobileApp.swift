import SwiftUI
import UniformTypeIdentifiers
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI
import FoolscapSections
import FoolscapJira
import FoolscapSecrets
import FoolscapHighlights
import FoolscapScribe

/// The iPhone app: the shared app model over the notebook folder the Files picker
/// granted (the app's own Documents until one is chosen), the Daily Notes and
/// Tasks sections on the notebook chrome sized for a phone, and a Settings tab.
@main
struct FoolscapMobileApp: App {
    init() {
        // The page's text column: narrower leather on a phone leaves it this much
        // (the margin rule sits 16 pt left of the text, still clear of the page edge).
        PageRuling.textLeft = 28
        PageRuling.textRight = 14
        // The text scale once followed the Mac's; it is the phone's own now, and the
        // Mac's 0.85 that may already be here goes back to full size, once.
        if !UserDefaults.standard.bool(forKey: "phoneTextScaleReset") {
            UserDefaults.standard.set(1.0, forKey: PreferenceKeys.textScale)
            UserDefaults.standard.set(true, forKey: "phoneTextScaleReset")
        }
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
    /// The Jira tab is a hard toggle, as on the Mac: off means no section, no requests.
    private(set) var jiraEnabled = false
    private(set) var jiraSection: JiraSection?
    /// The Secrets tab likewise: off means no section, no vault read.
    private(set) var secretsEnabled = false
    private(set) var secretsSection: SecretsSection?
    /// The Highlights tab: reading only on the phone (the Mac imports from the Kindle app).
    private(set) var highlightsEnabled = false
    private(set) var highlightsSection: HighlightsSection?
    /// The day's highlights lie on a loose page over the notebook until tapped away.
    var flyleafPresented = false
    /// The Scribe tab: reading only on the phone (the Mac syncs and reads the handwriting).
    private(set) var scribeEnabled = false
    private(set) var scribeSection: ScribeSection?

    init() {
        let bookmarked = BookmarkedFolder.resolve()
        usingLocalFolder = bookmarked == nil
        super.init(notesFolder: bookmarked ?? NotesFolder.defaultRoot)
        followSettingChanged()
        watchForChanges()
        setJiraEnabled(UserDefaults.standard.bool(forKey: "jiraEnabled"))
        setSecretsEnabled(UserDefaults.standard.bool(forKey: SecretsSection.enabledKey))
        setHighlightsEnabled(UserDefaults.standard.bool(forKey: "highlightsEnabled"))
        setScribeEnabled(UserDefaults.standard.bool(forKey: "scribeEnabled"))
        flyleafPresented = highlightsEnabled && UserDefaults.standard.bool(forKey: "flyleafOnOpen")
        // The Jira page's "Open Settings…" turns to the Settings tab.
        JiraSection.openSettings = { [weak self] in self?.selectedSectionID = RootView.settingsTab.id }
    }

    /// Add or remove the Jira section at runtime (`rewireSections` places it after Tasks).
    /// Nothing is indexed: it writes only task lines, through the library.
    func setJiraEnabled(_ on: Bool) {
        guard on != jiraEnabled, let library else { return }
        jiraEnabled = on
        if on {
            let jira = JiraSection(library: library)
            sections.append(jira)
            jiraSection = jira
            jira.start()
        } else {
            jiraSection?.stop()
            jiraSection = nil
            sections.removeAll { $0.id == JiraSection.sectionID }
            if selectedSectionID == JiraSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
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
    /// The text size is the phone's own: a window's scale is not a phone's.
    func applyMacAppearance() async {
        await applyFollowedAppearance(fontAvailable: { UIFont.familyNames.contains($0) }, textSize: false)
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

    /// Add or remove the Secrets section at runtime (`rewireSections` puts it last).
    /// Nothing is indexed: the vault never enters the library.
    func setSecretsEnabled(_ on: Bool) {
        guard on != secretsEnabled, let library else { return }
        secretsEnabled = on
        if on {
            let secrets = SecretsSection(library: library)
            sections.append(secrets)
            secretsSection = secrets
            secrets.start()
        } else {
            secretsSection?.stop()
            secretsSection = nil
            sections.removeAll { $0.id == SecretsSection.sectionID }
            if selectedSectionID == SecretsSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
    }

    /// Add or remove the Scribe section at runtime, and everything derived from `sections`.
    func setScribeEnabled(_ on: Bool) {
        guard on != scribeEnabled, let library else { return }
        scribeEnabled = on
        if on {
            let scribe = ScribeSection(library: library)
            sections.append(scribe)
            scribeSection = scribe
            library.indexesScribe = true
            scribe.start()
        } else {
            scribeSection?.stop()
            scribeSection = nil
            sections.removeAll { $0.id == ScribeSection.sectionID }
            library.indexesScribe = false
            if selectedSectionID == ScribeSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
    }

    /// Add or remove the Highlights section at runtime (`rewireSections` places it).
    func setHighlightsEnabled(_ on: Bool) {
        guard on != highlightsEnabled, let library else { return }
        highlightsEnabled = on
        if on {
            let highlights = HighlightsSection(library: library)
            highlights.turnToTab = { [weak self] in
                guard let self, self.selectedSectionID != HighlightsSection.sectionID else { return false }
                self.selectedSectionID = HighlightsSection.sectionID
                return true
            }
            sections.append(highlights)
            highlightsSection = highlights
            library.indexesHighlights = true
            highlights.start()
        } else {
            highlightsSection?.stop()
            highlightsSection = nil
            sections.removeAll { $0.id == HighlightsSection.sectionID }
            library.indexesHighlights = false
            flyleafPresented = false
            if selectedSectionID == HighlightsSection.sectionID { selectedSectionID = sections.first?.id ?? "" }
        }
        rewireSections()
    }

    override func defaultsChanged() {
        super.defaultsChanged()
        let role: AppearanceRole = followsMac ? .follower : .independent
        if role != appearanceRole { followSettingChanged() }
        let jira = UserDefaults.standard.bool(forKey: "jiraEnabled")
        if jira != jiraEnabled { setJiraEnabled(jira) }
        let secrets = UserDefaults.standard.bool(forKey: SecretsSection.enabledKey)
        if secrets != secretsEnabled { setSecretsEnabled(secrets) }
        let highlights = UserDefaults.standard.bool(forKey: "highlightsEnabled")
        if highlights != highlightsEnabled { setHighlightsEnabled(highlights) }
        let scribe = UserDefaults.standard.bool(forKey: "scribeEnabled")
        if scribe != scribeEnabled { setScribeEnabled(scribe) }
    }

    override func sectionSelectionChanged(from old: String) {
        if old == SecretsSection.sectionID, selectedSectionID != old { secretsSection?.didLeaveTab() }
        if selectedSectionID == SecretsSection.sectionID, selectedSectionID != old { secretsSection?.didEnterTab() }
        // Going somewhere turns the flyleaf away.
        if flyleafPresented { flyleafPresented = false }
    }

    /// Going to the background: the vault locks (and saves) first.
    override func flush() {
        secretsSection?.lockNow()
        highlightsSection?.stop()
        scribeSection?.stop()
        super.flush()
    }

    override func save() {
        secretsSection?.saveIfDirty()
        super.save()
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
    static let settingsTab = NotebookTabItem(id: "settings", appearance: TabAppearance(label: "Settings", systemImage: "gearshape", colorIndex: 5))

    var body: some View {
        @Bindable var model = model
        let tabsLeft = model.tabEdge == .left
        GeometryReader { geo in
            NotebookView(tabs: model.tabs + [Self.settingsTab], selection: $model.selectedSectionID, looseLeaf: $model.flyleafPresented) { id in
                if id == Self.settingsTab.id {
                    PhoneSettingsPage(model: model, choosingFolder: $choosingFolder)
                } else if let section = model.section(id: id) {
                    section.makeRootView()
                } else {
                    Text("No section").foregroundStyle(.secondary)
                }
            }
            // The flyleaf (the day's three highlights) lies on the notebook until tapped away.
            .overlay {
                if model.flyleafPresented, let highlights = model.highlightsSection {
                    PageTurnOverlay(isPresented: $model.flyleafPresented) { highlights.makeFlyleafView() }
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
        .environment(\.compactPage, true)
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
    @AppStorage(PreferenceKeys.textScale) private var textScale = 1.0
    @AppStorage("jiraEnabled") private var jiraEnabled = false
    @AppStorage(SecretsSection.enabledKey) private var secretsEnabled = false
    @AppStorage("highlightsEnabled") private var highlightsEnabled = false
    @AppStorage("flyleafOnOpen") private var flyleafOnOpen = false
    @AppStorage("scribeEnabled") private var scribeEnabled = false

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
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $textScale, in: 0.8...1.6, step: 0.05)
                        Text("\(Int((textScale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("The phone's own, whatever the Mac uses.").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                NotebookSettingsSections(themeID: $model.themeID)
                PensSettings(knownTags: model.library?.knownTags ?? [])
            }
            .disabled(followsMac)
            .opacity(followsMac ? 0.55 : 1)
            Section("Jira") {
                Toggle("Connect to Jira Cloud", isOn: $jiraEnabled)
                Text("Adds a Jira tab listing the issues assigned to you. Off, nothing runs: no requests, no tab. The token is this phone's own, kept in its Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.sectionSettingsPanes.filter { $0.id == JiraSection.sectionID }) { pane in pane.view }
            }
            Section("Kindle Scribe") {
                Toggle("Show Kindle Scribe notebooks", isOn: $scribeEnabled)
                Text("Adds a Scribe tab: the handwritten notebooks the Mac syncs into the notebook folder, ink beside transcript. The phone reads the files; it does not sync.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.sectionSettingsPanes.filter { $0.id == ScribeSection.sectionID }) { pane in pane.view }
            }
            Section("Highlights") {
                Toggle("Show Kindle highlights", isOn: $highlightsEnabled)
                Text("Adds a Highlights tab: the books and quotes the Mac has imported from its Kindle app, three of them a day. The phone reads the files; it does not import.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open on today's highlights", isOn: $flyleafOnOpen)
                    .disabled(!highlightsEnabled)
                ForEach(model.sectionSettingsPanes.filter { $0.id == HighlightsSection.sectionID }) { pane in pane.view }
            }
            Section("Secrets") {
                Toggle("Keep secrets in the notebook", isOn: $secretsEnabled)
                Text("Adds a padlocked Secrets tab: the vault file in the notebook folder, opened on the phone with its recovery passphrase. Nothing in it is indexed or searchable from the other tabs.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.sectionSettingsPanes.filter { $0.id == SecretsSection.sectionID }) { pane in pane.view }
            }
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
