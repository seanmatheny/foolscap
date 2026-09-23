import Testing
import AppKit
@testable import FoolscapCore
@testable import FoolscapStore
@testable import FoolscapEditor

@Suite @MainActor struct PasteTests {
    @Test func pastingAScreenshotInsertsAnImageLine() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp)
        try folder.ensureLayout()
        let day = DayKey("2026-09-22")!
        let doc = NoteDocument(path: "Daily/2026-09-22.md", url: folder.url(for: day), day: day)
        doc.setText("# Day\nline\n")
        let view = MarkdownTextView(document: doc, palette: EditorPalette(theme: .classicBlack))
        view.setSelectedRange(NSRange(location: 10, length: 0))

        // What ⌃⇧⌘4 puts on the clipboard: a PNG/TIFF image.
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        view.paste(nil)

        let text = doc.text
        #expect(text.hasPrefix("# Day\nline\n"), "text was: \(text.debugDescription)")
        #expect(text.contains("![screenshot](../Attachments/2026-09-22/2026-09-22-"))
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.attachmentsDirectory(for: day).path)
        #expect(files.count == 1 && files[0].hasSuffix(".png"))
    }
}
