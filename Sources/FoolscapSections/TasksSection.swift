import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import FoolscapCore
import FoolscapStore
import FoolscapUI

extension UTType {
    static let foolscapTask = UTType(exportedAs: "com.seanmatheny.foolscap.task")
}

extension TaskItem: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .foolscapTask)
    }
}

/// Every task from every section, grouped by status on one ruled page.
@MainActor
@Observable
public final class TasksSection: NotebookSection {
    public let id = "tasks"
    public let tab = TabAppearance(label: "Tasks", systemImage: "checklist")
    public let aggregator = TaskAggregator()
    let library: NotebookLibrary
    let openNote: (SectionRoute) -> Void
    var selectedTag: String?

    public init(library: NotebookLibrary, openNote: @escaping (SectionRoute) -> Void) {
        self.library = library
        self.openNote = openNote
    }

    public func makeRootView() -> AnyView { AnyView(TasksPage(section: self)) }

    /// New tasks live in today's note, so notes stay the source of truth.
    func addTask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let doc = library.document(forDay: .today)
        doc.appendTask(trimmed)
        library.flushAll()
    }
}

struct TasksPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: TasksSection
    @State private var showNewTask = false
    @State private var newTaskText = ""

    private var pitch: CGFloat { theme.linePitch }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    RulingView(pitch: pitch, topInset: pitch * 2 - 4, marginX: 58)
                        .frame(minHeight: geo.size.height)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        CategoryStrip(tags: section.aggregator.tags, selected: $section.selectedTag)
                            .frame(height: pitch)
                        Spacer().frame(height: pitch / 2)
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            TaskSectionView(status: status,
                                            tasks: section.aggregator.tasks(status: status, tag: section.selectedTag),
                                            pitch: pitch,
                                            onMove: { section.aggregator.move($0, to: status) },
                                            onToggle: { section.aggregator.move($0, to: $0.status.next) },
                                            onOpen: { section.openNote(SectionRoute(path: $0.source.path, line: $0.source.line)) })
                        }
                        Spacer(minLength: pitch * 2)
                    }
                    .padding(.leading, 58)
                    .padding(.trailing, 44)
                    .padding(.top, pitch)
                }
            }
        }
        .foregroundStyle(theme.ink.color)
        .task { await section.aggregator.reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tasks").font(theme.type.heading.font).fontWeight(.bold)
            Text("\(section.aggregator.tasks.count)").font(.system(size: 13, design: .serif)).foregroundStyle(theme.dimInk.color)
            Spacer()
            Button {
                showNewTask.toggle()
            } label: {
                Label("New task", systemImage: "plus").labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
                    .background(Circle().fill(theme.accent.color.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: [.command])
            .popover(isPresented: $showNewTask, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Task, with #category", text: $newTaskText)
                        .textFieldStyle(.roundedBorder).frame(width: 320)
                        .onSubmit { submit() }
                    Text("Added to today's note under “## Tasks”.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            if let err = section.aggregator.error { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .frame(height: pitch * 1.5)
    }

    private func submit() {
        section.addTask(newTaskText)
        newTaskText = ""
        showNewTask = false
    }
}

struct CategoryStrip: View {
    @Environment(\.notebookTheme) private var theme
    let tags: [String]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", isOn: selected == nil) { selected = nil }
                ForEach(tags, id: \.self) { tag in
                    chip("#" + tag, isOn: selected == tag) { selected = selected == tag ? nil : tag }
                }
            }
        }
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5, weight: isOn ? .semibold : .regular, design: .serif))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(isOn ? theme.accent.color.opacity(0.2) : theme.ink.color.opacity(0.06)))
                .overlay(Capsule().stroke(theme.ink.color.opacity(isOn ? 0.25 : 0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

struct TaskSectionView: View {
    @Environment(\.notebookTheme) private var theme
    let status: TaskStatus
    let tasks: [TaskItem]
    let pitch: CGFloat
    let onMove: (TaskItem) -> Void
    let onToggle: (TaskItem) -> Void
    let onOpen: (TaskItem) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.title)
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .highlighted(theme.highlighter[status])
                Text("\(tasks.count)").font(.system(size: 12, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
            .frame(height: pitch)
            if tasks.isEmpty {
                Text(targeted ? "Drop here" : "Nothing here")
                    .font(.system(size: 13, design: .serif)).italic()
                    .foregroundStyle(theme.dimInk.color)
                    .frame(height: pitch)
                    .padding(.leading, 28)
            }
            ForEach(tasks) { task in
                TaskRow(task: task, pitch: pitch, onToggle: { onToggle(task) }, onOpen: { onOpen(task) })
                    .draggable(task) {
                        Text(task.displayTitle).font(.system(size: 14, design: .serif))
                            .padding(6).background(theme.page.paperColor.color).cornerRadius(4)
                    }
            }
            Spacer().frame(height: pitch)
        }
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.accent.color.opacity(targeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(-6)
        )
        .dropDestination(for: TaskItem.self) { items, _ in
            for item in items { onMove(item) }
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeInOut(duration: 0.15), value: targeted)
    }
}

struct TaskRow: View {
    @Environment(\.notebookTheme) private var theme
    let task: TaskItem
    let pitch: CGFloat
    let onToggle: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(task.status == .notStarted ? theme.dimInk.color : theme.accent.color)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(task.isReadOnly)
            Text(task.displayTitle)
                .font(.system(size: 14.5, design: .serif))
                .strikethrough(task.status == .completed, color: theme.dimInk.color)
                .foregroundStyle(task.status == .completed ? theme.dimInk.color : theme.ink.color)
                .lineLimit(1)
                .highlighted(theme.highlighter[task.status])
            ForEach(task.tags, id: \.self) { tag in
                Text("#" + tag)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent.color.opacity(0.12)))
            }
            Spacer()
            if task.isReadOnly {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(theme.dimInk.color)
            }
            Button(action: onOpen) {
                Text(task.source.day.flatMap(DayKey.init)?.shortTitle ?? task.source.path)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(theme.dimInk.color)
                    .underline(hovering)
            }
            .buttonStyle(.plain)
            .help("Open in the daily note")
        }
        .frame(height: pitch)
        .padding(.leading, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var symbol: String {
        switch task.status {
        case .notStarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }
}
