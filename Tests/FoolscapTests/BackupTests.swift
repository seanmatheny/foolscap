import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore

@Suite @MainActor struct BackupTests {
    private func makeNotebook(_ name: String) throws -> NotesFolder {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-\(name)-\(UUID().uuidString)")
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        return folder
    }

    @Test func archiveRoundTrips() async throws {
        let folder = try makeNotebook("backup")
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let day = DayKey("2026-09-20")!
        try "# Day\n\n- [ ] !! Ship it #work\n".write(to: folder.url(for: day), atomically: true, encoding: .utf8)
        let attachments = folder.attachmentsDirectory(for: day)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: attachments.appendingPathComponent("shot.png"))
        try "".write(to: folder.dailyDirectory.appendingPathComponent(".2026-09-19.md.icloud"), atomically: true, encoding: .utf8)
        let scribe = folder.scribeDirectory.appendingPathComponent("Work", isDirectory: true)
        try FileManager.default.createDirectory(at: scribe, withIntermediateDirectories: true)
        try "# nb\n".write(to: scribe.appendingPathComponent("nb.md"), atomically: true, encoding: .utf8)
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.addStandaloneTask("Quick one #home")
        await library.rescan(full: true)
        try library.index.saveLinkPreview(.init(url: "https://x.test", title: "X", summary: nil, imagePath: nil, fetchedAt: 1, failures: 0))

        let support = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Scribe/OCR"), withIntermediateDirectories: true)
        try "{}".write(to: support.appendingPathComponent("Scribe/state.json"), atomically: true, encoding: .utf8)
        try "x".write(to: support.appendingPathComponent("index-abc.sqlite"), atomically: true, encoding: .utf8)   // never included
        let prefs = try PropertyListSerialization.data(fromPropertyList: ["themeID": "kraft"], format: .xml, options: 0)

        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try BackupArchive.create(notes: folder, index: library.index, supportDirectory: support, preferencesPlist: prefs,
                                 appVersion: "0.1", to: zip)
        #expect(FileManager.default.fileExists(atPath: zip.path))

        let contents = try BackupArchive.extract(zip)
        defer { try? FileManager.default.removeItem(at: contents.root) }
        #expect(contents.manifest.includesIndex && contents.manifest.includesSupport && contents.manifest.includesPreferences)
        #expect(contents.manifest.appVersion == "0.1")
        #expect(contents.manifest.notesFolder == folder.root.path)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: contents.notebook.appendingPathComponent("Daily/2026-09-20.md").path))
        #expect(fm.fileExists(atPath: contents.notebook.appendingPathComponent("Attachments/2026-09-20/shot.png").path))
        #expect(fm.fileExists(atPath: contents.notebook.appendingPathComponent("Scribe/Work/nb.md").path))
        #expect(fm.fileExists(atPath: contents.notebook.appendingPathComponent("Tasks.md").path))
        #expect(!fm.fileExists(atPath: contents.notebook.appendingPathComponent("Daily/.2026-09-19.md.icloud").path))
        #expect(fm.fileExists(atPath: contents.support!.appendingPathComponent("Scribe/state.json").path))
        #expect(!fm.fileExists(atPath: contents.support!.appendingPathComponent("index-abc.sqlite").path))
        #expect(contents.indexFile != nil)
        let restoredPrefs = try PropertyListSerialization.propertyList(from: contents.preferencesPlist!, format: nil) as? [String: Any]
        #expect(restoredPrefs?["themeID"] as? String == "kraft")

        // The index copy is a working database with the same rows.
        let copy = try SearchIndex(path: contents.indexFile!.path)
        #expect(try copy.tasks().map(\.title) == ["!! Ship it #work", "Quick one #home"])
        #expect(try copy.linkPreview(for: "https://x.test")?.title == "X")

        // Install into an empty notebook: the files come back, and a restored index keeps the previews.
        let target = try makeNotebook("restore")
        defer { try? fm.removeItem(at: target.root) }
        try "stale".write(to: target.url(for: DayKey("2026-01-01")!), atomically: true, encoding: .utf8)
        try BackupArchive.installNotebook(from: contents, into: target)
        #expect(try String(contentsOf: target.url(for: day), encoding: .utf8) == "# Day\n\n- [ ] !! Ship it #work\n")
        #expect(!fm.fileExists(atPath: target.url(for: DayKey("2026-01-01")!).path))
        #expect(fm.fileExists(atPath: target.tasksFile.path))
        let targetIndexPath = TestIndex.path(for: target)
        let targetIndex = try SearchIndex(path: targetIndexPath)
        try targetIndex.restore(fromFileAt: contents.indexFile!.path)
        #expect(try targetIndex.linkPreview(for: "https://x.test")?.title == "X")
        #expect(try targetIndex.tasks().count == 2)
        try? fm.removeItem(atPath: targetIndexPath)
    }

    @Test func managerBacksUpAndRestoresInPlace() async throws {
        let folder = try makeNotebook("manager")
        defer { try? FileManager.default.removeItem(at: folder.root) }
        let day = DayKey("2026-09-21")!
        try "# Before\n".write(to: folder.url(for: day), atomically: true, encoding: .utf8)
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        await library.rescan(full: true)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-msupport-\(UUID().uuidString)")
        let backups = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-backups-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support); try? FileManager.default.removeItem(at: backups) }
        let defaults = UserDefaults(suiteName: "foolscap-tests-\(UUID().uuidString)")!
        let manager = BackupManager(library: library, supportDirectory: support, defaults: defaults)
        manager.folder = backups
        manager.keepCount = 2

        let first = try #require(await manager.backUpToFolder())
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(manager.lastBackup != nil)
        let generation = library.generation

        // Change the notebook, then restore: the old text is back, a safety copy was made, editors are told to reload.
        try "# After\n".write(to: folder.url(for: day), atomically: true, encoding: .utf8)
        try "# Extra\n".write(to: folder.url(for: DayKey("2026-09-22")!), atomically: true, encoding: .utf8)
        try await manager.restore(from: first)
        #expect(try String(contentsOf: folder.url(for: day), encoding: .utf8) == "# Before\n")
        #expect(!FileManager.default.fileExists(atPath: folder.url(for: DayKey("2026-09-22")!).path))
        #expect(library.generation == generation + 1)
        #expect(library.days == [day])
        #expect(try library.index.allNoteRecords().map(\.path) == ["Daily/2026-09-21.md"])
        let zips = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasSuffix(".zip") }
        #expect(zips.count == 2 && zips.contains { $0.hasPrefix("Foolscap Before Restore") })

        // Pruning keeps only the newest few.
        _ = await manager.backUpToFolder()
        _ = await manager.backUpToFolder()
        #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasSuffix(".zip") }.count <= 2)
    }
}
