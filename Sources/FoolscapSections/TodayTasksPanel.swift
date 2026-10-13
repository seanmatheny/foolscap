import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// Tasks marked today (`[/]`), from any note, gathered at the head of today's page.
public enum TodayTasks {
    /// The tasks that head today's page: those in the Today status, highest
    /// priority first, leaving out the ones written on today's own note (they
    /// are on the page already). A task ticked done while its id is in `keep`
    /// (shown on this visit) stays, struck through and last, so a tick does not
    /// whip the row away; the moon (back to To do) or Someday takes it off the
    /// page at once.
    public static func select(from tasks: [TaskItem], today: DayKey, keep: Set<String> = []) -> [TaskItem] {
        tasks.enumerated()
            .filter { $0.element.source.day != today.string
                && ($0.element.status == .today || ($0.element.status == .completed && keep.contains($0.element.id))) }
            .map { (offset: $0.offset, task: $0.element, priority: $0.element.priority, done: $0.element.status != .today) }
            .sorted { a, b in
                if a.done != b.done { return !a.done }
                return a.priority != b.priority ? a.priority > b.priority : a.offset < b.offset
            }
            .map(\.task)
    }
}

/// The Today list under the day's date, laid out like the Today band of the
/// Tasks tab (tick, priority, tags, notes and a way back to the note each task
/// came from). The editor lays it on the ruling in whole lines, one per row.
struct TodayTasksPanel: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: DailyNotesSection
    let aggregator: TaskAggregator
    /// Ids seen on this visit: a task ticked done stays, struck through, until the page is rebuilt.
    /// (One sent back to To do with the moon leaves at once.)
    @State private var shown: Set<String> = []
    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        let tasks = TodayTasks.select(from: aggregator.tasks, today: .today, keep: shown)
        let ids = tasks.map(\.id)
        Group {
            if !tasks.isEmpty {
                let allTags = aggregator.knownTags(adding: section.library.knownTags)
                let open = tasks.filter { $0.status == .today }.count
                VStack(alignment: .leading, spacing: 0) {
                    // The Tasks tab's section heading, with a sun where its fold chevron is.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "sun.max")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.dimInk.color)
                            .frame(width: 12)
                        Text("Today")
                            .font(.system(size: 17 * scale, weight: .bold, design: .serif))
                        Text("\(open)").font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                    }
                    .frame(height: pitch)
                    // Every row, however many: a list that scrolled inside the
                    // page hid the ones below the fold.
                    rows(tasks, allTags: allTags)
                }
                .foregroundStyle(theme.ink.color)
                // Ringed in the theme's Today colour, a faint wash inside a dashed line.
                // The ring is drawn around the rows, not laid out: the rows keep to the ruling.
                .background {
                    let tint = theme.highlighter[.today] ?? theme.accent
                    RoundedRectangle(cornerRadius: pitch * 0.75, style: .continuous)
                        .fill(tint.color.opacity(theme.isDark ? 0.10 : 0.14))
                        .overlay(RoundedRectangle(cornerRadius: pitch * 0.75, style: .continuous)
                            .strokeBorder(tint.color.opacity(theme.isDark ? 0.55 : 0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .padding(.horizontal, -12)
                        .padding(.vertical, -3)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: ids, initial: true) { _, ids in shown.formUnion(ids) }
    }

    private func rows(_ tasks: [TaskItem], allTags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(tasks) { task in
                TaskRow(task: task, pitch: pitch, allTags: allTags, isSelected: false, groupCount: 1,
                        onSelect: {},
                        onToggle: { aggregator.move(task, to: task.status.toggled) },
                        onOpen: { section.navigate(to: SectionRoute(path: task.source.path, line: task.source.line)) },
                        onSetStatus: { aggregator.move(task, to: $0) },
                        onUpdate: { aggregator.update(task, title: $0, notes: $1) },
                        onAddTag: { aggregator.addTag($0, to: task) },
                        onRemoveTag: { aggregator.removeTag($0, from: task) },
                        onSetPriority: { aggregator.setPriority($0, of: task) },
                        onOpenIssue: task.jiraIssueKey.map { key in { section.openRoute?(TaskItem.jiraSectionID, SectionRoute(path: key)) } })
            }
        }
    }
}
