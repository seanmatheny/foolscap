import Testing
import Foundation
@testable import FoolscapScribe

@Suite struct ScribeTranscriptTests {
    let notebook = ScribeNotebookRef(id: "724f0e7f-ebdd", name: "todo", path: "Work/todo")

    func render(_ pages: [[[TextLine]]]) -> String {
        ScribeTranscript.render(notebook: notebook, title: "todo", pages: pages, modified: Date(timeIntervalSince1970: 0))
    }

    @Test func recognisedTextCannotCreateTagsOrHeadings() {
        #expect(ScribeTranscript.escapeMarkdown("#budget is *big*") == ##"\#budget is \*big\*"##)
        #expect(ScribeTranscript.escapeMarkdown("# Chris") == ##"\# Chris"##)
        #expect(ScribeTranscript.escapeMarkdown("---") == #"\---"#)
        #expect(ScribeTranscript.escapeMarkdown("> quoted") == #"\> quoted"#)
        #expect(ScribeTranscript.escapeMarkdown("- a bullet stays a bullet") == "- a bullet stays a bullet")
        #expect(ScribeTranscript.escapeMarkdown("a ~~b~~ ==c==") == #"a \~\~b\~\~ \=\=c\=\="#)
        for s in ["#budget is *big*", "# Chris", "---", "> quoted", "back\\slash", "a ~~b~~ ==c=="] {
            #expect(ScribeTranscript.unescapeMarkdown(ScribeTranscript.escapeMarkdown(s)) == s)
        }
    }

    @Test func noteLayout() {
        let note = render([pageOf("TODO: Wash the car"), []])
        #expect(note.hasPrefix("# todo\n#scribe/work\n\n## Page 1\n\n**TODO:** Wash the car\n"))
        #expect(note.contains("## Page 2\n\n*No handwriting recognised on this page.*"))
        #expect(note.contains("Sync ID 724f0e7f-ebdd"))
        #expect(note.contains("(2 pages, last changed "))
        #expect(note.hasSuffix("*Sync ID 724f0e7f-ebdd*\n"))
    }

    @Test func bulletBeforeTheMarkerSurvives() {
        #expect(ScribeTranscript.renderLine("- T0DO; call Bob") == "- **TODO:** call Bob")
    }

    @Test func renderingIsDeterministic() {
        #expect(render([pageOf("x")]) == render([pageOf("x")]))
    }

    @Test func tagsFollowTheFolders() {
        #expect(ScribeTranscript.noteTag(forPath: "Personal/book notes/Notebook 1") == "scribe/personal/book-notes")
        #expect(ScribeTranscript.noteTag(forPath: "Loose") == "scribe")
    }

    @Test func titlesFallBackToThePathWhenNamesCollide() {
        let notebooks = [
            ScribeNotebookRef(id: "a", name: "Notebook 1", path: "Work/Notebook 1"),
            ScribeNotebookRef(id: "b", name: "Notebook 1", path: "Personal/Notebook 1"),
            ScribeNotebookRef(id: "c", name: "todo", path: "Work/todo"),
        ]
        #expect(ScribeTranscript.noteTitles(notebooks) == ["a": "Work / Notebook 1", "b": "Personal / Notebook 1", "c": "todo"])
    }

    @Test func sanitisesNames() {
        #expect(ScribeTranscript.sanitizeName(#"a/b:c*d?e"f<g>h|i "#) == "a_b_c_d_e_f_g_h_i")
        #expect(ScribeTranscript.sanitizeName("  ") == "untitled")
    }

    @Test func parseRoundTripsTheRenderedNote() {
        let pages: [[[TextLine]]] = [
            [[TextLine("Budget meeting #q3", x: 0.05, y: 0.1, w: 0.3, h: 0.04), TextLine("- TODO: send *slides*", x: 0.05, y: 0.145, w: 0.3, h: 0.04)],
             [TextLine("second paragraph", x: 0.05, y: 0.3, w: 0.3, h: 0.04)]],
            [],
        ]
        let text = render(pages)
        let parsed = ScribeTranscript.parse(text)
        #expect(parsed.title == "todo")
        #expect(parsed.syncID == "724f0e7f-ebdd")
        #expect(parsed.pages.map(\.number) == [1, 2])
        #expect(parsed.pages[0].paragraphs == [
            [ScribeTranscript.Line(before: "Budget meeting #q3", task: nil), ScribeTranscript.Line(before: "- ", task: "send *slides*")],
            [ScribeTranscript.Line(before: "second paragraph", task: nil)],
        ])
        #expect(parsed.pages[1].isEmpty)
        #expect(parsed.plainText == "Page 1\n\nBudget meeting #q3\n- TODO: send *slides*\n\nsecond paragraph\n\nPage 2")
        // Lines map back to pages for search hits.
        let lines = text.components(separatedBy: "\n")
        let secondHeading = lines.firstIndex(of: "## Page 2")!
        #expect(ScribeTranscript.pageNumber(forLine: secondHeading - 1, in: parsed) == 1)
        #expect(ScribeTranscript.pageNumber(forLine: secondHeading + 1, in: parsed) == 2)
        #expect(ScribeTranscript.pageNumber(forLine: 0, in: parsed) == nil)
    }
}
