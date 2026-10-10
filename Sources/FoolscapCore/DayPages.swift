import CoreGraphics
import Foundation

/// A page some other section wrote on a given day (a handwritten Scribe page), as
/// the Daily page shows it in its "From your Scribe" appendix: a thumbnail, the
/// recognised text, and a route back to the page. Nothing is copied into the
/// day's note unless the user asks.
public struct DayPage: Identifiable, Hashable, Sendable {
    public var id: String
    public var sectionID: String
    /// The notebook ("Work / Notebook 3" when names collide).
    public var title: String
    /// "Page 3"
    public var subtitle: String
    /// The first recognised line, the natural heading when the text is added to a note.
    public var headline: String
    /// Paragraphs separated by blank lines.
    public var text: String
    public var route: SectionRoute

    public init(id: String, sectionID: String, title: String, subtitle: String, headline: String, text: String, route: SectionRoute) {
        self.id = id; self.sectionID = sectionID; self.title = title; self.subtitle = subtitle
        self.headline = headline; self.text = text; self.route = route
    }
}

/// A section that files pages by day (Scribe, by the date written at the top of
/// a page). Thumbnails are asked for separately, so a page stays a plain value.
@MainActor
public protocol DayPagesProvider: AnyObject {
    /// Fires when the pages may have changed (after a sync).
    var changes: AsyncStream<Void> { get }
    func pages(on day: DayKey) async -> [DayPage]
    func thumbnail(for page: DayPage, width: CGFloat, backingScale: CGFloat) async -> CGImage?
}
