import Foundation
import FoolscapStore

/// A handwritten TODO already turned into a task, keyed by `ScribeTodos.todoKey`.
public struct TodoRecord: Codable, Equatable, Sendable {
    public var text: String
    public var page: Int
    public var addedAt: Date
    public init(text: String, page: Int, addedAt: Date) { self.text = text; self.page = page; self.addedAt = addedAt }
}

/// A folder or notebook on the Kindle, keyed by Amazon's id. Names repeat
/// across folders, so the id is the only identity.
public struct ScribeItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Path under `Scribe/` (sanitised names joined with "/"), no extension.
    public var path: String
    public var isFolder: Bool
    public var parentID: String?
    /// Order among siblings as Amazon lists them.
    public var order: Int
    /// When the PDF was last rebuilt (epoch seconds, local clock); 0 = never.
    public var updateTime: Int
    /// Amazon's modification time from the last sync, for display.
    public var modificationTime: Int?
    public var totalPages: Int?
    /// SHA-256 of the page images the current PDF was built from.
    public var contentHash: String?
    /// SHA-256 of the PDF bytes, for the viewer's render cache.
    public var pdfHash: String?
    /// Whether the transcript has been written for the current content.
    public var transcribedHash: String?
    public var todos: [String: TodoRecord]

    public init(id: String, name: String, path: String, isFolder: Bool, parentID: String?, order: Int = 0) {
        self.id = id; self.name = name; self.path = path; self.isFolder = isFolder; self.parentID = parentID
        self.order = order; self.updateTime = 0; self.todos = [:]
    }

    public var pdfRelativePath: String { "\(NotesFolder.scribeDirectoryName)/\(path).pdf" }
    public var transcriptRelativePath: String { "\(NotesFolder.scribeDirectoryName)/\(path).md" }
    public var ref: ScribeNotebookRef { ScribeNotebookRef(id: id, name: name, path: path) }
}

/// Everything the sync remembers between passes. Lives in Application Support,
/// not the synced notes folder: it is per-machine bookkeeping.
public struct ScribeState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = ScribeState.currentVersion
    public var items: [String: ScribeItem] = [:]
    public var lastSync: Date?

    public init() {}

    public static func load(from url: URL) -> ScribeState {
        guard let data = try? Data(contentsOf: url),
              let state = try? Self.decoder.decode(ScribeState.self, from: data),
              state.version == currentVersion else { return ScribeState() }
        return state
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Tree access

    public var notebooks: [ScribeItem] { items.values.filter { !$0.isFolder }.sorted { $0.path < $1.path } }
    public var rootItems: [ScribeItem] { children(of: nil) }

    public func children(of parentID: String?) -> [ScribeItem] {
        items.values.filter { $0.parentID == parentID }.sorted { ($0.isFolder ? 0 : 1, $0.order, $0.path) < ($1.isFolder ? 0 : 1, $1.order, $1.path) }
    }

    /// Every notebook under a folder, any depth.
    public func notebooks(under folderID: String) -> [ScribeItem] {
        var out: [ScribeItem] = []
        for child in children(of: folderID) {
            if child.isFolder { out += notebooks(under: child.id) } else { out.append(child) }
        }
        return out
    }

    public func item(atTranscriptPath relativePath: String) -> ScribeItem? {
        items.values.first { $0.transcriptRelativePath == relativePath }
    }
}

/// Where the Scribe section keeps its state and OCR cache.
public enum ScribePaths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foolscap/Scribe", isDirectory: true)
    }
    public static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }
    public static var ocrDirectory: URL { supportDirectory.appendingPathComponent("OCR", isDirectory: true) }
}
