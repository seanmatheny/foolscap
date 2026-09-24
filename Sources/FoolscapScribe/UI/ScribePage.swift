import SwiftUI
import FoolscapCore
import FoolscapUI

/// The Scribe tab: folder sub-tabs across the top, a contents column of
/// notebooks, and the selected notebook filling the rest.
struct ScribePage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: ScribeSection

    private var pitch: CGFloat { theme.linePitch }

    var body: some View {
        Group {
            if !section.tree.hasNotebooks {
                emptyState
            } else {
                VStack(spacing: 0) {
                    FolderTabRow(tabs: section.folderTabs, selectedID: section.selectedFolderID) { section.select(folder: $0) }
                        .padding(.top, pitch)
                    HStack(alignment: .top, spacing: 0) {
                        ScribeContentsColumn(section: section)
                            .padding(.top, 4)
                        Rectangle().fill(theme.ink.color.opacity(0.12)).frame(width: 0.5).padding(.vertical, 8)
                        if let notebook = section.selectedNotebook {
                            ScribeNotebookView(section: section, notebook: notebook)
                                .id(notebook.id)
                                .padding(.leading, 18)
                        } else {
                            Text("Choose a notebook").font(.system(size: 15, design: .serif)).foregroundStyle(theme.dimInk.color)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .padding(.leading, 58)
                .padding(.trailing, 44)
            }
        }
        .foregroundStyle(theme.ink.color)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kindle Scribe").font(theme.type.heading.font).fontWeight(.bold)
            if section.status.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(section.status.phase ?? "Fetching your notebooks…")
                }
                .font(.system(size: 15, design: .serif)).foregroundStyle(theme.dimInk.color)
            } else if section.status.needsSignIn || !section.account.isSignedIn {
                Text("Sign in to Amazon once and your handwritten notebooks will appear here, with their text recognised and any TODO lines added to the Tasks tab.")
                    .font(.system(size: 15, design: .serif)).opacity(0.75)
                    .frame(maxWidth: 520, alignment: .leading)
                actionButton(section.account.isSigningIn ? "Waiting for sign-in…" : "Sign in to Amazon…") { section.signIn() }
                    .disabled(section.account.isSigningIn)
                Text("Use your password (and the one-time code if Amazon asks): passkeys only work in real browsers, not inside an app. Foolscap keeps the session afterwards.")
                    .font(.system(size: 12.5, design: .serif)).foregroundStyle(theme.dimInk.color)
                    .frame(maxWidth: 520, alignment: .leading)
                if let error = section.account.signInError { Text(error).font(.system(size: 13, design: .serif)).foregroundStyle(.red) }
            } else {
                Text("No notebooks yet.").font(.system(size: 15, design: .serif)).opacity(0.75)
                actionButton("Sync now") { section.syncNow() }
            }
            if let error = section.status.lastError {
                Text(error).font(.system(size: 13, design: .serif)).foregroundStyle(.red).frame(maxWidth: 520, alignment: .leading)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: pitch, leading: 58, bottom: 24, trailing: 44))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }
}

/// The Kindle Scribe group in Settings, under the master toggle.
struct ScribeSettingsPane: View {
    @Bindable var section: ScribeSection
    @AppStorage("scribeSyncMinutes") private var syncMinutes = ScribeSection.defaultSyncMinutes
    @AppStorage("scribeLanguages") private var languages = ScribeSection.defaultLanguages.joined(separator: ", ")

    var body: some View {
        LabeledContent("Amazon account") {
            HStack {
                if section.account.isSignedIn {
                    Text("Signed in").foregroundStyle(.secondary)
                    Button("Sign Out") { section.signOut() }
                } else {
                    Text("Not signed in").foregroundStyle(.secondary)
                    Button(section.account.isSigningIn ? "Waiting…" : "Sign In…") { section.signIn() }
                        .disabled(section.account.isSigningIn)
                }
            }
        }
        if let error = section.account.signInError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        Text("Sign in with your password and one-time code; passkeys are not available inside an app's web view.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("Check for changes", selection: $syncMinutes) {
            Text("Every 5 minutes").tag(5)
            Text("Every 15 minutes").tag(15)
            Text("Every 30 minutes").tag(30)
            Text("Every hour").tag(60)
            Text("Every 3 hours").tag(180)
        }
        .onChange(of: syncMinutes) { _, _ in section.settingsChanged() }
        TextField("Handwriting languages", text: $languages, prompt: Text("en-US, en-GB"))
        Text("Vision language codes, comma separated. Changing them re-reads every notebook on the next sync.")
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Sync") {
            HStack {
                Button(section.status.isRunning ? "Syncing…" : "Sync Now") { section.syncNow() }
                    .disabled(section.status.isRunning || !section.account.isSignedIn)
                Text(statusText).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        Text("Notebooks are saved as PDF and transcript in Scribe/ inside your notebook folder. Handwritten “TODO:” lines become #scribe tasks. Sync only runs while Foolscap is open; enable it on one Mac.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var statusText: String {
        if let error = section.status.lastError { return error }
        if let phase = section.status.phase { return phase }
        guard let run = section.status.lastRun ?? section.state.lastSync else { return "Never" }
        var text = "Last " + DateFormatter.localizedString(from: run, dateStyle: .short, timeStyle: .short)
        if let r = section.status.lastReport {
            text += " · \(r.rendered) fetched, \(r.transcribed) read, \(r.tasksAdded) task\(r.tasksAdded == 1 ? "" : "s") added"
        }
        return text
    }
}
