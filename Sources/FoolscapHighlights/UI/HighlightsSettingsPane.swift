import SwiftUI
import FoolscapCore

/// The Kindle Highlights group in Settings, under the master toggle.
struct HighlightsSettingsPane: View {
    @Bindable var section: HighlightsSection
    @AppStorage(HighlightsImportSchedule.key) private var schedule = HighlightsImportSchedule.atLaunch.rawValue

    var body: some View {
        Picker("Check for new highlights", selection: $schedule) {
            ForEach(HighlightsImportSchedule.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
        .onChange(of: schedule) { _, _ in section.settingsChanged() }
        Text("Each check reads the Kindle app's own database on this Mac; nothing runs while Foolscap is closed. “Whenever the Kindle app syncs” watches that file and costs nothing in between.")
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Import") {
            HStack {
                Button(section.status.isRunning ? "Importing…" : "Import Now") { section.importNow() }
                    .disabled(section.status.isRunning)
                Text(statusText).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        if section.status.needsFullDiskAccess {
            FullDiskAccessButton()
            Text("macOS protects other apps' data. Turn on Kindle for Foolscap under Files & Folders (or add Foolscap under Full Disk Access), then import again. The grant is tied to the app's signature: an ad-hoc build loses it whenever it is rebuilt, so sign the app with a certificate to keep it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let report = section.status.lastReport, !report.skipped.isEmpty {
            DisclosureGroup("\(report.skipped.count) book\(report.skipped.count == 1 ? "" : "s") skipped") {
                ForEach(report.skipped) { s in
                    Text("\(s.title): \(s.reason) (\(s.count) highlight\(s.count == 1 ? "" : "s"))").font(.caption)
                }
            }
        }
        Text(kfxText).font(.caption).foregroundStyle(.secondary)
        Text("Highlights are saved as one markdown file per book in Highlights/ inside your notebook folder, its cover beside it. Tags, ♥ and “hidden” live on each quote's last line. Everything is read from the Kindle app on this Mac, so only books downloaded there can be read.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var kfxText: String {
        switch section.kfxAvailability {
        case .ready: return "Newer (KFX) books are decoded with Calibre's KFX Input plugin, found on this Mac."
        default: return section.kfxAvailability.message + ". MOBI books are read directly."
        }
    }

    private var statusText: String {
        if let error = section.status.lastError { return error }
        if let phase = section.status.phase { return phase }
        guard let run = section.status.lastRun else { return "Not yet this session" }
        var text = "Last " + DateFormatter.localizedString(from: run, dateStyle: .short, timeStyle: .short)
        if let r = section.status.lastReport { text += " · " + r.summary }
        return text
    }
}
