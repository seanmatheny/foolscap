import Testing
import Foundation
@testable import FoolscapCore

@Suite struct TaskLineParserTests {
    @Test func parsesThreeStatuses() {
        #expect(TaskLineParser.parse("- [ ] Buy milk")?.status == .notStarted)
        #expect(TaskLineParser.parse("  * [/] Write plan")?.status == .inProgress)
        #expect(TaskLineParser.parse("1. [x] Done")?.status == .completed)
        #expect(TaskLineParser.parse("- [X] Done")?.status == .completed)
    }

    @Test func rejectsNonTasks() {
        #expect(TaskLineParser.parse("- Buy milk") == nil)
        #expect(TaskLineParser.parse("[ ] no bullet") == nil)
        #expect(TaskLineParser.parse("- [ ]") == nil)
        #expect(TaskLineParser.parse("- [?] weird") == nil)
    }

    @Test func extractsTags() {
        let p = TaskLineParser.parse("- [ ] Email Dave about #work/hpc and `#notatag` C#")!
        #expect(p.tags == ["work/hpc"])
        #expect(TaskLineParser.stripTags(from: p.title) == "Email Dave about and `#notatag` C#")
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
        #expect(TaskLineParser.replacingStatus(in: "\t- [ ]  Two  spaces #a", with: .inProgress) == "\t- [/]  Two  spaces #a")
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
