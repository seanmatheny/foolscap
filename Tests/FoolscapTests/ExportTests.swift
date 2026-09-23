import Testing
@testable import FoolscapCore

@Suite struct ExportTests {
    @Test func htmlCoversTasksTagsAndCode() {
        let md = "# Day\n\n- [ ] Todo #work\n- [/] Doing\n- [x] Done\n\n```swift\nlet x = 1\n```\n\nhttps://example.com\n"
        let html = MarkdownExporter.html(fromMarkdown: md, title: "Day")
        #expect(html.contains("<h1>Day</h1>"))
        #expect(html.contains("<li class=\"task todo\">☐ <p>Todo <span class=\"tag\">#work</span></p>"))
        #expect(html.contains("<li class=\"task doing\">◐ <p>Doing</p>"))
        #expect(html.contains("<li class=\"task done\">☑ <p>Done</p>"))
        #expect(html.contains("<pre><code class=\"language-swift\">let x = 1"))
        #expect(html.contains("<a href=\"https://example.com\">https://example.com</a>"))
    }
}
