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
    public let tab = TabAppearance(label: "Daily Notes", systemImage: "calendar")
    public let library: NotebookLibrary
    public var selectedDay: DayKey = .today
    /// Requested line to reveal after navigation (from search).
    public var pendingLine: Int?

    @ObservationIgnored private let _taskProvider: DailyNotesTaskProvider

    public init(library: NotebookLibrary) {
        self.library = library
        _taskProvider = DailyNotesTaskProvider(library: library)
    }

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
        library.flushAll()
        return try library.index.tasks(provider: id)
    }

    func setStatus(_ status: TaskStatus, of task: TaskItem) async throws {
        let doc = library.document(atRelativePath: task.source.path)
        try doc.replaceTaskMark(line: task.source.line, expectedKey: task.contentKey, with: status)
        library.flushAll()
    }
}

struct DailyNotesPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: DailyNotesSection
    @State private var showCalendar = false

    var body: some View {
        let document = section.library.document(forDay: section.selectedDay)
        ZStack(alignment: .topTrailing) {
            MarkdownEditor(document: document) { section.library.scheduleSave() }
                .id(section.selectedDay)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
            DayNavigator(section: section, showCalendar: $showCalendar)
                .padding(.top, 8)
                .padding(.trailing, 14)
            if document.isDownloading {
                Text("Downloading from iCloud…")
                    .font(.system(size: 13, design: .serif)).foregroundStyle(theme.dimInk.color)
                    .padding(.top, 60).padding(.leading, 64)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if document.externalChangePending {
                ExternalChangeBanner(document: document)
                    .padding(.top, 44).padding(.trailing, 14)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: section.selectedDay)
        .onChange(of: section.selectedDay) { _, _ in section.library.flushAll() }
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
