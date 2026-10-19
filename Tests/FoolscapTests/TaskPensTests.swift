import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapSections

/// The highlighter pens from Settings ▸ Tasks: which tag a task is stroked by, and the lane order.
@Suite @MainActor struct TaskPensTests {
    private func task(_ title: String, status: TaskStatus = .notStarted, line: Int = 0, day: String? = nil) -> TaskItem {
        TaskItem(providerID: "t", title: title, status: status, tags: TaskLineParser.tags(in: title), indent: 0,
                 source: TaskSource(path: day.map { "Daily/\($0).md" } ?? "Tasks.md", line: line, day: day))
    }

    @Test func roundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "foolscap-pens-\(UUID().uuidString)")!
        let pens = TaskPens([TagPen(tag: "lais", colour: .teal), TagPen(tag: "home", colour: .pink)])
        pens.save(to: defaults)
        #expect(TaskPens.load(from: defaults) == pens)
        #expect(TaskPens.load(from: defaults).sortsLanes)
        defaults.set(false, forKey: TaskPens.sortKey)
        #expect(!TaskPens.load(from: defaults).sortsLanes)
        #expect(TaskPens.load(from: UserDefaults(suiteName: "foolscap-pens-\(UUID().uuidString)")!).isEmpty)
        // A hand-written default, as `-taskPens '…'` passes one.
        defaults.set(#"[{"tag":"work","colour":"blue"}]"#, forKey: TaskPens.key)
        #expect(TaskPens.load(from: defaults).pens == [TagPen(tag: "work", colour: .blue)])
        // "mint" was renamed teal; a pen saved under the old name keeps its place.
        defaults.set(#"[{"tag":"lais","colour":"mint"}]"#, forKey: TaskPens.key)
        #expect(TaskPens.load(from: defaults).pens == [TagPen(tag: "lais", colour: .teal)])
        defaults.set("not json", forKey: TaskPens.key)
        #expect(TaskPens.load(from: defaults).isEmpty)
        // The plain form the argument domain keeps.
        defaults.set("#lais=mint, home=pink", forKey: TaskPens.key)
        #expect(TaskPens.load(from: defaults).pens == [TagPen(tag: "lais", colour: .teal), TagPen(tag: "home", colour: .pink)])
        #expect(TaskPens.parse("lais=plaid") == nil)
    }

    @Test func keepsEightDistinctNamedTags() {
        let typed = [TagPen(tag: "", colour: .green), TagPen(tag: "t0", colour: .blue), TagPen(tag: "t0", colour: .pink)]
            + (0..<12).map { TagPen(tag: "t\($0)", colour: .yellow) }
        let pens = TaskPens(typed)
        #expect(pens.pens.count == TaskPens.limit)
        #expect(pens.isFull)
        // The blank row is dropped and the first of a repeated tag wins.
        #expect(pens.pens.first == TagPen(tag: "t0", colour: .blue))
        #expect(pens.pens.map(\.tag) == ["t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7"])
    }

    @Test func theFirstPenInListOrderWins() {
        let pens = TaskPens([TagPen(tag: "lais", colour: .teal), TagPen(tag: "bau", colour: .yellow)])
        #expect(pens.pen(for: task("Both #bau #lais"))?.pen.tag == "lais")
        #expect(pens.pen(for: task("One #bau"))?.index == 1)
        #expect(pens.pen(for: task("None #home")) == nil)
        #expect(pens.laneRank(of: task("None")) == TaskPens.limit)
        #expect(pens.laneRank(of: task("x #bau")) == 1)
        #expect(pens.colour(for: task("x #bau"), onDark: true) == PenColour.yellow.rgba(onDark: true))
        #expect(pens.colour(for: task("x"), onDark: true) == nil)
        var off = pens
        off.sortsLanes = false
        #expect(off.laneRank(of: task("x #bau")) == 0)
        #expect(off.pen(for: task("x #bau"))?.pen.colour == .yellow)
    }

    @Test func todaysPageSortsPenByPenThenPriority() {
        let today = DayKey("2026-10-19")!
        let tasks = [
            task("Plain", status: .today, line: 1, day: "2026-10-18"),
            task("!! Urgent plain", status: .today, line: 2, day: "2026-10-18"),
            task("Home #home", status: .today, line: 3, day: "2026-10-17"),
            task("Lais late #lais", status: .today, line: 4, day: "2026-10-17"),
            task("!! Lais first #lais", status: .today, line: 5, day: "2026-10-16"),
            task("Both #home #lais", status: .today, line: 6, day: "2026-10-16"),
        ]
        let pens = TaskPens([TagPen(tag: "lais", colour: .teal), TagPen(tag: "home", colour: .pink)])
        #expect(TodayTasks.select(from: tasks, today: today, pens: pens).map(\.displayTitle)
                == ["Lais first", "Lais late", "Both", "Home", "Urgent plain", "Plain"])
        // Without pens, or with the sort off, priority then note order as before.
        #expect(TodayTasks.select(from: tasks, today: today).map(\.displayTitle)
                == ["Urgent plain", "Lais first", "Plain", "Home", "Lais late", "Both"])
        var off = pens
        off.sortsLanes = false
        #expect(TodayTasks.select(from: tasks, today: today, pens: off) == TodayTasks.select(from: tasks, today: today))
    }

    @Test func theTasksTabLanesSortByPen() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-pens-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let day = DayKey("2026-10-18")!
        try "# Day\n\n- [ ] Plain\n- [ ] Home #home\n- [ ] !! Urgent plain\n- [ ] Lais #lais\n- [>] Parked #home\n"
            .write(to: folder.url(for: day), atomically: true, encoding: .utf8)
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        let aggregator = TaskAggregator()
        aggregator.setProviders([DailyNotesTaskProvider(library: library)])
        await aggregator.reload()

        let pens = TaskPens([TagPen(tag: "lais", colour: .teal), TagPen(tag: "home", colour: .pink)])
        #expect(aggregator.tasks(status: .notStarted, pens: pens).map(\.displayTitle) == ["Lais", "Home", "Urgent plain", "Plain"])
        #expect(aggregator.tasks(status: .notStarted).map(\.displayTitle) == ["Urgent plain", "Plain", "Home", "Lais"])
        #expect(aggregator.tasks(status: .someday, pens: pens).map(\.displayTitle) == ["Parked"])
        // The filter still applies inside the pen order.
        #expect(aggregator.tasks(status: .notStarted, tags: ["home"], pens: pens).map(\.displayTitle) == ["Home"])

        // A drop on a pen's chip moves the task to that pen in one write: the other pen tags come off.
        let home = aggregator.tasks.first { $0.displayTitle == "Home" }!
        aggregator.addTag("lais", to: [home], replacing: ["home"])
        #expect(aggregator.tasks.first { $0.id == home.id }?.tags == ["lais"])
        try await Task.sleep(for: .milliseconds(300))
        let text = try String(contentsOf: folder.url(for: day), encoding: .utf8)
        #expect(text.contains("- [ ] Home #lais\n"))
        #expect(!text.contains("#home #lais"))
    }
}
