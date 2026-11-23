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
    /// The Tasks tab's aggregator, shared so today's page can head itself with
    /// the tasks marked today and edit them in place.
    public var taskAggregator: TaskAggregator?
    /// Sections that file pages by day (Scribe), shown in the day's appendix.
    public var dayPagesProviders: [any DayPagesProvider] = []
    /// Opens another section at a route (a Scribe page from the appendix).
    @ObservationIgnored public var openRoute: ((String, SectionRoute) -> Void)?
    /// Opens the notebook search (the palette ⇧⌘F shows), from the page's search capsule.
    @ObservationIgnored public var openSearch: (() -> Void)?

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

    func remove(_ task: TaskItem) async throws -> RemovedTask {
        let doc = await library.loadedDocument(atRelativePath: task.source.path)
        let cut = try doc.removeTaskBlock(line: task.source.line, expectedKey: task.contentKey)
        await library.save()
        return RemovedTask(task: task, text: cut.text, line: cut.line)
    }

    func restore(_ removed: RemovedTask) async throws {
        let doc = await library.loadedDocument(atRelativePath: removed.task.source.path)
        doc.insertLines(removed.text, at: removed.line)
        await library.save()
    }
}

struct DailyNotesPage: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.taskPens) private var pens
    @Environment(\.compactPage) private var compact
    @Bindable var section: DailyNotesSection
    @State private var showCalendar = false
    /// The day's note, set from `.task` rather than fetched in `body`: opening
    /// a new day creates a document, and that must not happen mid-render.
    @State private var document: NoteDocument?

    /// Today's page lists the tasks marked today (`[/]`), from wherever they
    /// were written, under its date.
    private var todayHeader: AnyView? {
        guard section.selectedDay == .today, let aggregator = section.taskAggregator else { return nil }
        // The panel is hosted in a view of its own, which inherits none of this environment.
        return AnyView(TodayTasksPanel(section: section, aggregator: aggregator)
            .environment(\.taskPens, pens)
            .environment(\.compactPage, compact))
    }

    /// The day's handwritten pages, after the note.
    private var appendix: AnyView? {
        guard !section.dayPagesProviders.isEmpty else { return nil }
        return AnyView(DayPagesAppendix(section: section, day: section.selectedDay, providers: section.dayPagesProviders))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Holds the page's full size while the note loads, so the navigator stays in its corner.
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            // The note loads in the background the first time a day is shown; the
            // editor appears once the text is in place, so nothing typed is overwritten.
            if let document, document.isLoaded {
                MarkdownEditor(document: document, revealLine: section.pendingLine,
                               tags: { [library = section.library] in library.knownTags },
                               header: todayHeader, footer: appendix) { section.library.scheduleSave() }
                    // Keyed on the library generation too: a folder switch or a restore replaces every
                    // document. And on the day-pages providers: the footer takes them by value.
                    .id("\(document.path)/\(section.library.generation)/\(section.dayPagesProviders.count)")
                    // On the phone the note runs under the clock and the home indicator like the
                    // other pages' scroll views; the text view insets its content by the same room.
                    .ignoresPageInsets(compact)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            }
            HStack(spacing: 8) {
                SearchCapsule(compact: compact) { section.openSearch?() }
                DayNavigator(section: section, showCalendar: $showCalendar)
            }
            .padding(.top, 8)
            .padding(.trailing, compact ? PageRuling.textRight : 44)
            .clearOfTabChip()
            if let document {
                NoteLoadStatus(document: document, compact: compact)
                NoteChangeBanners(document: document, compact: compact)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: section.selectedDay)
        .task(id: "\(section.selectedDay.string)/\(section.library.generation)") {
            let library = section.library
            let doc = library.document(forDay: section.selectedDay)
            #if os(iOS)
            // Read with `devicectl device process launch --console`: which day the page is
            // on and whether its note was already in memory.
            NSLog("Daily page: \(doc.path), loaded \(doc.isLoaded), downloading \(doc.isDownloading)")
            #endif
            document = doc
            await library.save()
            // Only the page on screen (and the Tasks file) stays open, so a folder
            // change never re-checks every day visited this session.
            library.releaseDocuments(except: [doc.path, NotesFolder.tasksFileName])
        }
    }
}

/// Looks like a search field, opens the notebook search palette (⇧⌘F), which has
/// the real one: words and `#tags` across every day's note and task.
struct SearchCapsule: View {
    @Environment(\.notebookTheme) private var theme
    /// The magnifier alone, for a phone's page.
    var compact = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                if !compact { Text("Search notes and #tags").font(theme.type.body.face(12)) }
            }
            .foregroundStyle(theme.ink.color.opacity(hovering ? 0.75 : 0.5))
            .padding(.horizontal, 10).frame(height: 24)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .background(Capsule().fill(theme.page.paperColor.color.opacity(0.85)).shadow(color: .black.opacity(0.08), radius: 2, y: 1))
        .overlay(Capsule().stroke(theme.ink.color.opacity(hovering ? 0.2 : 0.1), lineWidth: 0.5))
        .onHover { hovering = $0 }
        .help("Search every day's notes and tasks (⇧⌘F)")
    }
}

struct DayNavigator: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Bindable var section: DailyNotesSection
    @Binding var showCalendar: Bool

    var body: some View {
        HStack(spacing: 2) {
            navButton("chevron.left", help: "Previous day (⌘[)") { section.go(days: -1) }
            Button { showCalendar.toggle() } label: {
                Text(section.selectedDay.shortTitle)
                    .font(theme.type.body.face(12, weight: .medium))
                    .padding(.horizontal, 8).frame(height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A popover on the Mac; on a phone a popover becomes a full-height sheet with the
            // month floating in its middle, so the calendar takes a half-height sheet instead
            // and a tapped day turns the page by itself.
            .popover(isPresented: compact ? .constant(false) : $showCalendar) {
                CalendarPopover(section: section, dismiss: { showCalendar = false })
            }
            .sheet(isPresented: compact ? $showCalendar : .constant(false)) {
                CalendarPopover(section: section, compact: true, dismiss: { showCalendar = false })
                    .presentationDetents([.medium])
            }
            navButton("chevron.right", help: "Next day (⌘])") { section.go(days: 1) }
            if section.selectedDay != .today {
                Button("Today") { section.goToday() }
                    .buttonStyle(.plain)
                    .font(theme.type.body.face(11, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(Capsule().fill(theme.accent.color.opacity(0.14)))
                    .padding(.leading, 4)
            }
        }
        .foregroundStyle(theme.ink.color.opacity(0.75))
        .padding(.horizontal, 4)
        .background(Capsule().fill(theme.page.paperColor.color.opacity(0.85)).shadow(color: .black.opacity(0.08), radius: 2, y: 1))
    }

    /// A chevron, with a finger's worth of hit area on a phone (the symbol stays small).
    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: compact ? 32 : 24, height: compact ? 32 : 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct CalendarPopover: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: DailyNotesSection
    /// A phone's sheet: a tapped day goes there at once, no Go button.
    var compact = false
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
                if compact {
                    Button("Today") { go(to: .today) }.disabled(section.selectedDay == .today)
                } else {
                    Button("Go") { go(to: DayKey(date)) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .frame(width: compact ? nil : 280)
        .frame(maxWidth: compact ? .infinity : nil, maxHeight: compact ? .infinity : nil, alignment: .top)
        // The phone's sheet is a sheet of the notebook's paper; the Mac's popover is the system's.
        .background { if compact { theme.page.paperColor.color.ignoresSafeArea() } }
        .tint(compact ? theme.accent.color : nil)
        .paperScheme(compact, dark: theme.isDark)
        .onAppear { date = section.selectedDay.date }
        .onChange(of: date) { _, picked in
            // The picker hands back the chosen day at the time the old date had; only a day
            // the reader chose (not the one `onAppear` set) turns the page.
            if compact, DayKey(picked) != section.selectedDay { go(to: DayKey(picked)) }
        }
    }

    private func go(to day: DayKey) {
        section.selectedDay = day
        dismiss()
    }
}

private extension View {
    /// System controls on the notebook's paper take the paper's light or dark scheme.
    @ViewBuilder
    func paperScheme(_ on: Bool, dark: Bool) -> some View {
        if on { colorScheme(dark ? .dark : .light) } else { self }
    }
}
