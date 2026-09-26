import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// Daily notes search: full text over notes plus task titles, from the index.
@MainActor
final class DailyNotesSearchProvider: SearchProvider {
    let library: NotebookLibrary
    init(library: NotebookLibrary) { self.library = library }

    /// Scribe transcripts and highlight books share the index but belong to their own sections.
    private let scope = SearchIndex.PathScope.notUnderAny([NotesFolder.scribeDirectoryName + "/", NotesFolder.highlightsDirectoryName + "/"])

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        await library.save()
        let index = library.index, scope = self.scope
        let (notes, tasks) = try await Task.detached(priority: .userInitiated) {
            (try index.searchNotes(query, limit: limit, scope: scope), try index.searchTasks(query, limit: limit, scope: scope))
        }.value
        try Task.checkCancellation()
        let lines = await firstLines(matching: query, inNotesAt: notes.map(\.path))
        var hits: [SearchHit] = []
        for note in notes {
            hits.append(SearchHit(sectionID: NoteParser.dailyProviderID, title: note.title,
                                  snippet: note.snippet, route: SectionRoute(path: note.path, line: lines[note.path] ?? nil)))
        }
        for task in tasks {
            hits.append(SearchHit(sectionID: NoteParser.dailyProviderID, title: "Task · " + (task.source.day ?? ""),
                                  snippet: task.title, route: SectionRoute(path: task.source.path, line: task.source.line)))
        }
        return hits
    }

    func tags() async throws -> [String] { library.knownTags }

    /// The first line containing any query word (or tag) in each note, so the
    /// editor can jump there. Open notes are read from memory; the rest with
    /// coordinated reads off the main actor.
    private func firstLines(matching query: String, inNotesAt paths: [String]) async -> [String: Int?] {
        let search = SearchQuery(query)
        var lines: [String: Int?] = [:]
        var unopened: [(path: String, url: URL)] = []
        for path in paths {
            if let doc = library.documents[path], doc.isLoaded {
                lines[path] = search.firstMatchingLine(in: doc.text)
            } else {
                unopened.append((path, library.folder.url(forRelativePath: path)))
            }
        }
        guard !unopened.isEmpty else { return lines }
        let read = await Task.detached(priority: .userInitiated) {
            unopened.map { item -> (String, Int?) in
                guard !Task.isCancelled, let data = try? FileIO.read(item.url) else { return (item.path, nil) }
                return (item.path, search.firstMatchingLine(in: String(decoding: data, as: UTF8.self)))
            }
        }.value
        for (path, line) in read { lines[path] = line }
        return lines
    }
}

/// Runs a query across every section's search provider.
@MainActor
@Observable
public final class SearchCoordinator {
    public var isPresented = false
    public var query = "" { didSet { schedule() } }
    public private(set) var hits: [SearchHit] = []
    public var selection: Int = 0
    /// All known tags, refreshed when the palette opens.
    public private(set) var knownTags: [String] = []
    /// Tag suggestions for a `#` token being typed.
    public var tagSuggestions: [String] {
        guard let pending = SearchQuery(query).pendingTag else { return [] }
        let already = Set(SearchQuery(query).tags)
        return knownTags.filter { !already.contains($0) && (pending.isEmpty || $0.hasPrefix(pending)) }.prefix(12).map { $0 }
    }
    var providers: [(id: String, provider: any SearchProvider)] = []
    public var navigate: ((String, SectionRoute) -> Void)?
    private var task: Task<Void, Never>?

    public init() {}

    public func setSections(_ sections: [any NotebookSection]) {
        providers = sections.compactMap { s in s.searchProvider.map { (s.id, $0) } }
    }

    private func schedule() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        let parsed = SearchQuery(q)
        // A lone `#` is a suggestion request; a partial tag already filters by prefix.
        guard !parsed.isEmpty, parsed.wordText.count >= 2 || parsed.hasTagFilter else { hits = []; return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            var all: [SearchHit] = []
            for (_, p) in providers { all += (try? await p.search(q, limit: 30)) ?? [] }
            self.hits = all
            self.selection = 0
        }
    }

    public func open(with query: String? = nil) {
        if let query { self.query = query }
        isPresented = true
        Task { [weak self] in
            guard let self else { return }
            var all: [String] = []
            for (_, p) in providers { all += (try? await p.tags()) ?? [] }
            var seen = Set<String>()
            self.knownTags = all.filter { seen.insert($0).inserted }
        }
    }

    public func complete(tag: String) {
        query = SearchQuery.completing(query, with: tag)
    }

    public func activate(_ hit: SearchHit) {
        isPresented = false
        navigate?(hit.sectionID, hit.route)
    }

    public func activateSelection() {
        guard hits.indices.contains(selection) else { return }
        activate(hits[selection])
    }
}

/// Spotlight-style palette floating over the notebook.
public struct SearchPalette: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var coordinator: SearchCoordinator
    @FocusState private var focused: Bool

    public init(coordinator: SearchCoordinator) { self.coordinator = coordinator }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.dimInk.color)
                TextField("Search notes and tasks", text: $coordinator.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, design: .serif))
                    .focused($focused)
                    .onSubmit { coordinator.activateSelection() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { coordinator.isPresented = false; return .handled }
                if !coordinator.query.isEmpty {
                    Button { coordinator.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(theme.dimInk.color)
                }
            }
            .padding(.horizontal, 14).frame(height: 44)
            if SearchQuery(coordinator.query).pendingTag != nil {
                Divider().overlay(theme.ink.color.opacity(0.15))
                TagSuggestionList(tags: coordinator.tagSuggestions) { coordinator.complete(tag: $0) }
            }
            if !coordinator.hits.isEmpty {
                Divider().overlay(theme.ink.color.opacity(0.15))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(coordinator.hits.enumerated()), id: \.element.id) { i, hit in
                                SearchHitRow(hit: hit, isSelected: i == coordinator.selection)
                                    .id(hit.id)
                                    .onTapGesture { coordinator.activate(hit) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: min(360, CGFloat(coordinator.hits.count) * 50 + 8))
                    .onChange(of: coordinator.selection) { _, s in
                        if coordinator.hits.indices.contains(s) { proxy.scrollTo(coordinator.hits[s].id) }
                    }
                }
            } else if coordinator.query.count >= 2, SearchQuery(coordinator.query).pendingTag == nil {
                Divider().overlay(theme.ink.color.opacity(0.15))
                Text("No matches").font(.system(size: 13, design: .serif)).foregroundStyle(theme.dimInk.color)
                    .frame(height: 40)
            }
        }
        .frame(width: 560)
        .background(
            ZStack {
                theme.page.paperColor.color
                TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity, blend: theme.page.textureBlend)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.ink.color.opacity(0.2), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .foregroundStyle(theme.ink.color)
        .onAppear { focused = true }
    }

    private func move(_ delta: Int) {
        let n = coordinator.hits.count
        guard n > 0 else { return }
        coordinator.selection = (coordinator.selection + delta + n) % n
    }
}

/// Tags matching a `#` token being typed; click one to complete it.
struct TagSuggestionList: View {
    @Environment(\.notebookTheme) private var theme
    let tags: [String]
    let pick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tags.isEmpty ? "No tags yet. Type #tag in a note to create one." : "Filter by tag")
                .font(.system(size: 11, design: .serif)).foregroundStyle(theme.dimInk.color)
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button("#" + tag) { pick(tag) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium, design: .serif))
                            .foregroundStyle(theme.accent.color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(theme.accent.color.opacity(0.12)))
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchHitRow: View {
    @Environment(\.notebookTheme) private var theme
    let hit: SearchHit
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.title).font(.system(size: 13, weight: .semibold, design: .serif))
            Text(snippet).font(.system(size: 12.5, design: .serif)).lineLimit(2).foregroundStyle(theme.ink.color.opacity(0.8))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? theme.accent.color.opacity(0.16) : .clear).padding(.horizontal, 6))
        .contentShape(Rectangle())
    }

    /// FTS snippets mark matches with \u{1}…\u{2}; show them bold.
    private var snippet: AttributedString {
        var out = AttributedString()
        var bold = false
        var run = ""
        func flush() {
            var a = AttributedString(run)
            if bold { a.font = .system(size: 12.5, weight: .bold, design: .serif); a.backgroundColor = theme.highlighter[.inProgress]?.color }
            out += a; run = ""
        }
        let collapsed = hit.snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "^[#\\s]+", with: "", options: .regularExpression)
        for ch in collapsed {
            if ch == "\u{1}" { flush(); bold = true }
            else if ch == "\u{2}" { flush(); bold = false }
            else { run.append(ch) }
        }
        flush()
        return out
    }
}

/// Menu helpers for the in-note find bar (NSTextFinder on the focused text view).
@MainActor
public enum FindCommands {
    public static func perform(_ action: NSTextFinder.Action) {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSTextView else { NSSound.beep(); return }
        let item = NSMenuItem(); item.tag = action.rawValue
        responder.performTextFinderAction(item)
    }
}
