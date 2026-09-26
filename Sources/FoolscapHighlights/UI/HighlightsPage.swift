import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// The Highlights tab: a header with the mode chips and the search field,
/// then today's three, the shelf of covers, one book, or search results.
struct HighlightsPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    @FocusState private var searchFocused: Bool

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        RulingView(pitch: pitch, topInset: pitch * 2 - 4, marginX: 58)
                            .frame(minHeight: geo.size.height)
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            Spacer().frame(height: pitch / 2)
                            content
                            Spacer(minLength: pitch * 2)
                        }
                        .padding(.leading, 58)
                        .padding(.trailing, 44)
                        .padding(.top, pitch)
                    }
                }
                .onChange(of: section.pendingHighlightID) { _, id in scroll(to: id, proxy: proxy) }
                .onChange(of: section.items.count) { _, _ in scroll(to: section.pendingHighlightID, proxy: proxy) }
            }
        }
        .foregroundStyle(theme.ink.color)
        .task { await section.reload() }
    }

    @ViewBuilder private var content: some View {
        if section.items.isEmpty {
            emptyState
        } else if !section.searchQuery.isEmpty {
            SearchResults(section: section)
        } else {
            switch section.mode {
            case .today: TodayView(section: section, items: section.picks, showsBooks: true)
            case .books: BookGrid(section: section)
            case .book(let path): BookPage(section: section, path: path)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Highlights").font(theme.type.heading.font).fontWeight(.bold)
            Text("\(section.items.count)").font(.system(size: 13 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            Spacer()
            if !section.items.isEmpty {
                FilterChip(label: "Today", isOn: section.mode == .today && section.searchText.isEmpty) { section.searchText = ""; section.showToday() }
                FilterChip(label: "Books", isOn: section.mode != .today && section.searchText.isEmpty) { section.searchText = ""; section.showBooks() }
                searchField
            }
            if section.status.isRunning {
                ProgressView().controlSize(.mini).help(section.status.phase ?? "Importing…")
            }
        }
        .frame(height: pitch * 1.5)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.dimInk.color)
            TextField("Search quotes, books, #tags", text: $section.searchText)
                .font(.system(size: 13 * scale, design: .serif))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .completesTags(in: $section.searchText, known: section.knownTags)
            if !section.searchText.isEmpty {
                Button { section.searchText = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimInk.color)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(searchFocused ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(searchFocused ? 0.22 : 0.12), lineWidth: 0.5))
        .colorScheme(theme.isDark ? .dark : .light)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if section.status.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(section.status.phase ?? "Reading your Kindle highlights…")
                }
                .font(.system(size: 15, design: .serif)).foregroundStyle(theme.dimInk.color)
            } else if !section.kindleInstalled {
                Text("Highlights come from the Kindle app on this Mac. Install Amazon Kindle from the App Store, sign in, and download the books you have highlighted.")
                    .font(.system(size: 15, design: .serif)).opacity(0.75)
                    .frame(maxWidth: 520, alignment: .leading)
            } else {
                Text("No highlights yet. Books you have highlighted in the Kindle app and downloaded there are read into one page each.")
                    .font(.system(size: 15, design: .serif)).opacity(0.75)
                    .frame(maxWidth: 520, alignment: .leading)
                ImportButton(section: section)
            }
            if let error = section.status.lastError {
                Text(error).font(.system(size: 13, design: .serif)).foregroundStyle(.red).frame(maxWidth: 520, alignment: .leading)
            }
            if section.status.needsFullDiskAccess {
                FullDiskAccessButton()
                AccessGrantNote()
            }
            if let report = section.status.lastReport, !report.skipped.isEmpty {
                SkippedList(report: report)
            }
        }
        .padding(.top, 4)
    }

    private func scroll(to id: String?, proxy: ScrollViewProxy) {
        guard let id, section.items.contains(where: { $0.id == id }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

/// Matching highlights from every book, grouped by book.
struct SearchResults: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        let results = section.searchResults
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text("Nothing matches.").font(.system(size: 14, design: .serif)).italic().foregroundStyle(theme.dimInk.color)
                    .padding(.top, 6)
            }
            ForEach(groups(results), id: \.path) { group in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { section.searchText = ""; section.open(book: group.path) } label: {
                        Text(group.title).font(.system(size: 15 * scale, weight: .semibold, design: .serif))
                    }
                    .buttonStyle(.plain)
                    if !group.author.isEmpty { Text(group.author).font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color) }
                    Text("\(group.items.count)").font(.system(size: 11 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                }
                .padding(.top, 14).padding(.bottom, 2)
                ForEach(group.items) { item in
                    HighlightRow(section: section, item: item, query: section.searchQuery)
                }
            }
        }
    }

    private struct Group { var path: String; var title: String; var author: String; var items: [HighlightItem] }

    private func groups(_ items: [HighlightItem]) -> [Group] {
        var order: [String] = []
        var byPath: [String: Group] = [:]
        for item in items {
            if byPath[item.path] == nil {
                order.append(item.path)
                byPath[item.path] = Group(path: item.path, title: item.bookTitle, author: item.bookAuthor, items: [])
            }
            byPath[item.path]!.items.append(item)
        }
        return order.compactMap { byPath[$0] }
    }
}

struct ImportButton: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection

    var body: some View {
        Button { section.importNow() } label: {
            Text(section.status.isRunning ? "Importing…" : "Import from Kindle")
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(section.status.isRunning)
        .padding(.top, 6)
    }
}

/// Opens System Settings where the Kindle app's data can be unlocked for Foolscap.
struct FullDiskAccessButton: View {
    var body: some View {
        HStack(spacing: 10) {
            Button("Open Files & Folders Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
            }
            Button("Full Disk Access…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
            }
        }
        .font(.system(size: 12.5, design: .serif))
    }
}

/// macOS ties the grant to the app's code signature, so an ad-hoc build loses it on every rebuild.
struct AccessGrantNote: View {
    @Environment(\.notebookTheme) private var theme
    var body: some View {
        Text("If the switch turns itself off again, the app has been rebuilt since it was granted: macOS ties the permission to the app's signature, and an ad-hoc signature changes with every build. Sign the app with a certificate (see the Makefile) to keep it.")
            .font(.system(size: 12, design: .serif)).foregroundStyle(theme.dimInk.color)
            .frame(maxWidth: 560, alignment: .leading)
    }
}

/// Books the last import could not read, with the reason for each.
struct SkippedList: View {
    @Environment(\.notebookTheme) private var theme
    let report: ImportReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(report.skipped.count) book\(report.skipped.count == 1 ? "" : "s") skipped:")
                .font(.system(size: 12.5, weight: .semibold, design: .serif)).foregroundStyle(theme.dimInk.color)
            ForEach(report.skipped) { s in
                Text("\(s.title) — \(s.reason) (\(s.count))")
                    .font(.system(size: 12, design: .serif)).foregroundStyle(theme.dimInk.color).lineLimit(2)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: 560, alignment: .leading)
    }
}
