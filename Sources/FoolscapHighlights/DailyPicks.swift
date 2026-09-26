import Foundation
import FoolscapCore

/// Three highlights a day, the same three all day: a seeded, weighted draw
/// over the collection. Favourites weigh three times a plain highlight, hidden
/// ones never come up, and anything shown in the last month is unlikely to.
public enum DailyPicks {
    public static let favouriteWeight = 3.0
    public static let recentWeight = 0.25
    public static let recentDays = 30

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// FNV-1a of the day string: the same day seeds the same draw.
    static func seed(_ day: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in day.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return hash
    }

    /// Every eligible highlight, best draw first (Efraimidis–Spirakis: each
    /// candidate's key is u^(1/w) for one uniform u).
    public static func ranked(_ items: [HighlightItem], day: String, recent: Set<String>) -> [HighlightItem] {
        var rng = SplitMix64(seed: seed(day))
        let candidates = items.filter { !$0.isHidden }.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        let keyed = candidates.map { item -> (Double, HighlightItem) in
            let u = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &rng)
            var weight = item.isFavourite ? favouriteWeight : 1
            if recent.contains(item.contentKey) { weight *= recentWeight }
            return (pow(u, 1 / weight), item)
        }
        return keyed.sorted { $0.0 > $1.0 }.map(\.1)
    }

    /// The day's picks: those already recorded for the day (still present, not
    /// hidden), topped up from the ranking. New picks are recorded in `history`.
    public static func picks(_ items: [HighlightItem], day: String, history: inout DailyPickHistory, count: Int = 3) -> [HighlightItem] {
        let byKey = Dictionary(items.map { ($0.contentKey, $0) }, uniquingKeysWith: { a, _ in a })
        var chosen: [HighlightItem] = []
        for key in history.days[day] ?? [] {
            if let item = byKey[key], !item.isHidden, !chosen.contains(where: { $0.contentKey == key }) { chosen.append(item) }
        }
        if chosen.count < count {
            let recent = recentKeys(history, before: day)
            let ranking = ranked(items, day: day, recent: recent)
            // Three different books when the collection allows it.
            for distinct in [true, false] where chosen.count < count {
                for item in ranking where !chosen.contains(where: { $0.contentKey == item.contentKey }) {
                    if distinct && chosen.contains(where: { $0.path == item.path }) { continue }
                    chosen.append(item)
                    if chosen.count == count { break }
                }
            }
        }
        let keys = chosen.map(\.contentKey)
        if history.days[day] != keys {
            if keys.isEmpty { history.days[day] = nil } else { history.days[day] = keys }
        }
        return chosen
    }

    /// Content keys shown in the days before `day`, within the recent window.
    static func recentKeys(_ history: DailyPickHistory, before day: String) -> Set<String> {
        guard let date = dayFormatter.date(from: day) else { return [] }
        let floor = dayKey(date.addingTimeInterval(-Double(recentDays) * 86400))
        var keys = Set<String>()
        for (d, list) in history.days where d < day && d >= floor { keys.formUnion(list) }
        return keys
    }
}

/// A small, fast, seedable generator with good statistical quality.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
