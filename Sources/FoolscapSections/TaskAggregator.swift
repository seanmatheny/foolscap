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

    public func tasks(status: TaskStatus, tag: String?) -> [TaskItem] {
        tasks.filter { $0.status == status && (tag == nil || $0.tags.contains(tag!)) }
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

    public func addTag(_ tag: String, to task: TaskItem) {
        let clean = tag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        guard !clean.isEmpty, !task.tags.contains(clean) else { return }
        rename(task, to: task.title + " #" + clean)
    }

    public func move(_ task: TaskItem, to status: TaskStatus) {
        guard task.status != status, !task.isReadOnly,
              let provider = providers.first(where: { $0.id == task.providerID }) else { return }
        // Optimistic: update the list now, the file catches up.
        if let i = tasks.firstIndex(where: { $0.id == task.id }) { tasks[i].status = status }
        Task {
            do { try await provider.setStatus(status, of: task) }
            catch { self.error = "Could not update task: \(error)"; await reload() }
        }
    }
}
