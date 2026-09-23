import SwiftUI
import FoolscapCore
import FoolscapUI

/// The notebooks in the selected Kindle folder, nested folders as headings,
/// with the sync status underneath.
struct ScribeContentsColumn: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: ScribeSection
    static let width: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(section.contents.enumerated()), id: \.offset) { _, group in
                        if !group.group.isEmpty {
                            Text(group.group.uppercased())
                                .font(.system(size: 10, weight: .semibold, design: .serif))
                                .tracking(0.8)
                                .foregroundStyle(theme.dimInk.color)
                                .padding(.leading, 10).padding(.top, 10).padding(.bottom, 2)
                        }
                        ForEach(group.notebooks) { notebook in
                            row(notebook)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Spacer(minLength: 0)
            SyncStatusLine(section: section)
                .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(width: Self.width)
    }

    private func row(_ notebook: ScribeItem) -> some View {
        let selected = notebook.id == section.selectedNotebookID
        return Button { section.select(notebook: notebook.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? theme.accent.color : theme.dimInk.color)
                Text(notebook.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular, design: .serif))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let pages = notebook.totalPages {
                    Text("\(pages)").font(.system(size: 10.5, design: .serif)).foregroundStyle(theme.dimInk.color)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.accent.color.opacity(0.16) : .clear).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Synced 5 min ago · Sync now", or what the sync is doing right now.
struct SyncStatusLine: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: ScribeSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if section.status.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(section.status.phase ?? "Syncing…").lineLimit(1)
                }
            } else if section.status.needsSignIn {
                Button("Sign in to Amazon…") { section.signIn() }.buttonStyle(.plain).foregroundStyle(theme.accent.color)
            } else {
                HStack(spacing: 6) {
                    Text(lastRunText).lineLimit(1)
                    Text("·")
                    Button("Sync now") { section.syncNow() }.buttonStyle(.plain).foregroundStyle(theme.accent.color)
                }
            }
            if let error = section.status.lastError {
                Text(error).lineLimit(2).foregroundStyle(.red.opacity(0.8))
            }
        }
        .font(.system(size: 11, design: .serif))
        .foregroundStyle(theme.dimInk.color)
    }

    private var lastRunText: String {
        guard let run = section.status.lastRun ?? section.state.lastSync else { return "Not synced yet" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return "Synced " + f.localizedString(for: run, relativeTo: Date())
    }
}
