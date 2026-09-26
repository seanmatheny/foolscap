import SwiftUI
import FoolscapCore

/// Merges every section's tasks into one list and routes status changes back.
@MainActor
@Observable
public final class TaskAggregator {
    public private(set) var tasks: [TaskItem] = []
    public private(set) var tags: [String] = []
    public var error: String?
    private var providers: [any TaskProvider] = []
    private var listeners: [Task<Void, Never>] = []
    private var reloadTask: Task<Void, Never>?

    public init() {}

    public func setProviders(_ providers: [any TaskProvider]) {
        listeners.forEach { $0.cancel() }
        self.providers = providers
        listeners = providers.map { provider in
            Task { [weak self] in
                for await _ in provider.changes {
                    guard let self else { return }
                    self.scheduleReload()
                }
            }
        }
        scheduleReload()
    }

    /// Coalesce bursts of change notifications.
    public func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    public func reload() async {
        var all: [TaskItem] = []
        for p in providers {
            do { all += try await p.tasks() } catch { self.error = error.localizedDescription }
        }
        tasks = all
        var counts: [String: Int] = [:]
        for t in all { for tag in t.tags { counts[tag, default: 0] += 1 } }
        tags = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// Tags on tasks still to do, most used first: the Tasks tab filters only on these.
    public var openTags: [String] {
        var counts: [String: Int] = [:]
        for t in tasks where t.status != .completed { for tag in t.tags { counts[tag, default: 0] += 1 } }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// Tasks in one status section, highest priority first, otherwise in note order.
    public func tasks(status: TaskStatus, tag: String?) -> [TaskItem] {
        // Priority is parsed from the title: once per task, not once per comparison.
        tasks.enumerated()
            .filter { $0.element.status == status && (tag == nil || $0.element.tags.contains(tag!)) }
            .map { (offset: $0.offset, task: $0.element, priority: $0.element.priority) }
            .sorted { a, b in a.priority != b.priority ? a.priority > b.priority : a.offset < b.offset }
            .map(\.task)
    }

    public func setPriority(_ priority: TaskPriority, of task: TaskItem) {
        guard task.priority != priority else { return }
        rename(task, to: TaskLineParser.settingPriority(priority, in: task.title))
    }

    public func rename(_ task: TaskItem, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != task.title, !trimmed.isEmpty, !task.isReadOnly,
              let provider = providers.first(where: { $0.id == task.providerID }) else { return }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            var t = tasks[i]; t.title = trimmed; t.tags = TaskLineParser.tags(in: trimmed); tasks[i] = t
        }
        Task {
            do { try await provider.setTitle(trimmed, of: task) }
            catch { self.error = "Could not edit task: \(error)"; await reload() }
        }
    }

    /// Save edits from the task editor: notes first (they hang off the old title's line), then the title.
    public func update(_ task: TaskItem, title: String, notes: String?) {
        let cleanNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes = (cleanNotes?.isEmpty ?? true) ? nil : cleanNotes
        guard !task.isReadOnly, let provider = providers.first(where: { $0.id == task.providerID }) else { return }
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].notes = newNotes }
        Task {
            do {
                if newNotes != task.notes { try await provider.setNotes(newNotes, of: task) }
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed != task.title, !trimmed.isEmpty { try await provider.setTitle(trimmed, of: task) }
            } catch { self.error = "Could not edit task: \(error)" }
            await reload()
        }
    }

    public func addTag(_ tag: String, to task: TaskItem) { addTag(tag, to: [task]) }

    /// Tag several tasks at once (a drop onto a tag chip). Tasks that already carry
    /// the tag are left alone; the writes run one after another like `move`.
    public func addTag(_ tag: String, to items: [TaskItem]) {
        let clean = tag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard !clean.isEmpty else { return }
        let edits = items.compactMap { task -> (TaskItem, String, any TaskProvider)? in
            guard !task.tags.contains(clean), !task.isReadOnly,
                  let provider = providers.first(where: { $0.id == task.providerID }) else { return nil }
            return (task, task.title + " #" + clean, provider)
        }
        guard !edits.isEmpty else { return }
        for (task, title, _) in edits {
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].title = title; tasks[i].tags.append(clean) }
        }
        Task {
            for (task, title, provider) in edits {
                do { try await provider.setTitle(title, of: task) }
                catch { self.error = "Could not tag task: \(error)"; await reload(); return }
            }
        }
    }

    public func move(_ task: TaskItem, to status: TaskStatus) { move([task], to: status) }

    /// Several tasks at once (a selection or a multi-task drag). The writes run one
    /// after another, since tasks from the same note edit the same document.
    public func move(_ items: [TaskItem], to status: TaskStatus) {
        let moves = items.compactMap { task -> (TaskItem, any TaskProvider)? in
            guard task.status != status, !task.isReadOnly,
                  let provider = providers.first(where: { $0.id == task.providerID }) else { return nil }
            return (task, provider)
        }
        guard !moves.isEmpty else { return }
        // Optimistic: update the list now, the files catch up.
        for (task, _) in moves {
            if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].status = status }
        }
        Task {
            for (task, provider) in moves {
                do { try await provider.setStatus(status, of: task) }
                catch { self.error = "Could not update task: \(error)"; await reload(); return }
            }
        }
    }
}
