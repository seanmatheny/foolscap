import SwiftUI
import FoolscapCore

extension JiraSection {
    /// One line for the page and the settings pane: error, offline, phase or last run.
    var statusText: String {
        if let error = status.lastError { return error }
        if status.isOffline && !status.isRunning { return "Offline; syncs when you reconnect" }
        if let phase = status.phase { return phase }
        guard let run = status.lastRun ?? state.lastSync else { return credentials == nil ? "" : "Not synced yet" }
        var text = "Synced " + DateFormatter.localizedString(from: run, dateStyle: .short, timeStyle: .short)
        if let r = status.lastReport, r.resolved > 0 { text += " · \(r.resolved) closed in Jira, ticked" }
        return text
    }
}

/// The Jira group in Settings, under the master toggle.
struct JiraSettingsPane: View {
    @Bindable var section: JiraSection
    @AppStorage(JiraSection.minutesKey) private var syncMinutes = JiraSection.defaultSyncMinutes
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var saveError: String?

    var body: some View {
        TextField("Site", text: $site, prompt: Text("https://your-site.atlassian.net"))
        TextField("Email", text: $email, prompt: Text("you@example.com"))
        SecureField("API token", text: $token,
                    prompt: Text(section.credentials == nil ? "Paste a token; it goes into your Keychain" : "In your Keychain; paste to replace"))
        Text("Save puts the token in the macOS login Keychain and keeps no copy: not in Foolscap's settings, its files or its backups. Foolscap reads it from the Keychain each time it syncs.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Save") {
                do {
                    try section.saveCredentials(site: site, email: email, token: token)
                    token = ""
                    saveError = nil
                } catch JiraClientError.unauthorised {
                    saveError = "Paste an API token."
                } catch {
                    saveError = "That does not look like a site address."
                }
            }
            .disabled(site.trimmingCharacters(in: .whitespaces).isEmpty || email.trimmingCharacters(in: .whitespaces).isEmpty
                      || (token.isEmpty && section.credentials == nil))
            Button("Forget") { section.clearCredentials(); token = "" }
                .disabled(section.credentials == nil)
            if section.credentials != nil { Text("Connected").foregroundStyle(.secondary) }
        }
        if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
        HStack(spacing: 4) {
            Link("Create an API token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
            Text("at Atlassian (one made for Foolscap, so it can be revoked on its own).")
        }
        .font(.caption).foregroundStyle(.secondary)
        Picker("Check Jira", selection: $syncMinutes) {
            Text("Every 15 minutes").tag(15)
            Text("Every 30 minutes").tag(30)
            Text("Every hour").tag(60)
            Text("Every 3 hours").tag(180)
            Text("Every 6 hours").tag(360)
            Text("Only when I ask").tag(0)
        }
        .onChange(of: syncMinutes) { _, _ in section.settingsChanged() }
        LabeledContent("Sync") {
            HStack {
                Button(section.status.isRunning ? "Syncing…" : "Sync Now") { section.syncNow() }
                    .disabled(section.status.isRunning || section.credentials == nil)
                Text(section.statusText).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        Text("The sun on an issue adds `- [/] KEY summary #jira` to Tasks.md with a link to the issue, so it sits under today's date. When Jira marks the issue Done, the next sync ticks the task. Ticking the task here does not change Jira.")
            .font(.caption).foregroundStyle(.secondary)
        .onAppear {
            site = section.site
            email = section.email
        }
    }
}
