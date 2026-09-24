import Foundation
import FoolscapCore
import FoolscapStore

/// Full text over the transcripts under `Scribe/`. Tags are already reported
/// by the Daily Notes provider (they share the index), so none are repeated here.
@MainActor
final class ScribeSearchProvider: SearchProvider {
    let library: NotebookLibrary
    private let scope = SearchIndex.PathScope.under(NotesFolder.scribeDirectoryName + "/")

    init(library: NotebookLibrary) { self.library = library }

    /// The query and the transcript reads (to find each hit's line) run off the
    /// main actor: a coordinated read on iCloud Drive can take seconds.
    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        let index = library.index, folder = library.folder, scope = self.scope, sectionID = ScribeSection.sectionID
        return try await Task.detached(priority: .userInitiated) {
            let search = SearchQuery(query)
            return try index.searchNotes(query, limit: limit, scope: scope).map { note in
                try Task.checkCancellation()
                let text = (try? FileIO.read(folder.url(forRelativePath: note.path))).map { String(decoding: $0, as: UTF8.self) }
                return SearchHit(sectionID: sectionID, title: "Scribe · " + note.title,
                                 snippet: Self.cleanSnippet(note.snippet),
                                 route: SectionRoute(path: note.path, line: text.flatMap(search.firstMatchingLine)))
            }
        }.value
    }

    /// FTS snippets carry the transcript's markdown escapes and `**TODO:**`.
    nonisolated static func cleanSnippet(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }
}
