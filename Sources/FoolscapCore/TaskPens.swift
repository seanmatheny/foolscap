import Foundation

/// A highlighter pen's colour: named, so a pen reads on every theme. Each has a
/// face for paper (multiplied in) and one for a black page (screened on).
public enum PenColour: String, Codable, CaseIterable, Sendable {
    case yellow, green, mint, blue, violet, pink, orange, grey

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public func rgba(onDark: Bool) -> RGBA {
        onDark ? .hex(dark, alpha: 0.32) : .hex(light, alpha: 0.5)
    }

    private var light: UInt32 {
        switch self {
        case .yellow: return 0xF7D842
        case .green: return 0x8ED081
        case .mint: return 0x7FD9B8
        case .blue: return 0xB9C6EA
        case .violet: return 0xC9B8F0
        case .pink: return 0xF4B6CF
        case .orange: return 0xF8B46A
        case .grey: return 0xC8C4BC
        }
    }

    private var dark: UInt32 {
        switch self {
        case .yellow: return 0xD7D39A
        case .green: return 0xA8D88C
        case .mint: return 0x9EDFC0
        case .blue: return 0x9ED1F5
        case .violet: return 0xC4B5FF
        case .pink: return 0xF3A6C7
        case .orange: return 0xF5B98A
        case .grey: return 0xB9B9C2
        }
    }
}

/// A tag given a highlighter: tasks carrying the tag are stroked in its colour.
public struct TagPen: Codable, Hashable, Sendable {
    public var tag: String
    public var colour: PenColour

    public init(tag: String, colour: PenColour) {
        self.tag = tag; self.colour = colour
    }
}

/// The pens chosen in Settings, in order: at most `limit`, one per tag. The order
/// is the sort order of the task lanes when `sortsLanes` is on. A task's pen is
/// the first in the list whose tag it carries; most tasks have none and stay plain.
/// Stored as JSON in the `taskPens` default, so `-taskPens '[…]'` previews a set.
public struct TaskPens: Codable, Hashable, Sendable {
    public static let limit = 8
    public static let key = "taskPens"
    public static let sortKey = "taskSortByPen"

    public private(set) var pens: [TagPen]
    /// Lanes list penned tasks first, pen by pen, when on (the default).
    public var sortsLanes: Bool

    public init(_ pens: [TagPen] = [], sortsLanes: Bool = true) {
        var seen: Set<String> = []
        self.pens = Array(pens.filter { !$0.tag.isEmpty && seen.insert($0.tag).inserted }.prefix(Self.limit))
        self.sortsLanes = sortsLanes
    }

    public var isEmpty: Bool { pens.isEmpty }
    public var isFull: Bool { pens.count >= Self.limit }

    /// The pen a task is stroked with: the first pen whose tag it carries, and where it sits in the list.
    public func pen(for task: TaskItem) -> (index: Int, pen: TagPen)? {
        for (i, pen) in pens.enumerated() where task.tags.contains(pen.tag) { return (i, pen) }
        return nil
    }

    public func colour(for task: TaskItem, onDark: Bool) -> RGBA? {
        pen(for: task)?.pen.colour.rgba(onDark: onDark)
    }

    /// Where a task sorts within its lane: its pen's place, unpenned tasks after
    /// every pen; every task alike when the lanes are not sorted by pen.
    public func laneRank(of task: TaskItem) -> Int {
        guard sortsLanes else { return 0 }
        return pen(for: task)?.index ?? Self.limit
    }

    // MARK: Defaults

    public static func load(from defaults: UserDefaults = .standard) -> TaskPens {
        let sorts = defaults.object(forKey: sortKey) as? Bool ?? true
        return TaskPens(defaults.string(forKey: key).flatMap(parse) ?? [], sortsLanes: sorts)
    }

    /// The stored JSON, or `tag=colour,tag=colour`: the argument domain drops a JSON
    /// value (it is not a property list), so `-taskPens lais=mint,home=pink` previews a set.
    public static func parse(_ text: String) -> [TagPen]? {
        if let pens = try? JSONDecoder().decode([TagPen].self, from: Data(text.utf8)) { return pens }
        var pens: [TagPen] = []
        for item in text.split(separator: ",") {
            let parts = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let colour = PenColour(rawValue: parts[1]) else { return nil }
            pens.append(TagPen(tag: String(parts[0].drop { $0 == "#" }), colour: colour))
        }
        return pens.isEmpty ? nil : pens
    }

    /// Writes the pens; the sort toggle is its own default (`sortKey`).
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(pens), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.key)
        }
    }

    public static func encode(_ pens: [TagPen]) -> String {
        (try? JSONEncoder().encode(pens)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}
