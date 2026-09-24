import Testing
import Foundation
@testable import FoolscapCore

@Suite struct TagCompletionTests {
    @Test func findsThePartialAtTheCaret() {
        #expect(TagCompletion.partial(in: "Call Bob #wo") == TagCompletion.Partial(range: NSRange(location: 9, length: 3), text: "wo"))
        #expect(TagCompletion.partial(in: "#Work/hp")?.text == "work/hp")
        #expect(TagCompletion.partial(in: "Call Bob #") == TagCompletion.Partial(range: NSRange(location: 9, length: 1), text: ""))
        #expect(TagCompletion.partial(in: "Call Bob #wo now") == nil)                 // caret past the tag
        #expect(TagCompletion.partial(in: "Call Bob #wo now", caret: 12)?.text == "wo") // caret right after it
        #expect(TagCompletion.partial(in: "C#") == nil)                               // glued to a word
        #expect(TagCompletion.partial(in: "## He") == nil)                            // heading hashes
        #expect(TagCompletion.partial(in: "`#code") == nil)
        #expect(TagCompletion.partial(in: "\\#esc") == nil)
        #expect(TagCompletion.partial(in: "#-x") == nil)                              // must start like a tag
        #expect(TagCompletion.partial(in: "") == nil)
    }

    @Test func matchesByPrefixAndCompletes() {
        let tags = ["work", "work/hpc", "home", "wo"]
        #expect(TagCompletion.matches(for: "wo", in: tags) == ["work", "work/hpc"])   // the exact "wo" is already complete
        #expect(TagCompletion.matches(for: "WO", in: tags) == ["work", "work/hpc"])
        #expect(TagCompletion.matches(for: "", in: tags) == tags)
        #expect(TagCompletion.matches(for: "zz", in: tags).isEmpty)
        #expect(TagCompletion.matches(for: "", in: ["a", "a", "b"]) == ["a", "b"])
        let partial = TagCompletion.partial(in: "Call Bob #wo")!
        #expect(TagCompletion.completing("Call Bob #wo", partial: partial, with: "work") == "Call Bob #work ")
    }
}
