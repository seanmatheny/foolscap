import SwiftUI
import AppKit
import FoolscapCore

/// The Secrets group in Settings, under the master toggle.
struct SecretsSettingsPane: View {
    @Bindable var section: SecretsSection
    @AppStorage(SecretsSection.lockMinutesKey) private var lockMinutes = SecretsSection.defaultLockMinutes
    @AppStorage(SecretsSection.lockOnLeaveKey) private var lockOnLeave = false
    @AppStorage(SecretsSection.autoUnlockKey) private var autoUnlock = true
    @State private var showPassphraseChange = false
    @State private var newPassphrase = ""
    @State private var confirmation = ""
    @State private var message: String?

    private var minutes: Binding<Double> {
        Binding(get: { Double(lockMinutes) }, set: { lockMinutes = Int($0.rounded()) })
    }

    var body: some View {
        LabeledContent("Lock after") {
            HStack {
                Slider(value: minutes, in: 1...60, step: 1).frame(width: 200)
                Text("\(lockMinutes) min").monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        }
        .onChange(of: lockMinutes) { _, _ in section.settingsChanged() }
        Text("Minutes without a keystroke or click in Foolscap before the vault locks. It also locks at once when the Mac sleeps, the screen locks and Foolscap quits.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Lock when I turn to another tab", isOn: $lockOnLeave)
        Toggle("Ask for Touch ID when I turn to the tab", isOn: $autoUnlock)
            .disabled(!section.vault.hasDeviceWrap)
        LabeledContent("Touch ID") {
            HStack {
                Text(deviceStatus).foregroundStyle(.secondary)
                Button(section.vault.hasDeviceWrap ? "Re-enrol…" : "Enrol…") { enrol() }
                    .disabled(!section.isUnlocked)
            }
        }
        if let why = section.vault.deviceEnrolError {
            Text(why).font(.caption).foregroundStyle(.secondary)
        }
        LabeledContent("Recovery passphrase") {
            Button(showPassphraseChange ? "Keep the current one" : "Change…") { showPassphraseChange.toggle(); newPassphrase = ""; confirmation = "" }
                .disabled(!section.isUnlocked)
        }
        if showPassphraseChange {
            SecureField("New passphrase", text: $newPassphrase)
            SecureField("The same again", text: $confirmation)
            Button("Save passphrase") { changePassphrase() }
                .disabled(newPassphrase.count < 8 || newPassphrase != confirmation)
        }
        LabeledContent("Markdown") {
            HStack {
                Button("Import…") { importFile() }.disabled(!section.isUnlocked)
                Button("Export decrypted…") { export() }.disabled(!section.isUnlocked)
            }
        }
        Text(section.isUnlocked
             ? "Import adds the entries of a markdown file in the vault's own format: a heading per entry (`## Title #tags`; any heading level is taken), then `- label: value` lines, a value in backticks kept secret. Entries already in the vault are skipped. (The same text pasted into a new card does the same.) Export writes the vault's markdown as a plain, readable file: for moving on, not for keeping."
             : "Unlock Secrets in the notebook first to enrol Touch ID, change the passphrase, import or export.")
            .font(.caption).foregroundStyle(.secondary)
        Text(vaultStatus).font(.caption).foregroundStyle(.secondary)
        if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
    }

    private var deviceStatus: String {
        guard let store = section.vault.deviceStore else { return "No device key store" }
        if section.vault.hasDeviceWrap { return "Enrolled with \(store.displayName)" }
        return section.vault.state == .absent ? "Set up with the vault" : "Not enrolled on this Mac"
    }

    private var vaultStatus: String {
        let vault = section.vault
        switch vault.state {
        case .absent: return "No vault yet: the Secrets tab makes one."
        case .failed(let why): return why
        default:
            var parts = ["Vault: \(vault.url.path)", ByteCountFormatter.string(fromByteCount: Int64(vault.byteCount), countStyle: .file)]
            if let header = vault.header { parts.append("changed " + DateFormatter.localizedString(from: header.modified, dateStyle: .medium, timeStyle: .short)) }
            if vault.state == .unlocked { parts.append("\(section.entryCount) entries") }
            return parts.joined(separator: " · ")
        }
    }

    private func enrol() {
        do {
            try section.vault.enrolDevice()
            message = "Enrolled. The next unlock asks \(section.vault.deviceStore?.displayName ?? "the device key")."
        } catch {
            message = "Could not enrol: \(error.localizedDescription)"
        }
    }

    private func changePassphrase() {
        do {
            try section.vault.changePassphrase(to: newPassphrase)
            message = "The recovery passphrase was changed."
            showPassphraseChange = false
            newPassphrase = ""; confirmation = ""
        } catch {
            message = "Could not change the passphrase: \(error.localizedDescription)"
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "A markdown file of entries: ## Title, then - label: value lines."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard !SecretsDocument.pieces(of: text).isEmpty else { message = "No entries found in \(url.lastPathComponent): each needs a `## Title` heading."; return }
            let result = section.importMarkdown(text)
            var parts = ["Added \(result.added) entr\(result.added == 1 ? "y" : "ies") from \(url.lastPathComponent)"]
            if result.skipped > 0 { parts.append("\(result.skipped) already there") }
            message = parts.joined(separator: ", ") + ". The file itself is still readable: delete it once the entries are in."
        } catch {
            message = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func export() {
        guard let text = section.vault.plaintext() else { return }
        let alert = NSAlert()
        alert.messageText = "Export the vault as readable text?"
        alert.informativeText = "The file is not encrypted: every password and key in it can be read by anyone with the file."
        alert.addButton(withTitle: "Choose Where…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Secrets.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: [.atomic])
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Could not export: \(error.localizedDescription)"
        }
    }
}
