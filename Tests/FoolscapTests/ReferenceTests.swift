import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapReference

@Suite struct ReferenceCoverTests {
    /// The look a title derives is fixed for good: it is what every device draws, and a
    /// change here would recolour every uncustomised cover on the shelf.
    @Test func derivedLooksAreStable() {
        let expected: [(String, CoverCloth, CoverPattern)] = [
            ("Recipes", .rust, .chevron), ("Packing List", .charcoal, .chevron), ("Home Network", .charcoal, .dots),
            ("Boiler Manual", .ochre, .herringbone), ("Car", .navy, .plain), ("Garden", .moss, .pinstripe),
            ("Backups", .ochre, .grid), ("Work Onboarding", .plum, .chevron),
        ]
        for (title, cloth, pattern) in expected {
            let d = ReferenceCover.derived(title: title)
            #expect(d.cloth == cloth && d.pattern == pattern, "\(title)")
        }
    }

    @Test func derivationIgnoresCaseSpacingAndAccentForm() {
        let a = ReferenceCover.derived(title: "Café Notes")
        #expect(ReferenceCover.derived(title: "  café notes ") == a)
        #expect(ReferenceCover.derived(title: "Cafe\u{301} Notes") == a)
    }

    @Test func stableHashIsFNV1a() {
        #expect(StableHash.fnv1a("2026-11-23") == 0xd375083368303124)
        #expect(StableHash.fnv1a("") == 0xcbf29ce484222325)
    }

    @Test func monograms() {
        #expect(ReferenceCover.monogram("Recipes") == "R")
        #expect(ReferenceCover.monogram("work projects 2026") == "WP")
        #expect(ReferenceCover.monogram("— ? —") == "·")
    }

    @Test func choicesOverrideTheDerivedLook() {
        let cover = ReferenceCover.resolve(title: "Recipes", choice: CoverChoice(symbol: "fork.knife", cloth: .teal))
        #expect(cover.cloth == .teal && cover.pattern == .chevron && cover.symbol == "fork.knife" && cover.monogram == "R")
    }
}

@Suite struct ReferenceCoversFileTests {
    @Test func roundTripsAndKeepsUnknownKeys() throws {
        let raw = #"{"covers":{"A.md":{"cloth":"teal","shelf":"top"},"B.md":{"symbol":"car.fill"}},"format":1,"order":["B.md","A.md"]}"#
        var doc = ReferenceCovers.decode(Data(raw.utf8))
        #expect(ReferenceCovers.choices(in: doc)["A.md"] == CoverChoice(cloth: .teal))
        doc = ReferenceCovers.setting(CoverChoice(pattern: .dots), for: "A.md", in: doc)
        let back = ReferenceCovers.decode(try ReferenceCovers.encode(doc))
        #expect(ReferenceCovers.choices(in: back)["A.md"] == CoverChoice(pattern: .dots))
        #expect(back["order"] == .array([.string("B.md"), .string("A.md")]))
        #expect(back["covers"]?.object?["A.md"]?.object?["shelf"] == .string("top"))
        // An empty choice drops the entry once nothing else is in it.
        let cleared = ReferenceCovers.setting(CoverChoice(), for: "B.md", in: back)
        #expect(!ReferenceCovers.hasEntry("B.md", in: cleared))
    }

    @Test func encodingIsByteStable() throws {
        var doc: ReferenceCovers.Document = [:]
        doc = ReferenceCovers.setting(CoverChoice(symbol: "leaf.fill", cloth: .moss), for: "Garden.md", in: doc)
        doc = ReferenceCovers.setting(CoverChoice(cloth: .navy), for: "Car.md", in: doc)
        let once = try ReferenceCovers.encode(doc)
        #expect(try ReferenceCovers.encode(ReferenceCovers.decode(once)) == once)
    }

    @Test func unknownNamesReadAsDerived() {
        let doc = ReferenceCovers.decode(Data(#"{"covers":{"A.md":{"cloth":"tartan","pattern":"paisley"}}}"#.utf8))
        #expect(ReferenceCovers.choices(in: doc)["A.md"] == CoverChoice())
    }
}

@Suite(.serialized) @MainActor struct ReferenceSectionTests {
    private func makeSection() async throws -> (ReferenceSection, NotebookLibrary, NotesFolder) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-reference-\(UUID().uuidString)")
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        library.indexesReference = true
        let defaults = UserDefaults(suiteName: "foolscap-reference-\(UUID().uuidString)")!
        let section = ReferenceSection(library: library, defaults: defaults)
        await section.reload()
        return (section, library, folder)
    }

    @Test func enabledUnlessSwitchedOff() {
        let defaults = UserDefaults(suiteName: "foolscap-reference-\(UUID().uuidString)")!
        #expect(ReferenceSection.isEnabled(defaults))
        defaults.set(false, forKey: ReferenceSection.enabledKey)
        #expect(!ReferenceSection.isEnabled(defaults))
    }

    @Test func createsAndOpensANote() async throws {
        let (section, _, folder) = try await makeSection()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let path = try await section.create(title: "Packing List")
        #expect(path == "Reference/Packing List.md")
        #expect(try String(contentsOf: folder.url(forRelativePath: path), encoding: .utf8) == "# Packing List\n\n")
        #expect(section.mode == .note(path))
        #expect(section.notes.map(\.title) == ["Packing List"])
        await #expect(throws: ReferenceError.exists("Packing List")) { try await section.create(title: "packing list") }
        await #expect(throws: ReferenceError.emptyTitle) { try await section.create(title: "  ") }
    }

    @Test func listingSkipsDotFilesAndOtherFiles() async throws {
        let (section, _, folder) = try await makeSection()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let dir = folder.referenceDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# A\n".write(to: dir.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent(ReferenceCovers.fileName), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        await section.reload()
        #expect(section.notes.map(\.key) == ["A.md"])
    }

    @Test func renameCarriesAChosenCoverAndPinsADerivedOne() async throws {
        let (section, _, folder) = try await makeSection()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        try await section.create(title: "Recipes")
        try await section.create(title: "Car")
        let recipes = try #require(section.notes.first { $0.title == "Recipes" })
        await section.setCover(CoverChoice(symbol: "fork.knife"), for: recipes)

        // Renamed while open, it stays open under its new name.
        section.open(path: recipes.path)
        try await section.rename(recipes, to: "Cooking")
        #expect(section.choices["Cooking.md"] == CoverChoice(symbol: "fork.knife"))
        #expect(section.choices["Recipes.md"] == nil)
        #expect(section.mode == .note("Reference/Cooking.md"))

        // An uncustomised note keeps the cloth and pattern its old title gave it.
        let car = try #require(section.notes.first { $0.title == "Car" })
        let before = section.cover(for: car)
        try await section.rename(car, to: "Vehicles")
        let vehicles = try #require(section.notes.first { $0.title == "Vehicles" })
        let after = section.cover(for: vehicles)
        #expect(after.cloth == before.cloth && after.pattern == before.pattern)
        #expect(after.monogram == "V")
    }

    @Test func aRenameOutsideTheAppKeepsTheCover() async throws {
        let (section, _, folder) = try await makeSection()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        try await section.create(title: "Garden")
        let garden = try #require(section.notes.first)
        await section.setCover(CoverChoice(cloth: .moss, pattern: .waves), for: garden)
        try FileManager.default.moveItem(at: folder.url(forRelativePath: "Reference/Garden.md"),
                                         to: folder.url(forRelativePath: "Reference/Allotment.md"))
        await section.reload()
        #expect(section.choices["Allotment.md"] == CoverChoice(cloth: .moss, pattern: .waves))
        #expect(section.choices["Garden.md"] == nil)
    }

    @Test func removingANoteDropsItsCover() async throws {
        let (section, _, folder) = try await makeSection()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        try await section.create(title: "Old")
        let old = try #require(section.notes.first)
        await section.setCover(CoverChoice(symbol: "car.fill"), for: old)
        try await section.remove(old, permanently: true)
        #expect(section.notes.isEmpty)
        #expect(section.choices.isEmpty)
        #expect(section.mode == .shelf)
    }

    /// Reference notes are searched in their own scope, are not Daily hits, and their
    /// checklists stay out of the Tasks tab.
    @Test func indexedWithoutTasks() async throws {
        let (section, library, folder) = try await makeSection()
        defer { try? FileManager.default.removeItem(at: folder.root) }
        try await library.createNote(atRelativePath: "Reference/Packing.md", text: "# Packing\n\n- [ ] Passport #travel\n")
        await section.reload()
        await library.rescan()
        let index = library.index
        #expect(try index.searchNotes("passport", scope: .under("Reference/")).map(\.path) == ["Reference/Packing.md"])
        #expect(try index.searchNotes("passport", scope: .notUnderAny(["Scribe/", "Highlights/", "Reference/"])).isEmpty)
        #expect(try index.tasks().isEmpty)
    }

    @Test func notebookFilesCarryTheFolderAndItsCovers() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-reference-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        try FileManager.default.createDirectory(at: folder.referenceDirectory, withIntermediateDirectories: true)
        try "# A\n".write(to: folder.referenceDirectory.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: folder.referenceDirectory.appendingPathComponent(ReferenceCovers.fileName), atomically: true, encoding: .utf8)
        try "x".write(to: folder.referenceDirectory.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        let paths = NotesFolder.notebookFiles(under: tmp).map(\.relativePath)
        #expect(paths.contains("Reference/A.md"))
        #expect(paths.contains("Reference/" + ReferenceCovers.fileName))
        #expect(!paths.contains("Reference/.DS_Store"))
    }
}
