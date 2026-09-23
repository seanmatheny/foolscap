import Testing
import Foundation
@testable import FoolscapScribe

// Ported from tests/test_notes_sync.py in KindleScribeSync-mac.

func fragment(_ text: String, _ x: Double, _ y: Double, w: Double = 0.3, h: Double = 0.04, alternates: [String] = []) -> OCRObservation {
    OCRObservation(text: text, alternates: alternates, confidence: 1, x: x, y: y, w: w, h: h)
}

/// A page holding one paragraph of short, left-aligned lines.
func pageOf(_ texts: String...) -> [[TextLine]] {
    [texts.enumerated().map { TextLine($1, x: 0.05, y: 0.1 + 0.045 * Double($0), w: 0.3, h: 0.04) }]
}

func tasksIn(_ texts: String...) -> [String] {
    let page = [texts.enumerated().map { TextLine($1, x: 0.05, y: 0.1 + 0.045 * Double($0), w: 0.3, h: 0.04) }]
    return ScribeTodos.extractTodos([page]).map(\.text)
}

@Suite struct ScribeLayoutTests {
    @Test func fragmentsOnOneRowAreJoinedLeftToRight() {
        let page = ScribeLayout.layoutPage([fragment("the car", 0.45, 0.101), fragment("TODO: Wash", 0.05, 0.10)])
        #expect(page.map { $0.map(\.text) } == [["TODO: Wash the car"]])
    }

    @Test func textSqueezedInAboveALineStaysSeparate() {
        let page = ScribeLayout.layoutPage([fragment("colleagues in Mayo", 0.05, 0.50, w: 0.6), fragment("Edinburgh", 0.40, 0.485, w: 0.2)])
        #expect(page.flatMap { $0.map(\.text) }.sorted() == ["Edinburgh", "colleagues in Mayo"])
    }

    @Test func aSkippedRuleStartsANewParagraph() {
        let rows = [0.10, 0.145, 0.19, 0.28, 0.325]
        let page = ScribeLayout.layoutPage(rows.enumerated().map { fragment("line \($0)", 0.05, $1) })
        #expect(page.map(\.count) == [3, 2])
    }

    @Test func rowsComeOutTopToBottomWhateverOrderVisionUsed() {
        let page = ScribeLayout.layoutPage([fragment("second", 0.05, 0.145), fragment("first", 0.05, 0.10)])
        #expect(page[0].map(\.text) == ["first", "second"])
    }

    @Test func emptyPage() {
        #expect(ScribeLayout.layoutPage([]).isEmpty)
    }

    @Test func alternateReadingRescuesAMisreadTodo() {
        let misread = fragment("TODD: Thank Claude", 0.05, 0.1, alternates: ["TODD: Thank Claud", "TODO: Thank Claude", "TODO: Thank Claud"])
        let page = ScribeLayout.layoutPage([misread])
        #expect(page[0][0].text == "TODO: Thank Claude")
        #expect(ScribeTodos.extractTodos([page]) == [Todo("Thank Claude", page: 1)])
    }

    @Test func firstReadingWinsOtherwise() throws {
        let todd = fragment("TODD: will handle the budget", 0.05, 0.1, alternates: ["TODD: will handle the budge"])
        #expect(ScribeLayout.layoutPage([todd])[0][0].text == "TODD: will handle the budget")
        let already = fragment("TODO: Wash the car", 0.05, 0.1, alternates: ["TODO: Wash he car"])
        #expect(ScribeLayout.layoutPage([already])[0][0].text == "TODO: Wash the car")
        let plain = try JSONDecoder().decode(OCRObservation.self, from: Data(#"{"text": "no alternates key", "x": 0.05, "y": 0.1, "w": 0.3, "h": 0.04}"#.utf8))
        #expect(ScribeLayout.layoutPage([plain])[0][0].text == "no alternates key")
    }

    @Test func medianAveragesTheMiddlePair() {
        #expect(ScribeLayout.median([3, 1, 2]) == 2)
        #expect(ScribeLayout.median([4, 1, 3, 2]) == 2.5)
    }
}

@Suite struct ScribeTodoTests {
    @Test func theSampleNotebook() {
        #expect(tasksIn("TODO: Wash the car") == ["Wash the car"])
    }

    @Test func markerVariantsTheRecogniserProduces() {
        for line in ["- TODO: call Bob", "T0DO; call Bob", "TODO - call Bob", "To do: call Bob", "todo: call Bob", "• TOD0: call Bob"] {
            #expect(tasksIn(line) == ["call Bob"], "\(line)")
        }
    }

    @Test func markerInTheMiddleOfALine() {
        #expect(tasksIn("Budget meeting. TODO: send slides") == ["send slides"])
    }

    @Test func linesThatAreNotTasks() {
        for line in ["TODO list for the garden", "TODOs: many", "things to do: relax", "nothing to do with it", "TODO wash the car"] {
            #expect(tasksIn(line) == [], "\(line)")
        }
    }

    @Test func taskNeedsSomeText() {
        #expect(tasksIn("TODO: -") == [])
    }

    @Test func bareHeadingTakesTheBulletsUnderIt() {
        #expect(tasksIn("TODO:", "- wash car", "- buy milk", "Meeting notes") == ["wash car", "buy milk"])
    }

    @Test func bareHeadingWithoutBulletsTakesOneLine() {
        #expect(tasksIn("TODO", "wash car", "unrelated note") == ["wash car"])
    }

    @Test func bareHeadingStopsAtTheParagraph() {
        let pages = [[[TextLine("TODO:", x: 0.05, y: 0.1, w: 0.1, h: 0.04)], [TextLine("- unrelated", x: 0.05, y: 0.3, w: 0.3, h: 0.04)]]]
        #expect(ScribeTodos.extractTodos(pages) == [])
    }

    @Test func lineReachingTheMarginWrapsOntoTheNext() {
        let paragraph = [TextLine("TODO: email Bob about the", x: 0.05, y: 0.10, w: 0.85, h: 0.04), TextLine("budget numbers", x: 0.05, y: 0.145, w: 0.3, h: 0.04)]
        #expect(ScribeTodos.extractTodos([[paragraph]]) == [Todo("email Bob about the budget numbers", page: 1)])
    }

    @Test func shortLineDoesNotSwallowTheNext() {
        #expect(tasksIn("TODO: email Bob", "budget numbers") == ["email Bob"])
    }

    @Test func wrapDoesNotSwallowABulletOrAnotherTodo() {
        for following in ["- next point", "TODO: second"] {
            let paragraph = [TextLine("TODO: first", x: 0.05, y: 0.10, w: 0.85, h: 0.04), TextLine(following, x: 0.05, y: 0.145, w: 0.85, h: 0.04)]
            #expect(ScribeTodos.extractTodos([[paragraph]])[0].text == "first", "\(following)")
        }
    }

    @Test func pageNumbers() {
        let pages = [pageOf("nothing here"), pageOf("TODO: on page two")]
        #expect(ScribeTodos.extractTodos(pages) == [Todo("on page two", page: 2)])
    }

    @Test func keysAndRatios() {
        #expect(ScribeTodos.todoKey("Wash the car!") == "wash the car")
        #expect(ScribeTodos.todoKey("  Wash-the CAR  ") == "wash the car")
        // difflib: 2·17/36
        #expect(abs(SequenceMatcher.ratio("wash the car today", "wash the cor today") - 34.0 / 36.0) < 1e-9)
        #expect(SequenceMatcher.ratio("book flight 1", "book flight 2") >= sameTodoRatio)
        #expect(SequenceMatcher.ratio("abc", "xyz") == 0)
        #expect(SequenceMatcher.ratio("", "") == 1)
        #expect(abs(SequenceMatcher.ratio("abcd", "bcda") - 0.75) < 1e-9)
    }
}
