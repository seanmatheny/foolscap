import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore

@Suite @MainActor struct MigrationTests {
    @Test func migrateCopiesNotesAndAttachmentsAndSwitches() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-migrate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let a = NotesFolder(root: base.appendingPathComponent("A")), b = base.appendingPathComponent("B")
        try a.ensureLayout()
        let day = DayKey("2026-09-20")!
        try "# A\n".write(to: a.url(for: day), atomically: true, encoding: .utf8)
        let att = a.attachmentsDirectory(for: day).appendingPathComponent("x.png")
        try FileManager.default.createDirectory(at: att.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: att)
        let library = try NotebookLibrary(folder: a, indexPath: TestIndex.path)
        try await library.migrate(to: b)
        #expect(library.folder.root.path == b.path)
        #expect(try String(contentsOf: library.folder.url(for: day), encoding: .utf8) == "# A\n")
        #expect(FileManager.default.fileExists(atPath: b.appendingPathComponent("Attachments/2026-09-20/x.png").path))
        #expect(FileManager.default.fileExists(atPath: a.url(for: day).path))   // source untouched
        await library.rescan(full: true)
        #expect(library.days == [day])
    }
}
