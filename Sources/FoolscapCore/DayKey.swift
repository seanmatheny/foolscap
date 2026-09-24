import Foundation

/// A calendar day as `YYYY-MM-DD`, the filename stem of a daily note.
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let string: String

    public init?(_ string: String) {
        guard DayKey.parse(string) != nil else { return nil }
        self.string = string
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        string = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static var today: DayKey { DayKey(Date()) }

    public var date: Date { DayKey.parse(string)! }

    public func adding(days: Int, calendar: Calendar = .current) -> DayKey {
        DayKey(calendar.date(byAdding: .day, value: days, to: date)!, calendar: calendar)
    }

    /// "Tuesday 23 September 2026"
    public var longTitle: String { Self.longFormatter.string(from: date) }

    /// "Tue 23 Sep"
    public var shortTitle: String { Self.shortFormatter.string(from: date) }

    // Built once: these run in view bodies and for every indexed note.
    // DateFormatter is thread-safe for formatting once configured.
    nonisolated(unsafe) private static let longFormatter = formatter("EEEEdMMMMyyyy")
    nonisolated(unsafe) private static let shortFormatter = formatter("EEEdMMM")

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    public var fileName: String { string + ".md" }
    public var description: String { string }

    public static func < (a: DayKey, b: DayKey) -> Bool { a.string < b.string }

    public static func fromFileName(_ name: String) -> DayKey? {
        guard name.hasSuffix(".md") else { return nil }
        return DayKey(String(name.dropLast(3)))
    }

    private static func parse(_ s: String) -> Date? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, s.count == 10,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        guard let date = Calendar.current.date(from: c),
              Calendar.current.component(.day, from: date) == d else { return nil }
        return date
    }
}
