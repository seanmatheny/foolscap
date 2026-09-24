import SwiftUI
import FoolscapCore
import FoolscapUI

/// The notebooks in the selected Kindle folder as an outline: nested folders
/// fold open and closed, with the sync status underneath. Names truncate past
/// about five levels; the tooltip carries the full path.
struct ScribeContentsColumn: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: ScribeSection
    static let width: CGFloat = 220
    static let indent: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.contentsRows) { row in
                        if row.item.isFolder {
                            folderRow(row)
                        } else {
                            notebookRow(row)
                        }
                    }
                }
                .padding(.vertical, 6)
                .animation(.easeOut(duration: 0.15), value: section.collapsedFolderIDs)
            }
            Spacer(minLength: 0)
            SyncStatusLine(section: section)
                .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .frame(width: Self.width)
    }

    private func folderRow(_ row: ScribeSection.ContentsRow) -> some View {
        Button { section.toggle(folder: row.item.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: 10)
                Text(row.item.name.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .serif))
                    .tracking(0.8)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(row.notebookCount)").font(.system(size: 10, design: .serif))
            }
            .foregroundStyle(theme.dimInk.color)
            .padding(.leading, 10 + Self.indent * CGFloat(row.depth)).padding(.trailing, 14)
            .padding(.top, 8).padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.item.path)
    }

    private func notebookRow(_ row: ScribeSection.ContentsRow) -> some View {
        let notebook = row.item
        let selected = notebook.id == section.selectedNotebookID
        return Button { section.select(notebook: notebook.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? theme.accent.color : theme.dimInk.color)
                Text(notebook.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular, design: .serif))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let pages = notebook.totalPages {
                    Text("\(pages)").font(.system(size: 10.5, design: .serif)).foregroundStyle(theme.dimInk.color)
                }
            }
            .padding(.leading, 10 + Self.indent * CGFloat(row.depth)).padding(.trailing, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.accent.color.opacity(0.16) : .clear).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help(notebook.path)
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
