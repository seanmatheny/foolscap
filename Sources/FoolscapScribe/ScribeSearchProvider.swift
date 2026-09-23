import Foundation
import FoolscapCore
import FoolscapStore

/// Full text over the transcripts under `Scribe/`. Tags are already reported
/// by the Daily Notes provider (they share the index), so none are repeated here.
@MainActor
final class ScribeSearchProvider: SearchProvider {
    static let sectionID = "scribe"
    let library: NotebookLibrary
    private let scope = SearchIndex.PathScope.under(NotesFolder.scribeDirectoryName + "/")

    init(library: NotebookLibrary) { self.library = library }

    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        try library.index.searchNotes(query, limit: limit, scope: scope).map { note in
            let url = library.folder.url(forRelativePath: note.path)
            let text = (try? FileIO.read(url)).map { String(decoding: $0, as: UTF8.self) }
            let line = text.flatMap { SearchQuery(query).firstMatchingLine(in: $0) }
            return SearchHit(sectionID: Self.sectionID, title: "Scribe · " + note.title,
                             snippet: Self.cleanSnippet(note.snippet), route: SectionRoute(path: note.path, line: line))
        }
    }

    /// FTS snippets carry the transcript's markdown escapes and `**TODO:**`.
    static func cleanSnippet(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }
}
