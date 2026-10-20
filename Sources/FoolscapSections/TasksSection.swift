import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable
import FoolscapCore
import FoolscapEditor
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
    /// The tag filters, in the order they were chosen: a task shows when it carries all of them.
    var selectedTags: [String] = []
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
        knownTags = aggregator.knownTags(adding: library.knownTags)
    }
}

struct TasksPage: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.taskPens) private var pens
    @Bindable var section: TasksSection
    @State private var newTaskText = ""
    @FocusState private var newTaskFocused: Bool
    /// Selected task ids (click, ⌘-click, ⇧-click), moved together by drag or menu.
    @State private var selection: Set<String> = []
    /// Where a ⇧-click range starts.
    @State private var selectionAnchor: String?

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    static let fieldGap: CGFloat = 3

    var body: some View {
        // The ruling falls where the daily note's does, and the rows move with it.
        let palette = EditorPalette(theme: theme)
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    RulingView(pitch: pitch, topInset: pitch + PageRuling.ruleOffset(palette), marginX: PageRuling.textLeft)
                        .frame(minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { clearSelection() }
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        newTaskField
                            .frame(height: pitch)
                        // The gap under the field is borrowed from the header and the
                        // space below the strip, so the task rows stay on the ruling.
                        Spacer().frame(height: Self.fieldGap * 2)
                        CategoryStrip(tags: stripTags, selected: $section.selectedTags,
                                      wash: { tag in pens.pens.first { $0.tag == tag }?.colour.rgba(onDark: theme.isDark) },
                                      onDropTasks: { items, tag in
                                          // Dropped on a pen's chip, a task moves to that pen: its other pen tags come off.
                                          let others = pens.pens.map(\.tag).contains(tag) ? pens.pens.map(\.tag).filter { $0 != tag } : []
                                          section.aggregator.addTag(tag, to: items, replacing: others)
                                          clearSelection()
                                      })
                            .frame(height: pitch)
                        Spacer().frame(height: pitch / 2 - Self.fieldGap)
                        // The desk: what is in hand across the top, then what is
                        // next beside what is parked, and the done pile folded away.
                        group(.today, symbol: "sun.max")
                        HStack(alignment: .top, spacing: 0) {
                            group(.notStarted)
                            Rectangle().fill(theme.ink.color.opacity(0.12)).frame(width: 0.5)
                                .padding(.horizontal, 14).padding(.vertical, 4)
                            group(.someday)
                        }
                        group(.completed)
                        Spacer(minLength: pitch * 2)
                    }
                    .padding(.leading, PageRuling.textLeft)
                    .padding(.trailing, 44)
                    .padding(.top, pitch + PageRuling.rowShift(palette))
                }
            }
        }
        .foregroundStyle(theme.ink.color)
        .background {
            // ⌘N goes to the new-task field.
            Button("") { newTaskFocused = true }.keyboardShortcut("n", modifiers: [.command]).opacity(0)
            // Escape clears the selection.
            if !selection.isEmpty {
                Button("") { clearSelection() }.keyboardShortcut(.cancelAction).opacity(0)
            }
        }
        .onChange(of: section.selectedTags) { _, _ in clearSelection() }
        .task { await section.aggregator.reload(); section.refreshKnownTags() }
        .onChange(of: section.library.knownTags) { _, _ in section.refreshKnownTags() }
        .onChange(of: section.aggregator.tags) { _, _ in section.refreshKnownTags() }
    }

    private func group(_ status: TaskStatus, symbol: String? = nil) -> TaskSectionView {
        TaskSectionView(status: status, symbol: symbol,
                        tasks: section.aggregator.tasks(status: status, tags: section.selectedTags, pens: pens),
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
                        onRemoveTag: { section.aggregator.removeTag($1, from: $0) },
                        onSetPriority: { section.aggregator.setPriority($1, of: $0) })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tasks").font(theme.type.heading.font).fontWeight(.bold)
            Text("\(section.aggregator.tasks.count)").font(theme.type.body.face(13 * scale)).foregroundStyle(theme.dimInk.color)
            Spacer()
            if let err = section.aggregator.error { Text(err).font(theme.type.body.face(11 * scale)).foregroundStyle(.red) }
        }
        .frame(height: pitch * 1.5 - Self.fieldGap)
    }

    /// Always on the page, so adding tasks never takes a click first. Return adds
    /// and keeps the focus for the next one.
    private var newTaskField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.dimInk.color)
            TextField(newTaskPrompt, text: $newTaskText)
                .font(theme.type.body.face(14 * scale))
                .textFieldStyle(.plain)
                .focused($newTaskFocused)
                .onSubmit { submit() }
                .completesTags(in: $newTaskText, known: section.knownTags)
            TagCompletionRow(text: $newTaskText, known: section.knownTags)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(newTaskFocused ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(newTaskFocused ? 0.22 : 0.12), lineWidth: 0.5))
        .help("⌘N")
        // The field's text and placeholder follow the paper, not the system appearance.
        .colorScheme(theme.isDark ? .dark : .light)
    }

    /// Filtered by tags, the field says the new task will carry them.
    private var newTaskPrompt: String {
        if !section.selectedTags.isEmpty {
            let tags = section.selectedTags.map { "#" + $0 }.joined(separator: " ")
            return "Add a task tagged \(tags); more #tags, or start with ! for priority"
        }
        return "Add a task, with #tags; start with !! or !!! to raise its priority"
    }

    /// Tags of tasks still to do, the penned ones leading in pen order; the chosen
    /// filters stay until they are cleared, even once their last task is done.
    private var stripTags: [String] {
        var tags = section.aggregator.openTags
        for chosen in section.selectedTags where !tags.contains(chosen) { tags.append(chosen) }
        let penned = pens.pens.map(\.tag).filter { tags.contains($0) }
        return penned + tags.filter { !penned.contains($0) }
    }

    /// The selection, in list order, as tasks still present.
    private var selectedTasks: [TaskItem] {
        selection.isEmpty ? [] : section.aggregator.tasks.filter { selection.contains($0.id) }
    }

    private func clearSelection() {
        selection = []
        selectionAnchor = nil
    }

    /// A task added while the list is filtered by tags takes those tags, so it
    /// shows up in the list it was typed into.
    private func submit() {
        guard !newTaskText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let text = section.selectedTags.reduce(newTaskText) { TaskLineParser.addingTag($1, to: $0) }
        section.addTask(text)
        newTaskText = ""
        newTaskFocused = true
    }
}

/// The tag filters: any number at once, a task showing when it carries all of
/// them. A chip toggles its tag; "All" clears them. Tasks dropped on a tag chip get that tag.
struct CategoryStrip: View {
    let tags: [String]
    @Binding var selected: [String]
    /// A penned tag's highlighter, worn by its chip.
    var wash: (String) -> RGBA? = { _ in nil }
    let onDropTasks: ([TaskItem], String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                CategoryChip(label: "All", isOn: selected.isEmpty) { selected = [] }
                ForEach(tags, id: \.self) { tag in
                    CategoryChip(label: "#" + tag, isOn: selected.contains(tag), wash: wash(tag),
                                 onDrop: { onDropTasks($0, tag) }) { toggle(tag) }
                }
            }
            // Room for a targeted chip's scale ("All" leads and takes no drops).
            .padding(.trailing, 4).padding(.vertical, 2)
        }
    }

    private func toggle(_ tag: String) {
        if let i = selected.firstIndex(of: tag) { selected.remove(at: i) } else { selected.append(tag) }
    }
}

struct CategoryChip: View {
    let label: String
    let isOn: Bool
    var wash: RGBA? = nil
    /// Tasks dropped on the chip; nil for a chip that takes no drops ("All").
    var onDrop: (([TaskItem]) -> Void)?
    let action: () -> Void
    @State private var targeted = false

    var body: some View {
        let chip = FilterChip(label: label, isOn: isOn, isTargeted: targeted, wash: wash, action: action)
        if let onDrop {
            chip
                .dropDestination(for: TaskDrag.self) { drags, _ in
                    onDrop(drags.flatMap(\.tasks))
                    return true
                } isTargeted: { targeted = $0 }
                .help("Click to filter; drop tasks here to tag them")
        } else {
            chip
        }
    }
}

struct TaskSectionView: View {
    @Environment(\.notebookTheme) private var theme
    let status: TaskStatus
    /// A symbol beside the heading (the sun on Today, as on the daily page).
    let symbol: String?
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
    let onRemoveTag: (TaskItem, String) -> Void
    let onSetPriority: (TaskItem, TaskPriority) -> Void
    @State private var targeted = false
    private var scale: CGFloat { theme.type.body.size / 15 }
    @AppStorage private var folded: Bool
    @State private var showAll = false
    static let recentLimit = 8

    init(status: TaskStatus, symbol: String? = nil, tasks: [TaskItem], allTags: [String], pitch: CGFloat,
         selection: Binding<Set<String>>, selectionAnchor: Binding<String?>, selectedTasks: [TaskItem],
         onMove: @escaping ([TaskItem], TaskStatus) -> Void, onToggle: @escaping (TaskItem) -> Void, onOpen: @escaping (TaskItem) -> Void,
         onRename: @escaping (TaskItem, String) -> Void, onUpdate: @escaping (TaskItem, String, String?) -> Void,
         onAddTag: @escaping (TaskItem, String) -> Void, onRemoveTag: @escaping (TaskItem, String) -> Void,
         onSetPriority: @escaping (TaskItem, TaskPriority) -> Void) {
        self.status = status; self.symbol = symbol; self.tasks = tasks; self.allTags = allTags; self.pitch = pitch
        _selection = selection; _selectionAnchor = selectionAnchor; self.selectedTasks = selectedTasks
        self.onMove = onMove; self.onToggle = onToggle; self.onOpen = onOpen
        self.onRename = onRename; self.onUpdate = onUpdate; self.onAddTag = onAddTag; self.onRemoveTag = onRemoveTag
        self.onSetPriority = onSetPriority
        // The done pile starts folded; the lanes start open.
        _folded = AppStorage(wrappedValue: status == .completed, "fold." + status.rawValue)
    }

    /// Completed tasks pile up: show the most recent few unless asked for all.
    private var visibleTasks: [TaskItem] {
        guard status == .completed, !showAll, tasks.count > Self.recentLimit else { return tasks }
        return Array(tasks.prefix(Self.recentLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The heading and its rows; the Today lane is ringed like the daily page's list.
            VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.dimInk.color)
                    .rotationEffect(.degrees(folded ? 0 : 90))
                    .frame(width: 12)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.dimInk.color)
                }
                // Plain: highlighter colours belong to the pens (Today is ringed as a lane instead).
                Text(status.title)
                    .font(theme.type.heading.face(17 * scale, weight: .bold))
                Text("\(tasks.count)").font(theme.type.body.face(12 * scale)).foregroundStyle(theme.dimInk.color)
            }
            .frame(height: pitch)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { folded.toggle() } }
            if !folded {
                if tasks.isEmpty {
                    Text(targeted ? "Drop here" : emptyText)
                        .font(theme.type.body.face(13)).italic()
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
                            onRemoveTag: { onRemoveTag(task, $0) },
                            onSetPriority: { onSetPriority(task, $0) })
                        .draggable(TaskDrag(tasks: group)) {
                            Text(group.count > 1 ? "\(group.count) tasks" : task.displayTitle).font(theme.type.body.face(14))
                                .padding(6).background(theme.page.paperColor.color).cornerRadius(4)
                        }
                }
                if status == .completed, tasks.count > Self.recentLimit {
                    Button(showAll ? "Show only the last \(Self.recentLimit)" : "Show all \(tasks.count) completed") {
                        withAnimation { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(theme.type.body.face(12))
                    .foregroundStyle(theme.accent.color)
                    .frame(height: pitch)
                    .padding(.leading, 28)
                }
            } else if targeted {
                Text("Drop here").font(theme.type.body.face(13)).italic()
                    .foregroundStyle(theme.dimInk.color).frame(height: pitch).padding(.leading, 28)
            }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .ringed(status == .today ? (theme.highlighter[.today] ?? theme.accent) : RGBA(0, 0, 0, 0), pitch: pitch, isDark: theme.isDark)
            Spacer().frame(height: pitch)
        }
        // Every status box spans the column, so their drop outlines line up whatever they hold.
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var emptyText: String {
        switch status {
        case .today: return "Nothing for today; drag tasks here"
        case .someday: return "Nothing parked"
        default: return "Nothing here"
        }
    }

    /// What dragging or re-filing `task` moves: the whole selection when the
    /// task is part of it, otherwise just the task.
    private func movingGroup(for task: TaskItem) -> [TaskItem] {
        selection.contains(task.id) && selectedTasks.count > 1 ? selectedTasks : [task]
    }

    /// Click selects one task, ⌘-click adds or removes one, ⇧-click extends from
    /// the last clicked task within this section. Escape or a click on the page clears.
    private func select(_ task: TaskItem) {
        #if canImport(AppKit)
        let modifiers = NSEvent.modifierFlags
        let command = modifiers.contains(.command), shift = modifiers.contains(.shift)
        #else
        // A touch has no modifiers: a tap selects one task.
        let command = false, shift = false
        #endif
        if command {
            if selection.remove(task.id) == nil { selection.insert(task.id) }
            selectionAnchor = task.id
        } else if shift, let anchor = selectionAnchor,
                  let a = visibleTasks.firstIndex(where: { $0.id == anchor }),
                  let b = visibleTasks.firstIndex(where: { $0.id == task.id }) {
            selection.formUnion(visibleTasks[min(a, b)...max(a, b)].map(\.id))
        } else if shift {
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
    @Environment(\.taskPens) private var pens
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
    let onRemoveTag: (String) -> Void
    let onSetPriority: (TaskPriority) -> Void
    /// Set for a `#jira` task: a click on its title turns to the issue in the Jira tab.
    var onOpenIssue: (() -> Void)? = nil
    /// Keeps the pen's chip showing, in its colour, where no filter strip names the pens
    /// (the daily page's Today panel); the Tasks tab shows it only under the pointer.
    var showsPenTag = false
    @State private var hovering = false
    @State private var editing = false
    @State private var askTag = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: symbol)
                    .font(.system(size: 14 * scale, weight: .regular))
                    .foregroundStyle(task.status == .notStarted || task.status == .someday ? theme.dimInk.color : theme.accent.color)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .linkPointer()
            .help(task.isReadOnly ? "" : (task.status == .completed ? "Mark not done" : "Mark done"))
            .disabled(task.isReadOnly)
            PriorityLight(priority: task.priority, onSet: onSetPriority)
                .disabled(task.isReadOnly)
            if let onOpenIssue {
                // The Button takes the click before the row's own tap gesture.
                Button(action: onOpenIssue) { title.underline(hovering, color: theme.dimInk.color) }
                    .buttonStyle(.plain)
                    .linkPointer()
                    .help("Open in the Jira tab")
            } else {
                title
            }
            // The pen's tag is said by the stroke; the others stay as chips. The pen's own
            // chip shows in its colour, under the pointer (so the tag can still be taken off)
            // or always where nothing else says which tag a colour stands for.
            ForEach(task.tags.filter { $0 != pen?.tag }, id: \.self) { tag in
                TagChip(tag: tag, scale: scale, removable: !task.isReadOnly) { onRemoveTag(tag) }
            }
            if let pen {
                TagChip(tag: pen.tag, scale: scale, removable: !task.isReadOnly, tint: pen.colour.rgba(onDark: theme.isDark)) { onRemoveTag(pen.tag) }
                    .opacity(hovering || showsPenTag ? 1 : 0)
            }
            if let notes = task.notes {
                Button { editing = true } label: { Image(systemName: "text.alignleft").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimInk.color).help(notes)
            }
            if let link = task.firstLink {
                Button { Platform.openURL(link) } label: { Image(systemName: "link").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.accent.color).help(link.absoluteString)
            }
            // Kept mounted (just invisible) so a popover anchored here survives the pointer leaving the row.
            HStack(spacing: 8) {
                // In and out of Today: the sun takes a task there, the moon sends it back to To do.
                if task.status == .today {
                    Button { onSetStatus(.notStarted) } label: { Image(systemName: "moon").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(theme.dimInk.color).help("Back to To do")
                } else if task.status != .completed {
                    Button { onSetStatus(.today) } label: { Image(systemName: "sun.max").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(theme.dimInk.color).help("Do today")
                }
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
                        .font(theme.type.body.face(11 * scale))
                        .foregroundStyle(theme.dimInk.color)
                        .underline(hovering)
                }
                .buttonStyle(.plain)
                .help("Open in the daily note")
            } else if task.isReadOnly {
                Text(task.source.path).font(theme.type.body.face(11 * scale)).foregroundStyle(theme.dimInk.color)
            }
        }
        // Done rows lie faded under their strikethrough.
        .opacity(task.status == .completed ? 0.55 : 1)
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
                if !task.tags.isEmpty {
                    Menu("Remove Tag") {
                        ForEach(task.tags, id: \.self) { tag in Button("#" + tag) { onRemoveTag(tag) } }
                    }
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
            if let onOpenIssue { Button("Open in Jira Tab") { onOpenIssue() } }
        }
    }

    private var title: some View {
        Text(task.displayTitle)
            .font(theme.type.body.face(14.5 * scale))
            .strikethrough(task.status == .completed, color: theme.dimInk.color)
            .foregroundStyle(task.status == .completed ? theme.dimInk.color : theme.ink.color)
            .lineLimit(1)
            .highlighted(stroke)
    }

    /// The pen whose tag the task carries, if any (done tasks lie plain).
    private var pen: TagPen? { task.status == .completed ? nil : pens.pen(for: task)?.pen }

    /// A penned task is stroked in its pen and every other task lies plain: the lanes
    /// say the status, so a status colour would read as a pen (Sean, 2026-10-20).
    private var stroke: RGBA? { pen?.colour.rgba(onDark: theme.isDark) }

    private var symbol: String {
        switch task.status {
        case .today: return "circle.lefthalf.filled"
        case .notStarted: return "circle"
        case .someday: return "circle.dotted"
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
                Text("Edit Task").font(theme.type.heading.face(15, weight: .bold))
                TextField("Task text, with #tags", text: $title)
                    .font(theme.type.body.face(14))
                    .paperField()
                    .focused($titleFocused)
                    .onSubmit { onSave(title, notes) }
                    .completesTags(in: $title, known: allTags)
                TagCompletionRow(text: $title, known: allTags)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes and links").font(theme.type.body.face(11)).foregroundStyle(theme.dimInk.color)
                    TextEditor(text: $notes)
                        .font(theme.type.body.face(13))
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .frame(height: 76)
                        .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(0.15), lineWidth: 0.5))
                }
                HStack {
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

/// The priority "light" before a task: a coloured dot that opens a menu.
struct PriorityLight: View {
    @Environment(\.notebookTheme) private var theme
    let priority: TaskPriority
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
                Circle().fill(priority.color.color)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center))
                Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5)
            }
            .frame(width: 9, height: 9)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(priority.title) priority")
    }
}

private extension View {
    /// The pointing hand over the tick on the Mac; a phone has no pointer.
    @ViewBuilder
    func linkPointer() -> some View {
        #if canImport(AppKit)
        pointerStyle(.link)
        #else
        self
        #endif
    }
}
