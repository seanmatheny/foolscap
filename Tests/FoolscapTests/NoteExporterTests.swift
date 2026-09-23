import Testing
import Foundation
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapSections

@Suite @MainActor struct NoteExporterTests {
    @Test func exportsMarkdownHTMLAndPDF() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let d1 = DayKey("2026-09-20")!, d2 = DayKey("2026-09-21")!
        let img = folder.attachmentsDirectory(for: d1).appendingPathComponent("pic.png")
        try FileManager.default.createDirectory(at: img.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: img)
        try "# One\n\n- [ ] A task #t\n\n![pic](../Attachments/2026-09-20/pic.png)\n".write(to: folder.url(for: d1), atomically: true, encoding: .utf8)
        try "# Two\n\nSecond day.\n".write(to: folder.url(for: d2), atomically: true, encoding: .utf8)
        let library = try NotebookLibrary(folder: folder)

        let out = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let md = try NoteExporter.export(library: library, scope: .all, format: .markdown, includeAttachments: true,
                                         theme: .classicBlack, to: out)
        #expect(md.files.count == 2)
        let mdText = try String(contentsOf: md.files[0], encoding: .utf8)
        #expect(mdText.contains("![pic](Attachments/pic.png)"))
        #expect(mdText.contains("\n---\n"))
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Attachments/pic.png").path))

        let html = try NoteExporter.export(library: library, scope: .day(d2), format: .html, includeAttachments: false,
                                           theme: .classicBlack, to: out.appendingPathComponent("two.html"))
        let htmlText = try String(contentsOf: html.files[0], encoding: .utf8)
        #expect(htmlText.contains("<h1>Two</h1>"))

        let tb = try NoteExporter.export(library: library, scope: .day(d1), format: .textbundle, includeAttachments: true,
                                         theme: .classicBlack, to: out.appendingPathComponent("one.textbundle"))
        #expect(tb.files.count == 1)
        let tbText = try String(contentsOf: tb.files[0].appendingPathComponent("text.md"), encoding: .utf8)
        #expect(tbText.contains("![pic](assets/pic.png)"))
        #expect(FileManager.default.fileExists(atPath: tb.files[0].appendingPathComponent("assets/pic.png").path))
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: tb.files[0].appendingPathComponent("info.json"))) as? [String: Any]
        #expect(info?["type"] as? String == "net.daringfireball.markdown")
        let tbAll = try NoteExporter.export(library: library, scope: .all, format: .textbundle, includeAttachments: true,
                                            theme: .classicBlack, to: out)
        #expect(tbAll.files.map(\.lastPathComponent) == ["2026-09-20.textbundle", "2026-09-21.textbundle"])

        let pdf = try NoteExporter.export(library: library, scope: .range(d1, d2), format: .pdf, includeAttachments: false,
                                          theme: .classicBlack, to: out)
        let pdfData = try Data(contentsOf: pdf.files[0])
        #expect(pdfData.starts(with: Array("%PDF".utf8)))
        #expect(pdf.files[0].lastPathComponent == "foolscap-2026-09-20-to-2026-09-21.pdf")
        // FOOLSCAP_KEEP_EXPORT=/some/dir keeps the outputs for a visual check.
        if let keep = ProcessInfo.processInfo.environment["FOOLSCAP_KEEP_EXPORT"] {
            try? FileManager.default.removeItem(atPath: keep)
            try FileManager.default.copyItem(at: out, to: URL(fileURLWithPath: keep))
        }
    }
}
