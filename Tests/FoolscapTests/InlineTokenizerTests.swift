import Testing
import Foundation
@testable import FoolscapCore

@Suite struct InlineTokenizerTests {
    private func kinds(_ s: String) -> [InlineToken.Kind] { InlineTokenizer.tokenize(s).map(\.kind) }

    @Test func basicSpans() {
        #expect(kinds("a **bold** and *it* and `code` ~~gone~~") == [.bold, .italic, .code, .strikethrough])
        #expect(kinds("***both***") == [.boldItalic])
        #expect(kinds("snake_case_word is not italic") == [])
        #expect(kinds("2 * 3 * 4") == [])
    }

    @Test func codeWins() {
        let t = InlineTokenizer.tokenize("`**not bold** #notag` **bold**")
        #expect(t.map(\.kind) == [.code, .bold])
    }

    @Test func linksTagsUrls() {
        let t = InlineTokenizer.tokenize("see [docs](https://x.y/z) or https://a.b/c #work/hpc C#")
        #expect(t.map(\.kind) == [.link(url: "https://x.y/z"), .url("https://a.b/c"), .tag("work/hpc")])
        let link = t[0]
        #expect((("see [docs](https://x.y/z) or https://a.b/c #work/hpc C#" as NSString).substring(with: link.content)) == "docs")
        #expect(link.syntax.count == 2)
    }

    @Test func imageIsNotALink() {
        #expect(kinds("![alt](a.png)") == [])
    }
}
