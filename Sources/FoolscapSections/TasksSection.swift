import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import FoolscapCore
import FoolscapStore
import FoolscapUI

extension UTType {
    static let foolscapTask = UTType(exportedAs: "com.seanmatheny.foolscap.task")
}

/// What a task drag carries: the dragged task, or the whole selection when the
/// task was part of one.
struct TaskDrag: Codable, Transferable {
    var tasks: [TaskItem]
    static var transferRepresentation: some TransferRepresentation {
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
    /// Every tag known anywhere, task tags (most used) first, then note-only tags.
    private(set) var knownTags: [String] = []

    public init(library: NotebookLibrary, openNote: @escaping (SectionRoute) -> Void) {
        self.library = library
        self.openNote = openNote
    }

    public func makeRootView() -> AnyView { AnyView(TasksPage(section: self)) }

    /// New tasks go to the standalone Tasks.md, so markdown stays the source of truth
    /// without touching a daily page.
    func addTask(_ text: String) { Task { await library.addStandaloneTask(text) } }

    func refreshKnownTags() {
        var seen = Set<String>()
        knownTags = (aggregator.tags + library.knownTags).filter { seen.insert($0).inserted }
    }
}

struct TasksPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: TasksSection
    @State private var showNewTask = false
    @State private var newTaskText = ""
    /// Selected task ids (click, ⌘-click, ⇧-click), moved together by drag or menu.
    @State private var selection: Set<String> = []
    /// Where a ⇧-click range starts.
    @State private var selectionAnchor: String?

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    RulingView(pitch: pitch, topInset: pitch * 2 - 4, marginX: 58)
                        .frame(minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { clearSelection() }
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        CategoryStrip(tags: stripTags, selected: $section.selectedTag)
                            .frame(height: pitch)
                        Spacer().frame(height: pitch / 2)
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            TaskSectionView(status: status,
                                            tasks: section.aggregator.tasks(status: status, tag: section.selectedTag),
                                            allTags: section.knownTags,
                                            pitch: pitch,
                                            selection: $selection,
                                            selectionAnchor: $selectionAnchor,
                                            selectedTasks: selectedTasks,
                                            onMove: { items, target in section.aggregator.move(items, to: target); clearSelection() },
                                            onToggle: { section.aggregator.move($0, to: $0.status.toggled) },
                                            onOpen: { section.openNote(SectionRoute(path: $0.source.path, line: $0.source.line)) },
                                            onRename: { section.aggregator.rename($0, to: $1) },
                                            onUpdate: { section.aggregator.update($0, title: $1, notes: $2) },
                                            onAddTag: { section.aggregator.addTag($1, to: $0) },
                                            onSetPriority: { section.aggregator.setPriority($1, of: $0) })
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
        .background {
            // Escape clears the selection.
            if !selection.isEmpty {
                Button("") { clearSelection() }.keyboardShortcut(.cancelAction).opacity(0)
            }
        }
        .onChange(of: section.selectedTag) { _, _ in clearSelection() }
        .task { await section.aggregator.reload(); section.refreshKnownTags() }
        .onChange(of: section.library.knownTags) { _, _ in section.refreshKnownTags() }
        .onChange(of: section.aggregator.tags) { _, _ in section.refreshKnownTags() }
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
                            .completesTags(in: $newTaskText, known: section.knownTags)
                        TagCompletionRow(text: $newTaskText, known: section.knownTags)
                        Text("Start with !, !! or !!! for low, medium or high priority.")
                            .font(.caption).foregroundStyle(theme.dimInk.color)
                    }
                }
            }
            if let err = section.aggregator.error { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .frame(height: pitch * 1.5)
    }

    /// Tags of tasks still to do; the chosen filter stays until it is cleared,
    /// even once its last task is done.
    private var stripTags: [String] {
        var tags = section.aggregator.openTags
        if let chosen = section.selectedTag, !tags.contains(chosen) { tags.append(chosen) }
        return tags
    }

    /// The selection, in list order, as tasks still present.
    private var selectedTasks: [TaskItem] {
        selection.isEmpty ? [] : section.aggregator.tasks.filter { selection.contains($0.id) }
    }

    private func clearSelection() {
        selection = []
        selectionAnchor = nil
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
    @Binding var selection: Set<String>
    @Binding var selectionAnchor: String?
    let selectedTasks: [TaskItem]
    let onMove: ([TaskItem], TaskStatus) -> Void
    let onToggle: (TaskItem) -> Void
    let onOpen: (TaskItem) -> Void
    let onRename: (TaskItem, String) -> Void
    let onUpdate: (TaskItem, String, String?) -> Void
    let onAddTag: (TaskItem, String) -> Void
    let onSetPriority: (TaskItem, TaskPriority) -> Void
    @State private var targeted = false
    private var scale: CGFloat { theme.type.body.size / 15 }
    @AppStorage private var folded: Bool
    @State private var showAll = false
    static let recentLimit = 8

    init(status: TaskStatus, tasks: [TaskItem], allTags: [String], pitch: CGFloat,
         selection: Binding<Set<String>>, selectionAnchor: Binding<String?>, selectedTasks: [TaskItem],
         onMove: @escaping ([TaskItem], TaskStatus) -> Void, onToggle: @escaping (TaskItem) -> Void, onOpen: @escaping (TaskItem) -> Void,
         onRename: @escaping (TaskItem, String) -> Void, onUpdate: @escaping (TaskItem, String, String?) -> Void,
         onAddTag: @escaping (TaskItem, String) -> Void, onSetPriority: @escaping (TaskItem, TaskPriority) -> Void) {
        self.status = status; self.tasks = tasks; self.allTags = allTags; self.pitch = pitch
        _selection = selection; _selectionAnchor = selectionAnchor; self.selectedTasks = selectedTasks
        self.onMove = onMove; self.onToggle = onToggle; self.onOpen = onOpen
        self.onRename = onRename; self.onUpdate = onUpdate; self.onAddTag = onAddTag; self.onSetPriority = onSetPriority
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
                    let group = movingGroup(for: task)
                    TaskRow(task: task, pitch: pitch, allTags: allTags,
                            isSelected: selection.contains(task.id), groupCount: group.count,
                            onSelect: { select(task) },
                            onToggle: { onToggle(task) }, onOpen: { onOpen(task) },
                            onSetStatus: { onMove(group, $0) },
                            onUpdate: { onUpdate(task, $0, $1) }, onAddTag: { onAddTag(task, $0) },
                            onSetPriority: { onSetPriority(task, $0) })
                        .draggable(TaskDrag(tasks: group)) {
                            Text(group.count > 1 ? "\(group.count) tasks" : task.displayTitle).font(.system(size: 14, design: .serif))
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
        .onTapGesture { selection = []; selectionAnchor = nil }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.accent.color.opacity(targeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .padding(-6)
        )
        .dropDestination(for: TaskDrag.self) { drags, _ in
            onMove(drags.flatMap(\.tasks), status)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeInOut(duration: 0.15), value: targeted)
    }

    /// What dragging or re-filing `task` moves: the whole selection when the
    /// task is part of it, otherwise just the task.
    private func movingGroup(for task: TaskItem) -> [TaskItem] {
        selection.contains(task.id) && selectedTasks.count > 1 ? selectedTasks : [task]
    }

    /// Click selects one task, ⌘-click adds or removes one, ⇧-click extends from
    /// the last clicked task within this section. Escape or a click on the page clears.
    private func select(_ task: TaskItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            if selection.remove(task.id) == nil { selection.insert(task.id) }
            selectionAnchor = task.id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor,
                  let a = visibleTasks.firstIndex(where: { $0.id == anchor }),
                  let b = visibleTasks.firstIndex(where: { $0.id == task.id }) {
            selection.formUnion(visibleTasks[min(a, b)...max(a, b)].map(\.id))
        } else if modifiers.contains(.shift) {
            selection.insert(task.id)
            selectionAnchor = task.id
        } else {
            selection = [task.id]
            selectionAnchor = task.id
        }
    }
}

struct TaskRow: View {
    @Environment(\.notebookTheme) private var theme
    let task: TaskItem
    let pitch: CGFloat
    let allTags: [String]
    let isSelected: Bool
    /// How many tasks the status menu items move: this one, or the selection it belongs to.
    let groupCount: Int
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onSetStatus: (TaskStatus) -> Void
    let onUpdate: (String, String?) -> Void
    let onAddTag: (String) -> Void
    let onSetPriority: (TaskPriority) -> Void
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
            PriorityLight(priority: task.priority, visible: hovering || task.priority != .none, onSet: onSetPriority)
                .disabled(task.isReadOnly)
            Text(task.displayTitle)
                .font(.system(size: 14.5 * scale, design: .serif))
                .strikethrough(task.status == .completed, color: theme.dimInk.color)
                .foregroundStyle(task.status == .completed ? theme.dimInk.color : theme.ink.color)
                .lineLimit(1)
                .highlighted(theme.highlighter[task.status])
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
            } else if task.isReadOnly {
                Text(task.source.path).font(.system(size: 11 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
        }
        .frame(height: pitch)
        .padding(.leading, 8)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.accent.color.opacity(isSelected ? 0.16 : 0)).padding(.vertical, 2))
        .contentShape(Rectangle())
        // A click selects at once; a second click edits (the buttons in the row keep their own clicks).
        .gesture(TapGesture(count: 2).onEnded { if !task.isReadOnly { editing = true } }
            .simultaneously(with: TapGesture().onEnded { onSelect() }))
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
                Menu("Priority") {
                    ForEach(TaskPriority.allCases, id: \.self) { p in
                        Button { onSetPriority(p) } label: {
                            if p == task.priority { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                        }
                    }
                }
                ForEach(TaskStatus.allCases.filter { groupCount > 1 || $0 != task.status }, id: \.self) { target in
                    Button(groupCount > 1 ? "Move \(groupCount) Tasks to \(target.title)" : "Mark \(target.title)") { onSetStatus(target) }
                }
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
                    .completesTags(in: $title, known: allTags)
                TagCompletionRow(text: $title, known: allTags)
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
                HStack {
                    Text(task.source.day == nil ? "Saved into Tasks.md." : "Saved into the daily note.").font(.caption).foregroundStyle(theme.dimInk.color)
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
                TextField("Tag", text: $newTag)
                    .font(.system(size: 13, design: .serif))
                    .paperField().frame(width: 200)
                    .focused($focused)
                    .onSubmit { onPick(choices.first ?? newTag) }
                    .onKeyPress(.tab) {
                        guard let first = choices.first, first != typed else { return .ignored }
                        newTag = first; return .handled
                    }
                if !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(choices, id: \.self) { tag in
                            Button("#" + tag) { onPick(tag) }
                                .buttonStyle(.plain).font(.system(size: 12.5, design: .serif))
                                .foregroundStyle(theme.accent.color)
                        }
                    }
                } else if !typed.isEmpty {
                    Text("New tag #\(typed)").font(.system(size: 11, design: .serif)).foregroundStyle(theme.dimInk.color)
                }
            }
        }
        .onAppear { focused = true }
    }

    /// What has been typed, as a tag: no `#`, lowercased.
    private var typed: String {
        newTag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
    }

    /// Known tags starting with what was typed (all of them before typing), minus the task's own.
    private var choices: [String] {
        let t = typed
        return allTags.filter { !existing.contains($0) && (t.isEmpty || $0.hasPrefix(t)) }.prefix(8).map { $0 }
    }
}

/// The priority "light" before a task: a coloured dot that opens a menu.
struct PriorityLight: View {
    @Environment(\.notebookTheme) private var theme
    let priority: TaskPriority
    let visible: Bool
    let onSet: (TaskPriority) -> Void

    var body: some View {
        Menu {
            ForEach(TaskPriority.allCases, id: \.self) { p in
                Button { onSet(p) } label: {
                    if p == priority { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
        } label: {
            ZStack {
                if let color = priority.color {
                    Circle().fill(color.color)
                    Circle().fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center))
                    Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                } else {
                    Circle().stroke(theme.dimInk.color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
                }
            }
            .frame(width: 9, height: 9)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(visible ? 1 : 0)
        .help(priority == .none ? "Set a priority" : "\(priority.title) priority")
    }
}

/// Chips for the `#tag` being typed at the end of a field; click one to complete it.
struct TagCompletionRow: View {
    @Environment(\.notebookTheme) private var theme
    @Binding var text: String
    let known: [String]

    var body: some View {
        if let partial = TagCompletion.partial(in: text) {
            let matches = TagCompletion.matches(for: partial.text, in: known)
            if !matches.isEmpty {
                HStack(spacing: 6) {
                    ForEach(matches, id: \.self) { tag in
                        Button("#" + tag) { text = TagCompletion.completing(text, partial: partial, with: tag) }
                            .buttonStyle(.plain).font(.system(size: 11, design: .serif))
                            .foregroundStyle(theme.accent.color)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent.color.opacity(0.12)))
                    }
                    Text("⇥").font(.system(size: 10)).foregroundStyle(theme.dimInk.color)
                }
            }
        }
    }
}

extension View {
    /// Tab completes the `#tag` being typed at the end of the field with the best match.
    func completesTags(in text: Binding<String>, known: [String]) -> some View {
        onKeyPress(.tab) {
            guard let partial = TagCompletion.partial(in: text.wrappedValue),
                  let first = TagCompletion.matches(for: partial.text, in: known).first else { return .ignored }
            text.wrappedValue = TagCompletion.completing(text.wrappedValue, partial: partial, with: first)
            return .handled
        }
    }
}
