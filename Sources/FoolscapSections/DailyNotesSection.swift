import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

/// One page per day, flipped with the arrows or ⌘[ / ⌘].
@MainActor
@Observable
public final class DailyNotesSection: NotebookSection {
    public let id = "daily"
    public let tab = TabAppearance(label: "Daily Notes", systemImage: "calendar", shortcut: "d")
    public let library: NotebookLibrary
    public var selectedDay: DayKey = .today
    /// Requested line to reveal after navigation (from search).
    public var pendingLine: Int?

    @ObservationIgnored private let _taskProvider: DailyNotesTaskProvider
    @ObservationIgnored private let _searchProvider: DailyNotesSearchProvider

    public init(library: NotebookLibrary) {
        self.library = library
        _taskProvider = DailyNotesTaskProvider(library: library)
        _searchProvider = DailyNotesSearchProvider(library: library)
    }

    public var searchProvider: (any SearchProvider)? { _searchProvider }

    public func makeRootView() -> AnyView { AnyView(DailyNotesPage(section: self)) }

    public func navigate(to route: SectionRoute) {
        if let day = library.folder.day(forRelativePath: route.path) {
            selectedDay = day
            pendingLine = route.line
        }
    }

    public var taskProvider: (any TaskProvider)? { _taskProvider }

    public func go(days: Int) { selectedDay = selectedDay.adding(days: days) }
    public func goToday() { selectedDay = .today }
}

/// Tasks found in daily notes, read from the index; status writes go through
/// the shared NoteDocument so an open editor updates instantly.
@MainActor
final class DailyNotesTaskProvider: TaskProvider {
    let id = NoteParser.dailyProviderID
    let library: NotebookLibrary
    init(library: NotebookLibrary) { self.library = library }

    nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await _ in library.changes { continuation.yield() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func tasks() async throws -> [TaskItem] {
        await library.save()
        let index = library.index, id = self.id
        return try await Task.detached(priority: .userInitiated) { try index.tasks(provider: id) }.value
    }

    func setStatus(_ status: TaskStatus, of task: TaskItem) async throws {
        let doc = await library.loadedDocument(atRelativePath: task.source.path)
        try doc.replaceTaskMark(line: task.source.line, expectedKey: task.contentKey, with: status)
        await library.save()
    }

    func setTitle(_ title: String, of task: TaskItem) async throws {
        let doc = await library.loadedDocument(atRelativePath: task.source.path)
        try doc.replaceTaskTitle(line: task.source.line, expectedKey: task.contentKey, with: title)
        await library.save()
    }

    func setNotes(_ notes: String?, of task: TaskItem) async throws {
        let doc = await library.loadedDocument(atRelativePath: task.source.path)
        try doc.replaceTaskNotes(line: task.source.line, expectedKey: task.contentKey, with: notes)
        await library.save()
    }
}

struct DailyNotesPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: DailyNotesSection
    @State private var showCalendar = false
    /// The day's note, set from `.task` rather than fetched in `body`: opening
    /// a new day creates a document, and that must not happen mid-render.
    @State private var document: NoteDocument?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Holds the page's full size while the note loads, so the navigator stays in its corner.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            // The note loads in the background the first time a day is shown; the
            // editor appears once the text is in place, so nothing typed is overwritten.
            if let document, document.isLoaded {
                MarkdownEditor(document: document, revealLine: section.pendingLine,
                               tags: { [library = section.library] in library.knownTags }) { section.library.scheduleSave() }
                    // Keyed on the library generation too: a folder switch or a restore replaces every document.
                    .id("\(document.path)/\(section.library.generation)")
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
            DayNavigator(section: section, showCalendar: $showCalendar)
                .padding(.top, 8)
                .padding(.trailing, 44)
            if let document {
                if document.isDownloading {
                    Text("Downloading from iCloud…")
                        .font(.system(size: 13, design: .serif)).foregroundStyle(theme.dimInk.color)
                        .padding(.top, 60).padding(.leading, 64)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if document.externalChangePending {
                    ExternalChangeBanner(document: document)
                        .padding(.top, 44).padding(.trailing, 44)
                } else if !document.conflictVersions.isEmpty {
                    ConflictBanner(document: document)
                        .padding(.top, 44).padding(.trailing, 44)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: section.selectedDay)
        .task(id: "\(section.selectedDay.string)/\(section.library.generation)") {
            let library = section.library
            let doc = library.document(forDay: section.selectedDay)
            document = doc
            await library.save()
            // Only the page on screen (and the Tasks file) stays open, so a folder
            // change never re-checks every day visited this session.
            library.releaseDocuments(except: [doc.path, NotesFolder.tasksFileName])
        }
    }
}

struct DayNavigator: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: DailyNotesSection
    @Binding var showCalendar: Bool

    var body: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", help: "Previous day (⌘[)") { section.go(days: -1) }
            Button { showCalendar.toggle() } label: {
                Text(section.selectedDay.shortTitle)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .padding(.horizontal, 8).frame(height: 24)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCalendar) {
                CalendarPopover(section: section, dismiss: { showCalendar = false })
            }
            navButton("chevron.right", help: "Next day (⌘])") { section.go(days: 1) }
            if section.selectedDay != .today {
                Button("Today") { section.goToday() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Capsule().fill(theme.accent.color.opacity(0.14)))
                    .padding(.leading, 4)
            }
        }
        .foregroundStyle(theme.ink.color.opacity(0.75))
        .padding(.horizontal, 4)
        .background(Capsule().fill(theme.page.paperColor.color.opacity(0.85)).shadow(color: .black.opacity(0.08), radius: 2, y: 1))
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct CalendarPopover: View {
    @Bindable var section: DailyNotesSection
    let dismiss: () -> Void
    @State private var date: Date = Date()

    var body: some View {
        VStack(spacing: 6) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Text("\(section.library.days.count) days with notes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Go") { section.selectedDay = DayKey(date); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear { date = section.selectedDay.date }
    }
}

struct ConflictBanner: View {
    @Environment(\.notebookTheme) private var theme
    let document: NoteDocument
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
            Text("iCloud has \(document.conflictVersions.count) conflicting cop\(document.conflictVersions.count == 1 ? "y" : "ies") of this note.")
            Button("Keep mine") { try? document.resolveConflicts(.keepMine) }
            Button("Take theirs") { try? document.resolveConflicts(.takeTheirs) }
            Button("Keep both") { try? document.resolveConflicts(.keepBoth) }
        }
        .font(.system(size: 12, design: .serif))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(theme.accent.color.opacity(0.18)))
        .foregroundStyle(theme.ink.color)
    }
}

struct ExternalChangeBanner: View {
    @Environment(\.notebookTheme) private var theme
    let document: NoteDocument
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.icloud")
            Text("This note changed on another device.")
            Button("Keep mine") { document.keepLocalVersion() }
            Button("Take theirs") { document.takeExternalVersion() }
        }
        .font(.system(size: 12, design: .serif))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(theme.accent.color.opacity(0.18)))
        .foregroundStyle(theme.ink.color)
    }
}
