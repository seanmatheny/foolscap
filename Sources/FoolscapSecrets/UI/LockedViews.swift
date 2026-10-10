import SwiftUI
import FoolscapCore
import FoolscapUI

/// The page while the vault is shut: a padlock, Touch ID, and the passphrase as a fallback.
struct LockedView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: SecretsSection
    @State private var passphrase = ""
    @State private var showPassphrase = false
    @FocusState private var passphraseFocused: Bool

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    private var unlocking: Bool { section.vault.state == .unlocking }

    var body: some View {
        let hasDevice = section.vault.hasDeviceWrap
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 64 * scale, weight: .regular))
                .foregroundStyle(theme.ink.color.opacity(0.45))
                .padding(.bottom, 6)
            Text("Secrets are locked").font(theme.type.heading.font).fontWeight(.bold)
            Text("Nothing on this page can be read until you unlock it. It locks itself again after \(section.lockMinutes) minute\(section.lockMinutes == 1 ? "" : "s") without a keystroke, when the Mac sleeps or the screen locks.")
                .font(.system(size: 13.5 * scale, design: .serif))
                .foregroundStyle(theme.dimInk.color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            if case .failed(let why) = section.vault.state {
                Text(why).font(.system(size: 13 * scale, design: .serif)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if hasDevice {
                Button { Task { await section.unlockWithDevice() } } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                        .font(.system(size: 13.5, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                        .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.6))
                }
                .buttonStyle(.plain)
                .disabled(unlocking)
                .keyboardShortcut(.defaultAction)
                if unlocking { ProgressView().controlSize(.small) }
                Button("Use the recovery passphrase") { showPassphrase.toggle(); passphraseFocused = showPassphrase }
                    .buttonStyle(.plain)
                    .font(.system(size: 12 * scale, design: .serif))
                    .foregroundStyle(theme.dimInk.color)
                    .underline()
            }
            if showPassphrase || !hasDevice {
                HStack(spacing: 8) {
                    SecureField("Recovery passphrase", text: $passphrase)
                        .paperField()
                        .font(.system(size: 13 * scale, design: .serif))
                        .frame(width: 260)
                        .focused($passphraseFocused)
                        .onSubmit(submit)
                    Button("Unlock") { submit() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(theme.accent.color.opacity(0.14)))
                        .disabled(passphrase.isEmpty || unlocking)
                }
                .colorScheme(theme.isDark ? .dark : .light)
                if !hasDevice {
                    Text(section.vault.deviceStore.map { "\($0.displayName) is not set up for this vault on this Mac. Once it is open, Settings ▸ Secrets can enrol it." } ?? "")
                        .font(.system(size: 12 * scale, design: .serif))
                        .foregroundStyle(theme.dimInk.color)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 470)
                }
            }
            if let error = section.vault.lastError {
                Text(error).font(.system(size: 13 * scale, design: .serif)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, pitch * 4)
    }

    private func submit() {
        let pass = passphrase
        guard !pass.isEmpty else { return }
        passphrase = ""
        Task { await section.unlock(passphrase: pass) }
    }
}

/// The first run: choose the recovery passphrase, make the vault.
struct SetupView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: SecretsSection
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var error: String?
    @FocusState private var passphraseFocused: Bool

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    private var ready: Bool { passphrase.count >= 8 && passphrase == confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep passwords, keys and codes here, filed A–Z like an address book.")
                .font(.system(size: 15 * scale, design: .serif)).opacity(0.8)
            Text("The vault is one AES-256 encrypted file inside your notebook folder, so it travels with your backups. Day to day it opens with Touch ID or your login password. The recovery passphrase you choose now is the other way in, and the only way on another Mac: keep it somewhere safe. Nothing in the vault is indexed or searchable from the other tabs.")
                .font(.system(size: 13.5 * scale, design: .serif))
                .foregroundStyle(theme.dimInk.color)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Recovery passphrase", text: $passphrase)
                .paperField().frame(width: 320)
                .focused($passphraseFocused)
            SecureField("The same again", text: $confirmation)
                .paperField().frame(width: 320)
                .onSubmit { if ready { create() } }
            HStack(spacing: 12) {
                Button { create() } label: {
                    Text("Create vault")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                        .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .opacity(ready ? 1 : 0.5)
                if !passphrase.isEmpty && passphrase.count < 8 {
                    Text("At least 8 characters.").font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                } else if !confirmation.isEmpty && passphrase != confirmation {
                    Text("The two do not match yet.").font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                }
            }
            if let error {
                Text(error).font(.system(size: 13 * scale, design: .serif)).foregroundStyle(.red)
            }
        }
        .colorScheme(theme.isDark ? .dark : .light)
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.top, pitch)
        .onAppear { DispatchQueue.main.async { passphraseFocused = true } }
    }

    private func create() {
        do {
            try section.createVault(passphrase: passphrase)
            passphrase = ""; confirmation = ""; error = nil
        } catch {
            self.error = "Could not create the vault: \(error.localizedDescription)"
        }
    }
}
