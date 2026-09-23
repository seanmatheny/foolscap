import Foundation
import SwiftUI

/// How a section's paper index tab looks.
public struct TabAppearance: Hashable, Sendable {
    public var label: String
    public var systemImage: String?
    /// Index into the theme's tab colours; `nil` uses the section's position.
    public var colorIndex: Int?
    /// ⌘ + this letter switches to the tab.
    public var shortcut: Character?

    public init(label: String, systemImage: String? = nil, colorIndex: Int? = nil, shortcut: Character? = nil) {
        self.label = label; self.systemImage = systemImage; self.colorIndex = colorIndex; self.shortcut = shortcut
    }
}

/// A search string split into words and `#tags`. Tags are strict filters.
public struct SearchQuery: Equatable, Sendable {
    public var words: [String]
    public var tags: [String]
    /// A `#` token still being typed (last token), used for suggestions.
    public var pendingTag: String?

    public init(_ text: String) {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var words: [String] = [], tags: [String] = []
        for t in tokens {
            if t.hasPrefix("#") { tags.append(String(t.dropFirst()).lowercased()) } else { words.append(t) }
        }
        let endsWithSpace = text.last?.isWhitespace ?? true
        if !endsWithSpace, let last = tokens.last, last.hasPrefix("#") {
            pendingTag = String(last.dropFirst()).lowercased()
            tags.removeLast()
        } else {
            pendingTag = nil
        }
        self.words = words
        self.tags = tags.filter { !$0.isEmpty }
    }

    public var wordText: String { words.joined(separator: " ") }
    public var isEmpty: Bool { words.isEmpty && tags.isEmpty && pendingTag == nil }
    /// True when the query carries any tag constraint (complete or partial).
    public var hasTagFilter: Bool { !tags.isEmpty || !(pendingTag ?? "").isEmpty }

    /// Replace the pending `#` token with a chosen tag.
    public static func completing(_ text: String, with tag: String) -> String {
        guard let hash = text.lastIndex(of: "#") else { return text + " #" + tag + " " }
        return String(text[..<hash]) + "#" + tag + " "
    }

    /// The first line of `text` containing any query word (or tag), so a
    /// section can jump there when a search hit is opened.
    public func firstMatchingLine(in text: String) -> Int? {
        let needles = words.map { $0.lowercased() } + tags.map { "#" + $0 }
        guard !needles.isEmpty else { return nil }
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let l = line.lowercased()
            if needles.contains(where: { l.contains($0) }) { return i }
        }
        return nil
    }
}

/// A place a section can be asked to show: a note, optionally a line in it.
public struct SectionRoute: Hashable, Sendable {
    public var path: String
    public var line: Int?
    public init(path: String, line: Int? = nil) { self.path = path; self.line = line }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: String
    public var sectionID: String
    public var title: String
    public var snippet: String
    public var route: SectionRoute
    public init(sectionID: String, title: String, snippet: String, route: SectionRoute) {
        self.id = "\(sectionID):\(route.path):\(route.line ?? -1)"
        self.sectionID = sectionID; self.title = title; self.snippet = snippet; self.route = route
    }
}

public protocol SearchProvider: AnyObject, Sendable {
    func search(_ query: String, limit: Int) async throws -> [SearchHit]
    /// Tags the provider knows, most used first (for `#` completion).
    func tags() async throws -> [String]
}

public extension SearchProvider {
    func tags() async throws -> [String] { [] }
}

/// A tab in the notebook. Daily Notes and Tasks are built in; Scribe will be another.
@MainActor
public protocol NotebookSection: AnyObject, Identifiable {
    var id: String { get }
    var tab: TabAppearance { get }
    func makeRootView() -> AnyView
    /// Show a specific note/line (from global search). Default: no-op.
    func navigate(to route: SectionRoute)
    var searchProvider: (any SearchProvider)? { get }
    var taskProvider: (any TaskProvider)? { get }
    func makeSettingsPane() -> AnyView?
}

public extension NotebookSection {
    func navigate(to route: SectionRoute) {}
    var searchProvider: (any SearchProvider)? { nil }
    var taskProvider: (any TaskProvider)? { nil }
    func makeSettingsPane() -> AnyView? { nil }
}

// MARK: - Theme in the SwiftUI environment (here so plug-ins need only Core)

private struct NotebookThemeKey: EnvironmentKey {
    static let defaultValue: NotebookTheme = .classicBlack
}

public extension EnvironmentValues {
    var notebookTheme: NotebookTheme {
        get { self[NotebookThemeKey.self] }
        set { self[NotebookThemeKey.self] = newValue }
    }
}

public extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
