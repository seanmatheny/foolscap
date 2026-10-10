import Foundation
import FoolscapCore

/// The day a handwritten page belongs to, read from the date Sean writes at the top
/// of a page ("July 24th", "Wednesday October 20", "24/May/2026", "17/6/26",
/// "22-09-25", "Del AI Day 22/7/26"). Numeric dates are day-first. A page with no
/// date of its own continues the previous page's day; a page before any dated page
/// has none. Nothing else (Amazon's stamps, sync times) is consulted: the handwritten
/// date is the one signal Sean controls.
public enum ScribePageDates {
    /// Goes into the transcript key: changing the rules rewrites every transcript.
    public static let rulesVersion = "page-dates/1"
    /// Only the top of a page is a date line.
    static let scannedLines = 3

    struct Partial: Equatable {
        var day: Int
        var month: Int
        var year: Int?
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let monthPattern = "(" + months.joined(separator: "|") + ")[a-z]*\\.?"

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// 2026-07-24
    private static let iso = regex(#"\b(20\d{2})-(\d{2})-(\d{2})\b"#)
    /// 17/6/26, 22-09-25, 22/7/2026 (day first); O/o and l/I stand in for digits OCR misread.
    private static let numeric = regex(#"(?<![\d/\-.])([\dOoIl]{1,2})[/\-.]([\dOoIl]{1,2})[/\-.](\d{4}|\d{2})(?![\d/\-.])"#)
    /// 24 May 2026, 24/May/2026, 22nd Sept, 24-May
    private static let dayFirst = regex(#"\b(\d{1,2})(?:st|nd|rd|th)?[ /\-.,]+"# + monthPattern + #"(?:[ ,/\-.]+(\d{4}|\d{2}))?\b"#)
    /// July 24th, Wednesday October 20, Sept 3, 2026
    private static let monthFirst = regex(#"\b"# + monthPattern + #"\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4}|\d{2}))?"#)

    private static func int(_ text: Substring) -> Int? {
        Int(text.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "o", with: "0")
                .replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "l", with: "1"))
    }

    private static func year(_ text: Substring?) -> Int? {
        guard let text, let value = Int(text) else { return nil }
        return text.count == 2 ? 2000 + value : value
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in line: String) -> Substring? {
        guard index < match.numberOfRanges, let range = Range(match.range(at: index), in: line) else { return nil }
        return line[range]
    }

    /// The first date on a line, as written (the year may be missing).
    static func partial(in line: String) -> Partial? {
        let range = NSRange(line.startIndex..., in: line)
        if let m = iso.firstMatch(in: line, range: range),
           let y = int(group(m, 1, in: line)!), let mo = int(group(m, 2, in: line)!), let d = int(group(m, 3, in: line)!) {
            return Partial(day: d, month: mo, year: y)
        }
        if let m = numeric.firstMatch(in: line, range: range),
           let d = int(group(m, 1, in: line)!), let mo = int(group(m, 2, in: line)!) {
            return Partial(day: d, month: mo, year: year(group(m, 3, in: line)))
        }
        if let m = dayFirst.firstMatch(in: line, range: range),
           let d = int(group(m, 1, in: line)!), let name = group(m, 2, in: line),
           let mo = months.firstIndex(of: name.lowercased()) {
            return Partial(day: d, month: mo + 1, year: year(group(m, 3, in: line)))
        }
        if let m = monthFirst.firstMatch(in: line, range: range),
           let name = group(m, 1, in: line), let mo = months.firstIndex(of: name.lowercased()),
           let d = int(group(m, 2, in: line)!) {
            return Partial(day: d, month: mo + 1, year: year(group(m, 3, in: line)))
        }
        return nil
    }

    /// A real calendar day, or nil ("7/24/26" is not swapped into a US date).
    static func day(_ partial: Partial, year: Int, calendar: Calendar) -> DayKey? {
        guard (1...31).contains(partial.day), (1...12).contains(partial.month), (2000...2099).contains(year) else { return nil }
        var components = DateComponents()
        components.year = year; components.month = partial.month; components.day = partial.day; components.hour = 12
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == partial.day else { return nil }
        return DayKey(date, calendar: calendar)
    }

    /// The day written at the top of a page. A date with no year gets the most recent
    /// year that keeps it on or before `notAfter` (the notebook's last change), so a
    /// December page in a notebook changed in January lands in the previous year.
    public static func date(forPage paragraphs: [[TextLine]], notAfter: Date, calendar: Calendar = .current) -> DayKey? {
        let lines = paragraphs.flatMap { $0 }.prefix(scannedLines)
        let limit = DayKey(notAfter, calendar: calendar)
        for line in lines {
            guard let partial = partial(in: line.text) else { continue }
            if let year = partial.year { return day(partial, year: year, calendar: calendar) }
            let latest = calendar.component(.year, from: notAfter)
            for year in (latest - 2...latest).reversed() {
                if let found = day(partial, year: year, calendar: calendar), found <= limit { return found }
            }
            return nil
        }
        return nil
    }

    /// One day per page: its own date, else the previous page's, else none.
    public static func resolve(pages: [[[TextLine]]], modified: Date, calendar: Calendar = .current) -> [DayKey?] {
        var current: DayKey?
        return pages.map { paragraphs in
            if let own = date(forPage: paragraphs, notAfter: modified, calendar: calendar) { current = own }
            return current
        }
    }
}
