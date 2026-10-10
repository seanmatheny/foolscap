import Testing
import Foundation
import FoolscapCore
@testable import FoolscapScribe

@Suite struct ScribePageDatesTests {
    let modified = DayKey("2026-10-08")!.date

    func page(_ lines: String...) -> [[TextLine]] {
        [lines.enumerated().map { TextLine($1, x: 0.05, y: 0.1 + 0.045 * Double($0), w: 0.3, h: 0.04) }]
    }

    func day(_ first: String, notAfter: Date? = nil) -> String? {
        ScribePageDates.date(forPage: page(first, "second line", "third line"), notAfter: notAfter ?? modified)?.string
    }

    @Test func readsTheFormatsSeanWrites() {
        #expect(day("July 24th") == "2026-07-24")
        #expect(day("Wednesday October 20") == "2025-10-20")   // after the notebook's last change: the year before
        #expect(day("24/May/2026") == "2026-05-24")
        #expect(day("eRGG - 17/6/26") == "2026-06-17")
        #expect(day("22-09-25") == "2025-09-22")
        #expect(day("Del AI Day 22/7/26") == "2026-07-22")
        #expect(day("24-09-26 Thursday") == "2026-09-24")
        #expect(day("2026-07-24") == "2026-07-24")
        #expect(day("22 Sept") == "2026-09-22")
        #expect(day("Sept 3, 2026") == "2026-09-03")
        #expect(day("Meeting 1/l0/26") == "2026-10-01")   // OCR's l for 1, 0 read as o
    }

    @Test func numericDatesAreDayFirstAndNeverSwapped() {
        #expect(day("7/24/26") == nil)
        #expect(day("31/4/26") == nil)
        #expect(day("3/4/26") == "2026-04-03")
    }

    @Test func missingYearNeverLandsAfterTheNotebookChanged() {
        #expect(day("December 30", notAfter: DayKey("2027-01-05")!.date) == "2026-12-30")
        #expect(day("January 2", notAfter: DayKey("2027-01-05")!.date) == "2027-01-02")
    }

    @Test func onlyTheTopOfThePageIsADateLine() {
        let late = [[TextLine("notes", x: 0, y: 0, w: 0.3, h: 0.04), TextLine("more", x: 0, y: 0.05, w: 0.3, h: 0.04),
                     TextLine("again", x: 0, y: 0.1, w: 0.3, h: 0.04), TextLine("17/6/26", x: 0, y: 0.15, w: 0.3, h: 0.04)]]
        #expect(ScribePageDates.date(forPage: late, notAfter: modified) == nil)
        #expect(day("no date here") == nil)
        #expect(day("call at 10:30") == nil)
        #expect(day("3-5 people") == nil)
    }

    @Test func undatedPagesContinueThePreviousDay() {
        let pages = [page("plans"), page("July 24th", "Cameron & Chris"), page("- more from the meeting"), page("17/6/26 eRGG"), []]
        #expect(ScribePageDates.resolve(pages: pages, modified: modified).map { $0?.string } == [nil, "2026-07-24", "2026-07-24", "2026-06-17", "2026-06-17"])
    }
}
