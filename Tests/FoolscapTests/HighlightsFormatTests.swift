import Testing
import Foundation
@testable import FoolscapCore

@Suite struct HighlightsFormatTests {
    static let day = HighlightMarkdown.dateFormatter.date(from: "12 Mar 2026")!

    func book(_ blocks: [(paragraphs: [String], note: String?, meta: HighlightMeta)]) -> String {
        var text = HighlightMarkdown.renderHeader(title: "The Rise and Fall", author: "William L. Shirer")
        for b in blocks { text += "\n" + HighlightMarkdown.renderBlock(paragraphs: b.paragraphs, note: b.note, meta: b.meta) + "\n" }
        return text
    }

    @Test func renderAndParseRoundTrip() {
        let meta = HighlightMeta(position: 492355, added: Self.day, tags: ["history", "war"], isFavourite: true, isHidden: false)
        let text = book([(["First paragraph.", "Second paragraph."], "my note", meta),
                         ([ "Plain one." ], nil, HighlightMeta(position: 500000, isHidden: true))])
        #expect(text == """
            # The Rise and Fall
            William L. Shirer
            #kindle

            > First paragraph.
            > Second paragraph.
            > *Note:* my note
            > — pos 492355 · 12 Mar 2026 · #history #war ♥

            > Plain one.
            > — pos 500000 · hidden

            """)
        let parsed = HighlightParser.parse(text, path: "Highlights/The Rise and Fall.md")
        #expect(parsed.title == "The Rise and Fall")
        #expect(parsed.author == "William L. Shirer")
        #expect(parsed.items.count == 2)
        let first = parsed.items[0]
        #expect(first.id == "Highlights/The Rise and Fall.md#L4")
        #expect(first.line == 4 && first.metaLine == 7)
        #expect(first.paragraphs == ["First paragraph.", "Second paragraph."])
        #expect(first.note == "my note")
        #expect(first.meta == meta)
        #expect(first.bookTitle == "The Rise and Fall" && first.bookAuthor == "William L. Shirer")
        let second = parsed.items[1]
        #expect(second.meta == HighlightMeta(position: 500000, isHidden: true))
        #expect(second.note == nil)
        #expect(second.text == "Plain one.")
    }

    @Test func escapingKeepsQuoteTextLiteral() {
        let quote = "#1 with #tag, — a leading dash, and *Note:* stars, back\\slash"
        let dashy = "— Winston Churchill"
        let starry = "*Note:* not a note"
        let text = book([([quote], nil, HighlightMeta(position: 1)), ([dashy, starry, "> nested?"], nil, HighlightMeta(position: 2))])
        #expect(text.contains("> \\#1 with \\#tag, — a leading dash"))
        #expect(text.contains("> \\— Winston Churchill"))
        #expect(text.contains("> \\*Note:* not a note"))
        #expect(text.contains("> \\> nested?"))
        let parsed = HighlightParser.parse(text, path: "Highlights/x.md")
        #expect(parsed.items.map(\.paragraphs) == [[quote], [dashy, starry, "> nested?"]])
        #expect(parsed.items[1].note == nil)
        // The note parser sees no tasks and only the header and meta tags.
        let note = NoteParser.parse(text, path: "Highlights/x.md", day: nil)
        #expect(note.tasks.isEmpty)
        #expect(note.tags == ["kindle"])
        let tagged = book([(["Quote"], nil, HighlightMeta(position: 1, tags: ["stoic"]))])
        #expect(NoteParser.parse(tagged, path: "Highlights/x.md", day: nil).tags.sorted() == ["kindle", "stoic"])
        #expect(NoteParser.parse(tagged, path: "Highlights/x.md", day: nil).title == "The Rise and Fall")
    }

    @Test func contentKeyIgnoresMeta() {
        let a = HighlightItem(path: "p", line: 0, metaLine: 1, bookTitle: "", bookAuthor: "", paragraphs: ["Hello  world"], note: nil,
                              meta: HighlightMeta(position: 1))
        let b = HighlightItem(path: "p", line: 9, metaLine: 10, bookTitle: "", bookAuthor: "", paragraphs: ["hello world"], note: "n",
                              meta: HighlightMeta(position: 2, added: Self.day, tags: ["x"], isFavourite: true, isHidden: true))
        #expect(a.contentKey == b.contentKey)
        #expect(a.contentKey != HighlightItem.contentKey(for: ["Hello there"]))
        #expect(a.contentKey.count == 16)
    }

    @Test func metaParsingIsTolerant() {
        #expect(HighlightParser.parseMeta("— pos 42") == HighlightMeta(position: 42))
        #expect(HighlightParser.parseMeta("—  pos 42 · #a #b") == HighlightMeta(position: 42, tags: ["a", "b"]))
        #expect(HighlightParser.parseMeta("— pos 42 · 12 Mar 2026 #A ♥") == HighlightMeta(position: 42, added: Self.day, tags: ["a"], isFavourite: true))
        #expect(HighlightParser.parseMeta("— pos 42 · 12 Mar 2026 · hidden · mystery token") == HighlightMeta(position: 42, added: Self.day, isHidden: true))
        #expect(HighlightParser.parseMeta("— 12 Mar 2026") == nil)
        #expect(HighlightParser.parseMeta("pos 42") == nil)
        // CRLF, `>` without a space and blank quote lines.
        let text = "# T\r\n#kindle\r\n\r\n>Quote\r\n>\r\n> — pos 7\r\n"
        let parsed = HighlightParser.parse(text, path: "p")
        #expect(parsed.items.count == 1)
        #expect(parsed.items[0].paragraphs == ["Quote"])
        #expect(parsed.items[0].meta.position == 7)
        // A block without a meta line is reported but yields no item.
        let plain = "# T\n\n> Just a quote\n\n> Real\n> — pos 3\n"
        let p2 = HighlightParser.parse(plain, path: "p")
        #expect(p2.blocks.count == 2 && p2.blocks[0].item == nil && p2.items.count == 1)
        #expect(p2.firstBlockLine == 2)
    }

    @Test func insertingOrdersReplacesAndAppends() {
        let start = book([(["Second"], nil, HighlightMeta(position: 200, tags: ["keep"], isFavourite: true)),
                          (["Fourth"], nil, HighlightMeta(position: 400))])
        let out = HighlightMarkdown.inserting([
            .init(paragraphs: ["Fifth"], meta: HighlightMeta(position: 500)),
            .init(paragraphs: ["First"], meta: HighlightMeta(position: 100)),
            .init(paragraphs: ["Third"], note: "n", meta: HighlightMeta(position: 300)),
        ], into: start, path: "p")
        let parsed = HighlightParser.parse(out, path: "p")
        #expect(parsed.items.map(\.text) == ["First", "Second", "Third", "Fourth", "Fifth"])
        #expect(parsed.items.map(\.meta.position) == [100, 200, 300, 400, 500])
        #expect(parsed.items[2].note == "n")
        #expect(out.hasSuffix("> — pos 500\n"))
        #expect(!out.contains("\n\n\n"))

        // Replacing by key rewrites the text and keeps the user's flags.
        let key = HighlightItem.contentKey(for: ["Second"])
        let replaced = HighlightMarkdown.inserting([.init(paragraphs: ["Second, extended"], meta: HighlightMeta(position: 199), replacingKey: key)],
                                                   into: out, path: "p")
        let p2 = HighlightParser.parse(replaced, path: "p")
        #expect(p2.items.map(\.text) == ["First", "Second, extended", "Third", "Fourth", "Fifth"])
        #expect(p2.items[1].meta == HighlightMeta(position: 199, tags: ["keep"], isFavourite: true))
        // A key that is gone appends a fresh block instead.
        let again = HighlightMarkdown.inserting([.init(paragraphs: ["Sixth"], meta: HighlightMeta(position: 600), replacingKey: "nope")], into: replaced, path: "p")
        #expect(HighlightParser.parse(again, path: "p").items.map(\.text).last == "Sixth")
        // Into a header-only file.
        let fresh = HighlightMarkdown.inserting([.init(paragraphs: ["Only"], meta: HighlightMeta(position: 1))],
                                                into: HighlightMarkdown.renderHeader(title: "T", author: ""), path: "p")
        #expect(fresh == "# T\n#kindle\n\n> Only\n> — pos 1\n")
        #expect(HighlightMarkdown.inserting([], into: fresh, path: "p") == fresh)
    }
}
