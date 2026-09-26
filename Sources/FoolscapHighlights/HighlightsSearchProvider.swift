import Foundation
import FoolscapCore

/// Global search over highlights: words in the quote, note, title or author,
/// `#tags` as strict filters. Works from the section's loaded list, so it
/// never touches SQLite on a keystroke.
@MainActor
final class HighlightsSearchProvider: SearchProvider {
    private unowned let section: HighlightsSection

    init(section: HighlightsSection) { self.section = section }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let parsed = SearchQuery(query)
        guard !parsed.isEmpty else { return [] }
        return section.items.lazy.filter { HighlightsSection.matches($0, parsed) }.prefix(limit).map { item in
            let author = item.bookAuthor.isEmpty ? "" : " · " + item.bookAuthor
            let snippet = item.text.count > 160 ? String(item.text.prefix(160)) + "…" : item.text
            return SearchHit(sectionID: HighlightsSection.sectionID, title: item.bookTitle + author, snippet: snippet,
                             route: SectionRoute(path: item.path, line: item.line))
        }
    }

    /// Meta tags are note tags already, reported by the Daily Notes provider.
    func tags() async throws -> [String] { [] }
}
