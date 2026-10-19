import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

/// The Jira tab: the issues assigned to you, grouped by their Jira status, on
/// the same ruling as the Tasks tab; a field to add one, and on each row the
/// sun, a status menu and a comment bubble.
struct JiraPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: JiraSection
    @State private var newTaskText = ""
    @FocusState private var newTaskFocused: Bool
    /// Shared with Settings ▸ Jira: "" means no epic.
    @AppStorage(JiraSection.epicKey) private var epicKey = JiraSection.defaultEpic
    /// The issue lit for a moment after a route lands on it.
    @State private var flashKey: String?

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    static let fieldGap: CGFloat = 3

    var body: some View {
        let palette = EditorPalette(theme: theme)
        GeometryReader { geo in
            ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    RulingView(pitch: pitch, topInset: pitch + PageRuling.ruleOffset(palette), marginX: PageRuling.textLeft)
                        .frame(minHeight: geo.size.height)
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        if section.status.needsCredentials {
                            signIn
                        } else {
                            newTaskField
                                .frame(height: pitch)
                            // A full line between the field and the first group, as between the groups below.
                            Spacer().frame(height: pitch * 1.5 - Self.fieldGap)
                            if section.state.issues.isEmpty {
                                Text(section.status.isRunning ? (section.status.phase ?? "Fetching your issues…") : "Nothing assigned to you.")
                                    .font(theme.type.body.face(14 * scale)).italic().foregroundStyle(theme.dimInk.color)
                                    .frame(height: pitch)
                            } else {
                                ForEach(section.groups) { group in
                                    groupView(group)
                                }
                            }
                        }
                        Spacer(minLength: pitch * 2)
                    }
                    .padding(.leading, PageRuling.textLeft)
                    .padding(.trailing, 44)
                    .padding(.top, pitch + PageRuling.rowShift(palette))
                }
            }
            .onChange(of: section.pendingKey) { _, key in reveal(key, proxy) }
            // The route may land before the launch sync has filled the list.
            .onChange(of: section.state.issues.count) { _, _ in reveal(section.pendingKey, proxy) }
            }
        }
        .foregroundStyle(theme.ink.color)
        .background {
            // ⌘N goes to the new-task field.
            Button("") { newTaskFocused = true }.keyboardShortcut("n", modifiers: [.command]).opacity(0)
        }
    }

    /// Scroll the issue into the middle of the page and light its row for a moment.
    private func reveal(_ key: String?, _ proxy: ScrollViewProxy) {
        guard let key, section.state.issues.contains(where: { $0.key == key }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(key, anchor: .center) }
            flashKey = key
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            if flashKey == key { flashKey = nil }
            if section.pendingKey == key { section.pendingKey = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Jira").font(theme.type.heading.font).fontWeight(.bold)
            Text("\(section.openCount)").font(theme.type.body.face(13 * scale)).foregroundStyle(theme.dimInk.color)
            Spacer()
            Text(section.statusText).font(theme.type.body.face(12 * scale))
                .foregroundStyle(section.status.lastError == nil ? theme.dimInk.color : .red).lineLimit(1)
            if section.credentials != nil {
                Button {
                    section.syncNow()
                } label: {
                    Label(section.status.isRunning ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .font(theme.type.body.face(11.5, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(theme.accent.color.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .disabled(section.status.isRunning)
            }
        }
        .frame(height: pitch * 1.5 - Self.fieldGap)
    }

    /// Like the Tasks tab's: type the title, Return makes the task in Jira.
    private var newTaskField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.dimInk.color)
            TextField(section.newTaskPrompt, text: $newTaskText)
                .font(theme.type.body.face(14 * scale))
                .textFieldStyle(.plain)
                .focused($newTaskFocused)
                .onSubmit { submit() }
                .disabled(section.isCreating)
            epicMenu
            if section.isCreating { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(newTaskFocused ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(newTaskFocused ? 0.22 : 0.12), lineWidth: 0.5))
        .help("⌘N")
        .colorScheme(theme.isDark ? .dark : .light)
    }

    /// The epic the next task goes under, as the rows' epic chip; a menu of the project's open ones.
    private var epicMenu: some View {
        Menu {
            Button {
                section.setEpic(nil)
            } label: {
                if epicKey.isEmpty { Label("No epic", systemImage: "checkmark") } else { Text("No epic") }
            }
            Divider()
            if section.epics.isEmpty {
                Text("Sync to list the epics")
            } else {
                ForEach(section.epics) { epic in
                    Button {
                        section.setEpic(epic.key)
                    } label: {
                        let title = "\(epic.key)  \(epic.summary)"
                        if epic.key == epicKey { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(epicKey.isEmpty ? "No epic" : section.epicTitle(for: epicKey))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .epicChip(theme: theme, scale: scale, faint: epicKey.isEmpty)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(section.isCreating)
        .help(epicKey.isEmpty ? "New tasks go under no epic" : "New tasks go under \(epicKey)")
    }

    /// The text stays in the field when Jira refuses, with the reason in the status line.
    private func submit() {
        let text = newTaskText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            if await section.createTask(summary: text).value { newTaskText = "" }
            newTaskFocused = true
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect Foolscap to Jira Cloud with your site, your email and an API token, and the issues assigned to you appear here. A sun on an issue adds it to Today.")
                .font(theme.type.body.face(14 * scale)).opacity(0.75)
                .frame(maxWidth: 520, alignment: .leading)
            Button {
                UserDefaults.standard.set("jira", forKey: "settingsTab")
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Text("Open Settings…")
                    .font(theme.type.body.face(13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                    .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            if let error = section.status.lastError {
                Text(error).font(theme.type.body.face(13)).foregroundStyle(.red)
            }
        }
        .padding(.top, pitch / 2)
    }

    private func groupView(_ group: JiraSection.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.name)
                        .font(theme.type.heading.face(17 * scale, weight: .bold))
                    Text("\(group.issues.count)").font(theme.type.body.face(12 * scale)).foregroundStyle(theme.dimInk.color)
                }
                .frame(height: pitch)
                ForEach(group.issues) { issue in
                    JiraIssueRow(section: section, issue: issue, pitch: pitch, flashed: flashKey == issue.key)
                        .id(issue.key)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // In Progress is ringed like the Today lanes, in the Jira tab's own colour so the two read apart.
            .ringed(group.isActive ? theme.tabColor(at: 4) : RGBA(0, 0, 0, 0), pitch: pitch, isDark: theme.isDark)
            Spacer().frame(height: pitch)
        }
    }
}

struct JiraIssueRow: View {
    @Environment(\.notebookTheme) private var theme
    let section: JiraSection
    let issue: JiraIssue
    let pitch: CGFloat
    /// Lit after a route landed on this issue.
    var flashed = false
    @State private var hovering = false
    @State private var commenting = false
    @State private var draft = ""
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        let pulled = section.isPulled(issue)
        let busy = section.busyKeys.contains(issue.key)
        HStack(alignment: .center, spacing: 8) {
            // A toggle: filled while the task sits in Today, a click then sends it back to To do.
            Button { if pulled { section.park(issue) } else { section.pull(issue) } } label: {
                Image(systemName: pulled ? "sun.max.fill" : "sun.max")
                    .font(.system(size: 13 * scale, weight: .regular))
                    .foregroundStyle(pulled ? theme.accent.color : theme.dimInk.color)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help(pulled ? "In Today; click to send it back to To do" : "Pull into Today")
            Circle()
                .fill(TaskPriority(rawValue: issue.taskPriorityLevel)?.color.color ?? .clear)
                .frame(width: 8, height: 8)
                .help(issue.priority ?? "")
            Text(issue.key)
                .font(theme.type.mono.face(11.5 * scale, weight: .medium))
                .foregroundStyle(theme.dimInk.color)
            Text(issue.summary)
                .font(theme.type.body.face(14.5 * scale))
                .lineLimit(1)
            if let parent = issue.parentSummary {
                // The epic, as a chip in Jira's purple.
                Text(parent)
                    .epicChip(theme: theme, scale: scale)
                    .help("Epic: \(parent)")
            }
            statusChip(busy: busy)
            Spacer(minLength: 8)
            if let due = issue.dueDate {
                Text("due \(due)").font(theme.type.body.face(11.5 * scale)).foregroundStyle(theme.dimInk.color)
            }
            commentButton(busy: busy)
            Button { section.open(issue) } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12 * scale))
                    .foregroundStyle(theme.dimInk.color)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Open in Jira")
        }
        .frame(height: pitch)
        .background(RoundedRectangle(cornerRadius: 5).fill(theme.accent.color.opacity(flashed ? 0.18 : 0)).padding(.vertical, 2))
        .animation(.easeOut(duration: 0.6), value: flashed)
        .contentShape(Rectangle())
        .onHover { over in
            hovering = over
            // The transitions are fetched as the pointer arrives, so the menu opens ready.
            if over { section.prefetchTransitions(for: issue) }
        }
        .contextMenu {
            Button("Pull into Today") { section.pull(issue) }.disabled(pulled || busy)
            Menu("Change Status") { transitionItems }
            Button("Add Comment…") { commenting = true }
            Divider()
            Button("Open in Jira") { section.open(issue) }
            Button("Copy Key") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(issue.key, forType: .string)
            }
        }
    }

    /// The issue's status as a chip; a menu of where the workflow lets it go.
    private func statusChip(busy: Bool) -> some View {
        Menu {
            transitionItems
        } label: {
            HStack(spacing: 4) {
                if busy { ProgressView().controlSize(.mini) }
                Text(issue.statusName)
                    .font(theme.type.body.face(10.5 * scale, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(theme.dimInk.color)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(Capsule().fill(theme.ink.color.opacity(0.07)))
            .overlay(Capsule().stroke(theme.ink.color.opacity(0.14), lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(busy)
        .help("Change the status in Jira")
    }

    @ViewBuilder private var transitionItems: some View {
        if let transitions = section.transitionCache[issue.key] {
            ForEach(transitions) { t in
                Button {
                    section.setStatus(issue, to: t)
                } label: {
                    if t.toStatusName == issue.statusName { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
                .disabled(t.toStatusName == issue.statusName)
            }
        } else {
            Text("Loading…").onAppear { section.prefetchTransitions(for: issue) }
        }
    }

    private func commentButton(busy: Bool) -> some View {
        Button { commenting = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "bubble.left").font(.system(size: 11.5 * scale))
                if let n = issue.commentCount, n > 0 {
                    Text("\(n)").font(theme.type.body.face(10.5 * scale))
                }
            }
            .foregroundStyle(theme.dimInk.color)
        }
        .buttonStyle(.plain)
        .opacity(hovering || (issue.commentCount ?? 0) > 0 ? 1 : 0.35)
        .disabled(busy)
        .help("Add a comment in Jira")
        .popover(isPresented: $commenting, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Comment on \(issue.key)").font(theme.type.body.face(12, weight: .semibold))
                TextEditor(text: $draft)
                    .font(theme.type.body.face(13))
                    .frame(width: 360, height: 90)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                HStack {
                    Text("⌘↩ posts").font(theme.type.body.face(11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { commenting = false; draft = "" }.keyboardShortcut(.cancelAction)
                    Button("Post") { post() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
        }
    }

    private func post() {
        let text = draft
        commenting = false
        draft = ""
        section.comment(issue, body: text)
    }
}

extension View {
    /// An epic as a chip in Jira's purple; `faint` for "No epic".
    func epicChip(theme: NotebookTheme, scale: CGFloat, faint: Bool = false) -> some View {
        self
            .font(theme.type.body.face(10.5 * scale, weight: .medium))
            .foregroundStyle(faint ? theme.dimInk.color
                             : theme.isDark ? Color(red: 0.80, green: 0.74, blue: 0.95) : Color(red: 0.36, green: 0.24, blue: 0.62))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .background(Capsule().fill(faint ? theme.ink.color.opacity(0.07)
                                       : Color(red: 0.49, green: 0.37, blue: 0.80).opacity(theme.isDark ? 0.28 : 0.16)))
    }
}
