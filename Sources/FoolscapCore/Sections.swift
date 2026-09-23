import Foundation
import SwiftUI

/// How a section's paper index tab looks.
public struct TabAppearance: Hashable, Sendable {
    public var label: String
    public var systemImage: String?
    /// Index into the theme's tab colours; `nil` uses the section's position.
    public var colorIndex: Int?

    public init(label: String, systemImage: String? = nil, colorIndex: Int? = nil) {
        self.label = label; self.systemImage = systemImage; self.colorIndex = colorIndex
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
