import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// One note on the Reference shelf: `Reference/<Title>.md`.
public struct ReferenceNote: Identifiable, Hashable, Sendable {
    /// Relative to the notes folder: "Reference/Recipes.md".
    public var path: String
    /// Relative to `Reference/`, the sidecar's key: "Recipes.md".
    public var key: String
    /// The file name without ".md".
    public var title: String
    public var modified: Date
    public var size: Int
    /// iCloud has not downloaded it yet (the phone).
    public var isPlaceholder: Bool
    public var id: String { path }

    public static func key(forPath path: String) -> String {
        String(path.dropFirst(NotesFolder.referenceDirectoryName.count + 1))
    }

    public static func title(forKey key: String) -> String {
        key.hasSuffix(".md") ? String(key.dropLast(3)) : key
    }
}

/// How the shelf is ordered.
public enum ReferenceSort: String, CaseIterable, Sendable {
    case title, edited
    public static let key = "referenceSort"
    public var label: String { self == .title ? "A–Z" : "Recent" }
}

public enum ReferenceError: LocalizedError, Equatable {
    case emptyTitle
    case exists(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTitle: return "A note needs a title."
        case .exists(let title): return "There is already a note called “\(title)” on the shelf."
        }
    }
}

/// The Reference tab: long-running notes on a shelf of cloth-bound covers, each
/// opened in the editor. The covers' look comes from each note's title, overlaid
/// with what the reader chose in `Reference/.foolscap-covers.json`.
@MainActor
@Observable
public final class ReferenceSection: NotebookSection {
    public static let sectionID = "reference"
    public static let enabledKey = "referenceEnabled"
    public let id = ReferenceSection.sectionID
    public let tab = TabAppearance(label: "Reference", systemImage: "books.vertical", colorIndex: 6, shortcut: "r")

    /// On unless switched off: the tab needs no account, permission or helper.
    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    public enum Mode: Equatable {
        case shelf
        case note(String)
    }

    public var mode: Mode = .shelf
    /// Narrows the shelf to titles carrying every word typed.
    public var filter = ""
    /// A line to reveal once a note opens (from search).
    public var pendingLine: Int?
    /// A note whose cover picker the shelf opens once it shows (`--reference-cover=Title`, for screenshots).
    public var pendingCoverPicker: String?
    public private(set) var notes: [ReferenceNote] = []
    /// Sidecar key → what the reader chose.
    public private(set) var choices: [String: CoverChoice] = [:]
    /// Whether the folder has been listed once (the shelf says nothing until then).
    public private(set) var hasLoaded = false
    public var lastError: String?
    public var sort: ReferenceSort {
        didSet { defaults.set(sort.rawValue, forKey: ReferenceSort.key) }
    }

    public let library: NotebookLibrary
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The last listing's stats by key, to recognise a rename made outside the app.
    @ObservationIgnored private var previousStats: [String: (mtime: Double, size: Int)]?
    /// The folder `previousStats` describes: a folder switch is no rename.
    @ObservationIgnored private var listedRoot: URL?
    @ObservationIgnored private lazy var provider = ReferenceSearchProvider(library: library)

    public init(library: NotebookLibrary, defaults: UserDefaults = .standard) {
        self.library = library
        self.defaults = defaults
        sort = defaults.string(forKey: ReferenceSort.key).flatMap(ReferenceSort.init(rawValue:)) ?? .title
    }

    public func makeRootView() -> AnyView { AnyView(ReferencePage(section: self)) }

    public var searchProvider: (any SearchProvider)? { provider }

    public func makeSettingsPane() -> AnyView? { AnyView(ReferenceSettingsPane(section: self)) }

    public func navigate(to route: SectionRoute) {
        guard route.path.hasPrefix(NotesFolder.referenceDirectoryName + "/") else { return }
        open(path: route.path, line: route.line)
    }

    /// Turning away puts the note back on the shelf: the tab always opens there.
    public func didLeaveTab() {
        mode = .shelf
        filter = ""
    }

    public func start() {
        guard listener == nil else { return }
        let stream = library.folderChanges
        listener = Task { [weak self] in
            for await _ in stream { self?.scheduleReload() }
        }
        scheduleReload()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        reloadTask?.cancel()
    }

    // MARK: The shelf

    /// The notes as the shelf shows them: filtered by title, in the chosen order.
    public var shelf: [ReferenceNote] {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        let shown = words.isEmpty ? notes : notes.filter { note in
            let title = note.title.lowercased()
            return words.allSatisfy { title.contains($0) }
        }
        switch sort {
        case .title: return shown.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .edited: return shown.sorted { $0.modified > $1.modified }
        }
    }

    public func cover(for note: ReferenceNote) -> ResolvedCover {
        ReferenceCover.resolve(title: note.title, choice: choices[note.key] ?? CoverChoice())
    }

    public func note(atPath path: String) -> ReferenceNote? { notes.first { $0.path == path } }

    public func open(path: String, line: Int? = nil) {
        pendingLine = line
        mode = .note(path.precomposedStringWithCanonicalMapping)
    }

    public func showShelf() {
        mode = .shelf
        pendingLine = nil
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    /// List the folder and read the sidecar off the main actor.
    public func reload() async {
        let folder = library.folder
        if listedRoot != folder.root { previousStats = nil; listedRoot = folder.root }
        let listed = await Task.detached(priority: .utility) { Self.list(folder) }.value
        var document = await library.readReferenceCovers()
        if let carried = carryOver(listed, document: document) {
            document = (try? await library.updateReferenceCovers({ ReferenceCovers.moving(carried.from, to: carried.to, in: $0) })) ?? document
        }
        previousStats = Dictionary(listed.map { ($0.key, (mtime: $0.modified.timeIntervalSince1970, size: $0.size)) },
                                   uniquingKeysWith: { a, _ in a })
        if notes != listed { notes = listed }
        let newChoices = ReferenceCovers.choices(in: document)
        if choices != newChoices { choices = newChoices }
        hasLoaded = true
        // A note deleted or renamed elsewhere while it was open goes back to the shelf.
        if case .note(let path) = mode, !listed.contains(where: { $0.path == path }) { mode = .shelf }
    }

    nonisolated static func list(_ folder: NotesFolder) -> [ReferenceNote] {
        func note(_ url: URL, placeholder: Bool) -> ReferenceNote {
            let path = folder.relativePath(of: url)
            let key = ReferenceNote.key(forPath: path)
            let stat = FileIO.stat(url)
            return ReferenceNote(path: path, key: key, title: ReferenceNote.title(forKey: key),
                                 modified: Date(timeIntervalSince1970: stat?.mtime ?? 0), size: stat?.size ?? 0,
                                 isPlaceholder: placeholder)
        }
        let real = folder.listReferenceNotes().map { note($0, placeholder: false) }
        let known = Set(real.map(\.key))
        let waiting = folder.listReferencePlaceholders().map { note($0, placeholder: true) }.filter { !known.contains($0.key) }
        return real + waiting
    }

    /// A rename made outside the app (Finder, Files): exactly one customised note gone and
    /// exactly one new, uncustomised note of the same size and age in its place. The
    /// cover goes with it; anything less certain is left alone.
    private func carryOver(_ listed: [ReferenceNote], document: ReferenceCovers.Document) -> (from: String, to: String)? {
        guard let previous = previousStats else { return nil }
        let entries = ReferenceCovers.choices(in: document)
        let current = Set(listed.map(\.key))
        let vanished = previous.keys.filter { !current.contains($0) && entries[$0] != nil }
        let appeared = listed.filter { previous[$0.key] == nil && entries[$0.key] == nil && !$0.isPlaceholder }
        guard vanished.count == 1, appeared.count == 1, let old = vanished.first, let stat = previous[old] else { return nil }
        let new = appeared[0]
        guard stat.size == new.size, abs(stat.mtime - new.modified.timeIntervalSince1970) < 1 else { return nil }
        return (old, new.key)
    }

    // MARK: Changes

    /// The file name a title gets, or an error when it has none or is taken.
    func fileKey(forTitle raw: String, except current: String? = nil) throws -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.lowercased().hasSuffix(".md") { title = String(title.dropLast(3)) }
        guard !title.isEmpty else { throw ReferenceError.emptyTitle }
        let key = FileNames.sanitize(title) + ".md"
        if let clash = notes.first(where: { $0.key.lowercased() == key.lowercased() && $0.key != current }) {
            throw ReferenceError.exists(clash.title)
        }
        return key
    }

    /// Write a new note headed with its title and open it.
    @discardableResult
    public func create(title: String) async throws -> String {
        let key = try fileKey(forTitle: title)
        let path = NotesFolder.referenceDirectoryName + "/" + key
        let heading = ReferenceNote.title(forKey: key)
        try await library.createNote(atRelativePath: path, text: "# \(heading)\n\n")
        await reload()
        open(path: path)
        return path
    }

    /// Rename a note's file; its cover goes with it, and a cover it never had chosen
    /// keeps the cloth and pattern its old title gave it (only the monogram follows).
    public func rename(_ note: ReferenceNote, to title: String) async throws {
        let key = try fileKey(forTitle: title, except: note.key)
        guard key != note.key else { return }
        let newPath = NotesFolder.referenceDirectoryName + "/" + key
        let wasOpen = mode == .note(note.path)
        if wasOpen { mode = .shelf }
        try await library.moveNote(from: note.path, to: newPath)
        let derived = ReferenceCover.derived(title: note.title)
        let oldKey = note.key
        _ = try? await library.updateReferenceCovers { doc in
            if ReferenceCovers.hasEntry(oldKey, in: doc) {
                return ReferenceCovers.moving(oldKey, to: key, in: doc)
            }
            return ReferenceCovers.setting(CoverChoice(cloth: derived.cloth, pattern: derived.pattern), for: key, in: doc)
        }
        await reload()
        if wasOpen { open(path: newPath) }
    }

    /// Choose a note's cover (an empty choice goes back to the one its title gives).
    public func setCover(_ choice: CoverChoice, for note: ReferenceNote) async {
        choices[note.key] = choice.isEmpty ? nil : choice
        let key = note.key
        do {
            let doc = try await library.updateReferenceCovers { ReferenceCovers.setting(choice, for: key, in: $0) }
            choices = ReferenceCovers.choices(in: doc)
        } catch {
            lastError = "Could not save the cover: \(error.localizedDescription)"
        }
    }

    /// Put a note in the Trash (`permanently`: delete it, where the folder has no Trash).
    public func remove(_ note: ReferenceNote, permanently: Bool = false) async throws {
        if mode == .note(note.path) { mode = .shelf }
        try await library.removeNote(atRelativePath: note.path, permanently: permanently)
        let key = note.key
        _ = try? await library.updateReferenceCovers { ReferenceCovers.removing(key, in: $0) }
        await reload()
    }

    #if canImport(AppKit)
    public func revealInFinder(_ note: ReferenceNote) {
        NSWorkspace.shared.activateFileViewerSelecting([library.folder.url(forRelativePath: note.path)])
    }
    #endif

    // MARK: Sample

    /// Ten made-up notes in an empty `Reference/` folder, for screenshots of a scratch
    /// notebook (`--reference-sample`). Does nothing when the folder holds a note.
    public func addSampleNotes() async {
        await reload()
        guard notes.isEmpty else { return }
        let samples: [(String, String)] = [
            ("Packing List", "- [ ] Passport\n- [ ] Chargers\n- [ ] Toothbrush\n"),
            ("Recipes", "## Weeknight dal\n\nRed lentils, cumin, turmeric, a tin of tomatoes.\n"),
            ("Home Network", "Router in the hall cupboard. Mesh nodes upstairs and in the garage.\n"),
            ("Boiler Manual", "Pressure should sit between 1 and 1.5 bar. Top up with the filling loop.\n"),
            ("Reading List", "- The Dispossessed\n- Piranesi\n- A Psalm for the Wild-Built\n"),
            ("Car", "Service every 15,000 km. Tyres 32 psi front, 30 rear.\n"),
            ("Gift Ideas", "Mum: a good secateurs. Sam: the Lego botanical set.\n"),
            ("Backups", "Time Machine to the NAS nightly; offsite copy on the first of the month.\n"),
            ("Garden", "Plant garlic on the shortest day, harvest on the longest.\n"),
            ("Work Onboarding", "Accounts to ask for, the people to meet, where the docs live.\n"),
        ]
        for (title, body) in samples {
            try? await library.createNote(atRelativePath: "\(NotesFolder.referenceDirectoryName)/\(title).md", text: "# \(title)\n\n\(body)")
        }
        _ = try? await library.updateReferenceCovers { doc in
            var doc = ReferenceCovers.setting(CoverChoice(symbol: "fork.knife"), for: "Recipes.md", in: doc)
            doc = ReferenceCovers.setting(CoverChoice(symbol: "car.fill", cloth: .navy), for: "Car.md", in: doc)
            return ReferenceCovers.setting(CoverChoice(symbol: "leaf.fill", cloth: .moss, pattern: .waves), for: "Garden.md", in: doc)
        }
        await reload()
    }
}
