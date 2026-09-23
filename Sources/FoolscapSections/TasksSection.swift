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
    public let tab = TabAppearance(label: "Tasks", systemImage: "checklist", shortcut: "t")
    public let aggregator = TaskAggregator()
    let library: NotebookLibrary
    let openNote: (SectionRoute) -> Void
    var selectedTag: String?

    public init(library: NotebookLibrary, openNote: @escaping (SectionRoute) -> Void) {
        self.library = library
        self.openNote = openNote
    }

    public func makeRootView() -> AnyView { AnyView(TasksPage(section: self)) }

    /// New tasks go to the standalone Tasks.md, so markdown stays the source of truth
    /// without touching a daily page.
    func addTask(_ text: String) { library.addStandaloneTask(text) }
}

struct TasksPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: TasksSection
    @State private var showNewTask = false
    @State private var newTaskText = ""

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(minHeight: geo.size.height)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        CategoryStrip(tags: section.aggregator.tags, selected: $section.selectedTag)
                            .frame(height: pitch)
                        Spacer().frame(height: pitch / 2)
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            TaskSectionView(status: status,
                                            tasks: section.aggregator.tasks(status: status, tag: section.selectedTag),
                                            allTags: section.aggregator.tags,
                                            pitch: pitch,
                                            onMove: { section.aggregator.move($0, to: status) },
                                            onToggle: { section.aggregator.move($0, to: $0.status.next) },
                                            onOpen: { section.openNote(SectionRoute(path: $0.source.path, line: $0.source.line)) },
                                            onRename: { section.aggregator.rename($0, to: $1) },
                                            onUpdate: { section.aggregator.update($0, title: $1, notes: $2) },
                                            onAddTag: { section.aggregator.addTag($1, to: $0) })
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
            Text("\(section.aggregator.tasks.count)").font(.system(size: 13 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
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
                PaperPopover {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Task, with #category", text: $newTaskText)
                            .paperField().frame(width: 320)
                            .onSubmit { submit() }
                        Text("Kept in Tasks.md in your notebook folder.").font(.caption).foregroundStyle(theme.dimInk.color)
                    }
                }
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
    let allTags: [String]
    let pitch: CGFloat
    let onMove: (TaskItem) -> Void
    let onToggle: (TaskItem) -> Void
    let onOpen: (TaskItem) -> Void
    let onRename: (TaskItem, String) -> Void
    let onUpdate: (TaskItem, String, String?) -> Void
    let onAddTag: (TaskItem, String) -> Void
    @State private var targeted = false
    private var scale: CGFloat { theme.type.body.size / 15 }
    @AppStorage private var folded: Bool
    @State private var showAll = false
    static let recentLimit = 8

    init(status: TaskStatus, tasks: [TaskItem], allTags: [String], pitch: CGFloat,
         onMove: @escaping (TaskItem) -> Void, onToggle: @escaping (TaskItem) -> Void, onOpen: @escaping (TaskItem) -> Void,
         onRename: @escaping (TaskItem, String) -> Void, onUpdate: @escaping (TaskItem, String, String?) -> Void,
         onAddTag: @escaping (TaskItem, String) -> Void) {
        self.status = status; self.tasks = tasks; self.allTags = allTags; self.pitch = pitch
        self.onMove = onMove; self.onToggle = onToggle; self.onOpen = onOpen
        self.onRename = onRename; self.onUpdate = onUpdate; self.onAddTag = onAddTag
        _folded = AppStorage(wrappedValue: false, "fold." + status.rawValue)
    }

    /// Completed tasks pile up: show the most recent few unless asked for all.
    private var visibleTasks: [TaskItem] {
        guard status == .completed, !showAll, tasks.count > Self.recentLimit else { return tasks }
        return Array(tasks.prefix(Self.recentLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.dimInk.color)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 12)
                Text(status.title)
                    .font(.system(size: 17 * scale, weight: .bold, design: .serif))
                    .highlighted(theme.highlighter[status])
                Text("\(tasks.count)").font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
            .frame(height: pitch)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { folded.toggle() } }
            if !folded {
                if tasks.isEmpty {
                    Text(targeted ? "Drop here" : "Nothing here")
                        .font(.system(size: 13, design: .serif)).italic()
                        .foregroundStyle(theme.dimInk.color)
                        .frame(height: pitch)
                        .padding(.leading, 28)
                }
                ForEach(visibleTasks) { task in
                    TaskRow(task: task, pitch: pitch, allTags: allTags,
                            onToggle: { onToggle(task) }, onOpen: { onOpen(task) },
                            onUpdate: { onUpdate(task, $0, $1) }, onAddTag: { onAddTag(task, $0) })
                        .draggable(task) {
                            Text(task.displayTitle).font(.system(size: 14, design: .serif))
                                .padding(6).background(theme.page.paperColor.color).cornerRadius(4)
                        }
                }
                if status == .completed, tasks.count > Self.recentLimit {
                    Button(showAll ? "Show only the last \(Self.recentLimit)" : "Show all \(tasks.count) completed") {
                        withAnimation { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(theme.accent.color)
                    .frame(height: pitch)
                    .padding(.leading, 28)
                }
            } else if targeted {
                Text("Drop here").font(.system(size: 13, design: .serif)).italic()
                    .foregroundStyle(theme.dimInk.color).frame(height: pitch).padding(.leading, 28)
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
    let allTags: [String]
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onUpdate: (String, String?) -> Void
    let onAddTag: (String) -> Void
    @State private var hovering = false
    @State private var editing = false
    @State private var askTag = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: symbol)
                    .font(.system(size: 14 * scale, weight: .regular))
                    .foregroundStyle(task.status == .notStarted ? theme.dimInk.color : theme.accent.color)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(task.isReadOnly)
            Text(task.displayTitle)
                .font(.system(size: 14.5 * scale, design: .serif))
                .strikethrough(task.status == .completed, color: theme.dimInk.color)
                .foregroundStyle(task.status == .completed ? theme.dimInk.color : theme.ink.color)
                .lineLimit(1)
                .highlighted(theme.highlighter[task.status])
                .onTapGesture(count: 2) { if !task.isReadOnly { editing = true } }
            ForEach(task.tags, id: \.self) { tag in
                Text("#" + tag)
                    .font(.system(size: 11 * scale, design: .serif))
                    .foregroundStyle(theme.accent.color)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent.color.opacity(0.12)))
            }
            if let notes = task.notes {
                Button { editing = true } label: { Image(systemName: "text.alignleft").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimInk.color).help(notes)
            }
            if let link = task.firstLink {
                Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "link").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.accent.color).help(link.absoluteString)
            }
            // Kept mounted (just invisible) so a popover anchored here survives the pointer leaving the row.
            HStack(spacing: 8) {
                Button { editing = true } label: { Image(systemName: "pencil").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimInk.color).help("Edit (double-click)")
                    .popover(isPresented: $editing, arrowEdge: .bottom) {
                        TaskEditPopover(task: task, allTags: allTags, onSave: { title, notes in onUpdate(title, notes); editing = false })
                    }
                Button { askTag = true } label: { Image(systemName: "tag").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimInk.color).help("Add a tag")
                    .popover(isPresented: $askTag, arrowEdge: .bottom) { TagPopover(allTags: allTags, existing: task.tags) { onAddTag($0); askTag = false } }
            }
            .opacity(hovering && !task.isReadOnly ? 1 : 0)
            .disabled(task.isReadOnly)
            Spacer()
            if task.isReadOnly {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(theme.dimInk.color)
            }
            if let day = task.source.day.flatMap(DayKey.init) {
                Button(action: onOpen) {
                    Text(day.shortTitle)
                        .font(.system(size: 11 * scale, design: .serif))
                        .foregroundStyle(theme.dimInk.color)
                        .underline(hovering)
                }
                .buttonStyle(.plain)
                .help("Open in the daily note")
            } else if !task.isReadOnly {
                Text("Tasks").font(.system(size: 11 * scale, design: .serif)).foregroundStyle(theme.dimInk.color.opacity(0.7))
            } else {
                Text(task.source.path).font(.system(size: 11 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
        }
        .frame(height: pitch)
        .padding(.leading, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if !task.isReadOnly {
                Button("Edit Task…") { editing = true }
                Menu("Add Tag") {
                    ForEach(allTags.filter { !task.tags.contains($0) }, id: \.self) { tag in
                        Button("#" + tag) { onAddTag(tag) }
                    }
                    Divider()
                    Button("New Tag…") { askTag = true }
                }
                Button("Mark \(task.status.next.title)") { onToggle() }
                Divider()
            }
            if task.source.day != nil { Button("Open in Daily Note") { onOpen() } }
        }
    }

    private var symbol: String {
        switch task.status {
        case .notStarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

/// Edit a task's single-line text and its notes (kept as indented lines under it).
struct TaskEditPopover: View {
    let task: TaskItem
    let allTags: [String]
    let onSave: (String, String?) -> Void
    @State private var title: String
    @State private var notes: String
    @FocusState private var titleFocused: Bool

    init(task: TaskItem, allTags: [String], onSave: @escaping (String, String?) -> Void) {
        self.task = task; self.allTags = allTags; self.onSave = onSave
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes ?? "")
    }

    @Environment(\.notebookTheme) private var theme

    var body: some View {
        PaperPopover {
            VStack(alignment: .leading, spacing: 10) {
                Text("Edit Task").font(.system(size: 15, weight: .bold, design: .serif))
                TextField("Task text, with #tags", text: $title)
                    .font(.system(size: 14, design: .serif))
                    .paperField()
                    .focused($titleFocused)
                    .onSubmit { onSave(title, notes) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes and links").font(.caption).foregroundStyle(theme.dimInk.color)
                    TextEditor(text: $notes)
                        .font(.system(size: 13, design: .serif))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(0.15), lineWidth: 0.5))
                }
                if !allTags.isEmpty {
                    HStack(spacing: 6) {
                        Text("Tags:").font(.caption).foregroundStyle(theme.dimInk.color)
                        ForEach(allTags.prefix(6), id: \.self) { tag in
                            Button("#" + tag) { if !title.contains("#" + tag) { title += " #" + tag } }
                                .buttonStyle(.plain).font(.system(size: 11, design: .serif))
                                .foregroundStyle(theme.accent.color)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(theme.accent.color.opacity(0.12)))
                        }
                    }
                }
                HStack {
                    Text("Saved into the daily note.").font(.caption).foregroundStyle(theme.dimInk.color)
                    Spacer()
                    Button("Save") { onSave(title, notes) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(width: 380)
        }
        .onAppear { titleFocused = true }
    }
}

struct TagPopover: View {
    let allTags: [String]
    let existing: [String]
    let onPick: (String) -> Void
    @State private var newTag = ""
    @FocusState private var focused: Bool

    @Environment(\.notebookTheme) private var theme

    var body: some View {
        PaperPopover {
            VStack(alignment: .leading, spacing: 8) {
                TextField("New tag", text: $newTag)
                    .font(.system(size: 13, design: .serif))
                    .paperField().frame(width: 200)
                    .focused($focused)
                    .onSubmit { onPick(newTag) }
                let choices = allTags.filter { !existing.contains($0) }
                if !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(choices.prefix(8), id: \.self) { tag in
                            Button("#" + tag) { onPick(tag) }
                                .buttonStyle(.plain).font(.system(size: 12.5, design: .serif))
                                .foregroundStyle(theme.accent.color)
                        }
                    }
                }
            }
        }
        .onAppear { focused = true }
    }
}
