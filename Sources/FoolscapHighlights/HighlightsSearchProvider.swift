import Foundation
import FoolscapCore

/// Global search over highlights: books named by the words come first (a hit
/// opens the book's page), then quotes carrying the words in their text or note,
/// `#tags` as strict filters. Works from the section's loaded list, so it
/// never touches SQLite on a keystroke.
@MainActor
final class HighlightsSearchProvider: SearchProvider {
    private unowned let section: HighlightsSection

    init(section: HighlightsSection) { self.section = section }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let parsed = SearchQuery(query)
        guard !parsed.isEmpty else { return [] }
        let books = HighlightsSection.matchingBooks(section.books, in: section.items, parsed).prefix(limit).map { book in
            let author = book.author.isEmpty ? "" : " · " + book.author
            let shown = book.count - book.hiddenCount
            return SearchHit(sectionID: HighlightsSection.sectionID, title: book.title + author,
                             snippet: "\(shown) highlight\(shown == 1 ? "" : "s")", route: SectionRoute(path: book.path))
        }
        return books + section.items.lazy.filter { HighlightsSection.matches($0, parsed) }.prefix(max(0, limit - books.count)).map { item in
            let author = item.bookAuthor.isEmpty ? "" : " · " + item.bookAuthor
            let snippet = item.text.count > 160 ? String(item.text.prefix(160)) + "…" : item.text
            return SearchHit(sectionID: HighlightsSection.sectionID, title: item.bookTitle + author, snippet: snippet,
                             route: SectionRoute(path: item.path, line: item.line))
        }
    }

    /// Meta tags are note tags already, reported by the Daily Notes provider.
    func tags() async throws -> [String] { [] }
}
