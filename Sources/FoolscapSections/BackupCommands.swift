import AppKit
import UniformTypeIdentifiers
import FoolscapCore
import FoolscapStore

/// The panels and alerts around backups, shared by the File menu and Settings.
@MainActor
public enum BackupCommands {
    /// Save one backup wherever the user chooses (the backup folder by default).
    public static func backUpNow(_ backup: BackupManager) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = BackupManager.fileName(for: Date())
        panel.directoryURL = backup.folder
        panel.message = "Save a complete backup of the notebook, its search index, Scribe data and settings."
        try? FileManager.default.createDirectory(at: backup.folder, withIntermediateDirectories: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await backup.backUp(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                report("Backup failed", error.localizedDescription)
            }
        }
    }

    /// Pick an archive, confirm, restore, and say how it went.
    public static func restore(_ backup: BackupManager) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = backup.folder
        panel.prompt = "Restore"
        panel.message = "Choose a Foolscap backup to restore. Everything it holds replaces what is in the app now."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let manifest: BackupManifest
        do { manifest = try BackupArchive.manifest(of: url) }
        catch { report("Not a Foolscap backup", error.localizedDescription); return }

        let when = DateFormatter.localizedString(from: manifest.createdAt, dateStyle: .full, timeStyle: .short)
        let alert = NSAlert()
        alert.messageText = "Restore the backup from \(when)?"
        alert.informativeText = """
            The notes, attachments, Tasks.md and Scribe files in the notebook folder, the search index, \
            Scribe sync state and the app's settings are all replaced with the backup's. \
            A safety copy of the current state is saved to \(backup.folder.path) first.
            """
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do {
                try await backup.restore(from: url)
                report("Restore complete", backup.lastMessage ?? "The backup was restored.", style: .informational)
            } catch {
                report("Restore failed", error.localizedDescription)
            }
        }
    }

    public static func chooseFolder(_ backup: BackupManager) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Automatic backups are written here, and one-off backups start here."
        panel.directoryURL = backup.folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backup.folder = url
    }

    private static func report(_ title: String, _ text: String, style: NSAlert.Style = .critical) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }
}
