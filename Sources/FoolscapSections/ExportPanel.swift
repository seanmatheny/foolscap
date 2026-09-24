import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// File ▸ Export… sheet.
public struct ExportPanel: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let library: NotebookLibrary
    let currentDay: DayKey
    @AppStorage("exportFormat") private var formatRaw = "markdown"
    @AppStorage("exportIncludeAttachments") private var includeAttachments = true
    @State private var scopeChoice = 0
    @State private var from: Date
    @State private var to: Date = Date()
    @State private var message: String?
    @State private var busy = false

    public init(library: NotebookLibrary, currentDay: DayKey) {
        self.library = library
        self.currentDay = currentDay
        _from = State(initialValue: currentDay.adding(days: -7).date)
        _to = State(initialValue: currentDay.date)
    }

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .markdown }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Notes").font(.title2.bold())
            Picker("Which notes", selection: $scopeChoice) {
                Text(currentDay.longTitle).tag(0)
                Text("A range of days").tag(1)
                Text("Everything (\(library.days.count) days)").tag(2)
            }
            .pickerStyle(.radioGroup)
            if scopeChoice == 1 {
                HStack {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
            }
            Picker("Format", selection: $formatRaw) {
                ForEach(ExportFormat.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if format == .markdown {
                Toggle("Copy attachments alongside", isOn: $includeAttachments)
            }
            if format == .textbundle {
                Text("One .textbundle package per note, with images inside. Opens in Bear, Ulysses, iA Writer and others.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { run() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var scope: ExportScope {
        switch scopeChoice {
        case 0: return .day(currentDay)
        case 1: return .range(DayKey(from), DayKey(to))
        default: return .all
        }
    }

    private func run() {
        let single = scopeChoice == 0
        let panel: NSSavePanel
        if single {
            let p = NSSavePanel()
            p.nameFieldStringValue = "\(currentDay.string).\(format.fileExtension)"
            panel = p
        } else {
            let p = NSOpenPanel()
            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
            p.prompt = "Export Here"
            panel = p
        }
        panel.message = single ? "Save the exported note." : "Choose a folder for the exported notes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        message = "Exporting…"
        Task {
            do {
                let result = try await NoteExporter.export(library: library, scope: scope, format: format,
                                                           includeAttachments: includeAttachments, theme: theme, to: url)
                message = result.files.isEmpty ? "No notes in that range." : "Exported \(result.files.count) file\(result.files.count == 1 ? "" : "s")."
                if let first = result.files.first { NSWorkspace.shared.activateFileViewerSelecting([first]) }
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
            busy = false
        }
    }
}
