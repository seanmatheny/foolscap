import Testing
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
