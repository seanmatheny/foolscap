import Testing
import Foundation
@testable import FoolscapCore

@Suite struct TaskLineParserTests {
    @Test func parsesFourStatuses() {
        #expect(TaskLineParser.parse("- [ ] Buy milk")?.status == .notStarted)
        #expect(TaskLineParser.parse("  * [/] Write plan")?.status == .today)
        #expect(TaskLineParser.parse("- [>] One day")?.status == .someday)
        #expect(TaskLineParser.parse("1. [x] Done")?.status == .completed)
        #expect(TaskLineParser.parse("- [X] Done")?.status == .completed)
        #expect(TaskLineParser.parse("- [?] Not a mark") == nil)
    }

    /// The Tasks tab and the menus follow the declaration order; the editor's
    /// checkbox walks to do → today → done, and starts a parked task.
    @Test func statusOrderAndCycle() {
        #expect(TaskStatus.allCases == [.today, .notStarted, .someday, .completed])
        #expect(TaskStatus.allCases.map(\.mark) == ["/", " ", ">", "x"])
        #expect(TaskStatus.notStarted.next == .today && TaskStatus.today.next == .completed)
        #expect(TaskStatus.completed.next == .notStarted && TaskStatus.someday.next == .today)
        #expect(TaskStatus.someday.isOpen && !TaskStatus.completed.isOpen)
    }

    @Test func rejectsNonTasks() {
        #expect(TaskLineParser.parse("- Buy milk") == nil)
        #expect(TaskLineParser.parse("[ ] no bullet") == nil)
        #expect(TaskLineParser.parse("- [ ]") == nil)
        #expect(TaskLineParser.parse("- [?] weird") == nil)
    }

    @Test func findsAJiraIssueKeyAtTheStart() {
        #expect(TaskLineParser.issueKey(in: "CPAS-12 Fix the thing #jira") == "CPAS-12")
        #expect(TaskLineParser.issueKey(in: "!! CPAS-12 Fix the thing") == "CPAS-12")
        #expect(TaskLineParser.issueKey(in: "cpas-12 Fix") == nil)
        #expect(TaskLineParser.issueKey(in: "Fix CPAS-12") == nil)
        #expect(TaskLineParser.issueKey(in: "CPAS-12x") == nil)
        let source = TaskSource(path: "Tasks.md", line: 1, day: nil)
        let jira = TaskItem(providerID: "daily", title: "CPAS-12 Fix #jira", status: .today, tags: ["jira"], indent: 0, source: source)
        let plain = TaskItem(providerID: "daily", title: "CPAS-12 Fix", status: .today, tags: [], indent: 0, source: source)
        #expect(jira.jiraIssueKey == "CPAS-12" && plain.jiraIssueKey == nil)
    }

    @Test func extractsTags() {
        let p = TaskLineParser.parse("- [ ] Email Dave about #work/hpc and `#notatag` C#")!
        #expect(p.tags == ["work/hpc"])
        #expect(TaskLineParser.stripTags(from: p.title) == "Email Dave about and `#notatag` C#")
    }

    @Test func removesOneTagAndKeepsTheRest() {
        #expect(TaskLineParser.removingTag("bau", from: "Lais disk space alerts #bau #lais") == "Lais disk space alerts #lais")
        #expect(TaskLineParser.removingTag("lais", from: "Lais disk space alerts #bau #lais") == "Lais disk space alerts #bau")
        // Mid-text, leading (after a priority marker), any case, every copy.
        #expect(TaskLineParser.removingTag("work", from: "Ship #work it  today") == "Ship it  today")
        #expect(TaskLineParser.removingTag("work", from: "!! #Work Ship it #work") == "!! Ship it")
        // A longer tag with the same prefix, inline code and C# stay.
        #expect(TaskLineParser.removingTag("work", from: "Email #work/hpc about `#work` in C# #work") == "Email #work/hpc about `#work` in C#")
        #expect(TaskLineParser.removingTag("home", from: "Fix #bau") == "Fix #bau")
    }

    @Test func addsTheFilterTagOnce() {
        // A task typed into the Tasks tab while it is filtered by #mgmt.
        #expect(TaskLineParser.addingTag("mgmt", to: "!! Slides for Wed ") == "!! Slides for Wed #mgmt")
        #expect(TaskLineParser.addingTag("mgmt", to: "Slides #MGMT for Wed") == "Slides #MGMT for Wed")
        #expect(TaskLineParser.addingTag("mgmt", to: "Slides #mgmt/board") == "Slides #mgmt/board #mgmt")
        #expect(TaskLineParser.addingTag("#mgmt", to: "Call `#mgmt`") == "Call `#mgmt` #mgmt")
    }

    @Test func escapedHashIsNotATag() {
        // Scribe transcripts escape recognised text; `\#budget` must not become a tag.
        #expect(TaskLineParser.tags(in: ##"\#budget is \#5 but #scribe/book-notes is"##) == ["scribe/book-notes"])
    }

    @Test func firstMatchingLineFindsWordsAndTags() {
        let text = "# Title\n\nnothing\nthe Budget line\n#work here\n"
        #expect(SearchQuery("budget").firstMatchingLine(in: text) == 3)
        #expect(SearchQuery("#work ").firstMatchingLine(in: text) == 4)
        #expect(SearchQuery("absent").firstMatchingLine(in: text) == nil)
    }

    @Test func replacesStatusByteExact() {
        #expect(TaskLineParser.replacingStatus(in: "\t- [ ]  Two  spaces #a", with: .today) == "\t- [/]  Two  spaces #a")
        #expect(TaskLineParser.replacingStatus(in: "- [/] Park it", with: .someday) == "- [>] Park it")
    }

    @Test func contentKeyIgnoresWhitespaceAndCase() {
        #expect(TaskItem.contentKey(for: "Buy  Milk") == TaskItem.contentKey(for: "buy milk"))
        #expect(TaskItem.contentKey(for: "Buy milk") != TaskItem.contentKey(for: "Buy eggs"))
    }
}

@Suite struct TaskPriorityTests {
    @Test func parsesMarkerAtTheStart() {
        #expect(TaskLineParser.priority(in: "!!! Fix the server #work") == .high)
        #expect(TaskLineParser.priority(in: "!! Medium one") == .medium)
        #expect(TaskLineParser.priority(in: "! Low one") == .low)
        #expect(TaskLineParser.priority(in: "Plain task") == .none)
        #expect(TaskLineParser.priority(in: "Wow! not a marker") == .none)
        #expect(TaskLineParser.priority(in: "!!!!") == .none)      // four bangs are just text
        #expect(TaskLineParser.priority(in: "!!") == .medium)      // a bare marker still counts
        #expect(TaskLineParser.priority(in: "!Log into the switches") == .low)   // no space needed
        #expect(TaskLineParser.priority(in: "!!!Fix it") == .high)
        #expect(TaskLineParser.priority(in: "!#bau Update docs") == .low)
        #expect(TaskLineParser.stripPriority(from: "!!Call Bob #work") == "Call Bob #work")
        #expect(TaskLineParser.settingPriority(.high, in: "!Call Bob") == "!!! Call Bob")
        #expect(TaskLineParser.priorityRange(in: "!! Medium one") == NSRange(location: 0, length: 2))
    }

    @Test func stripsAndSetsMarkers() {
        #expect(TaskLineParser.stripPriority(from: "!!! Fix the server #work") == "Fix the server #work")
        #expect(TaskLineParser.stripPriority(from: "Fix the server") == "Fix the server")
        #expect(TaskLineParser.settingPriority(.high, in: "Fix it #a") == "!!! Fix it #a")
        #expect(TaskLineParser.settingPriority(.low, in: "!!! Fix it #a") == "! Fix it #a")
        #expect(TaskLineParser.settingPriority(.none, in: "!! Fix it") == "Fix it")
    }

    @Test func priorityIsMetadataNotIdentity() {
        let plain = TaskItem(providerID: "daily", title: "Fix it #a", status: .notStarted, tags: ["a"], indent: 0,
                             source: TaskSource(path: "x.md", line: 0))
        let high = TaskItem(providerID: "daily", title: "!!! Fix it #a", status: .notStarted, tags: ["a"], indent: 0,
                            source: TaskSource(path: "x.md", line: 0))
        #expect(plain.contentKey == high.contentKey)
        #expect(high.priority == .high && plain.priority == .none)
        #expect(high.displayTitle == "Fix it")
        // The task line parser keeps the marker in the title so the file round-trips byte for byte.
        #expect(TaskLineParser.parse("- [ ] !! Buy milk")?.title == "!! Buy milk")
    }
}
