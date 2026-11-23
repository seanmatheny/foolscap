import Foundation
import FoolscapCore
import FoolscapStore

/// Full text over the notes under `Reference/`. Tags are already reported by the
/// Daily Notes provider (they share the index), so none are repeated here.
@MainActor
final class ReferenceSearchProvider: SearchProvider {
    let library: NotebookLibrary
    private let scope = SearchIndex.PathScope.under(NotesFolder.referenceDirectoryName + "/")

    init(library: NotebookLibrary) { self.library = library }

    /// The query and the note reads (to find each hit's line) run off the main
    /// actor: a coordinated read on iCloud Drive can take seconds.
    func search(_ query: String, limit: Int) async throws -> [SearchHit] {
        await library.save()
        let index = library.index, folder = library.folder, scope = self.scope, sectionID = ReferenceSection.sectionID
        return try await Task.detached(priority: .userInitiated) {
            let search = SearchQuery(query)
            return try index.searchNotes(query, limit: limit, scope: scope).map { note in
                try Task.checkCancellation()
                let text = (try? FileIO.read(folder.url(forRelativePath: note.path))).map { String(decoding: $0, as: UTF8.self) }
                let title = ReferenceNote.title(forKey: ReferenceNote.key(forPath: note.path))
                return SearchHit(sectionID: sectionID, title: "Reference · " + title, snippet: note.snippet,
                                 route: SectionRoute(path: note.path, line: text.flatMap(search.firstMatchingLine)))
            }
        }.value
    }
}
