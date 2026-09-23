import AppKit
import UniformTypeIdentifiers
import FoolscapCore
import FoolscapStore

/// Copies pasted or dropped images into the note's Attachments folder and
/// returns the markdown to insert.
@MainActor
enum AttachmentImporter {
    static let imageTypes: [UTType] = [.png, .jpeg, .gif, .tiff, .heic, .webP, .bmp]

    /// Directory for a note's attachments: `Attachments/<day>/` beside `Daily/`.
    static func attachmentsDirectory(for document: NoteDocument) -> URL {
        let root = document.url.deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(document.day?.string ?? "misc", isDirectory: true)
    }

    static func relativePath(for file: URL, document: NoteDocument) -> String {
        "../Attachments/\(document.day?.string ?? "misc")/\(file.lastPathComponent)"
    }

    /// Write PNG data for an image and return the markdown line.
    static func importImage(_ image: NSImage, document: NoteDocument, name: String? = nil) -> String? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let stamp = Self.stamp()
        let fileName = name.map { sanitise($0) } ?? "\(document.day?.string ?? "image")-\(stamp).png"
        return importData(png, fileName: fileName, document: document, alt: name ?? "screenshot")
    }

    /// Copy an existing image file, keeping its name (deduplicated).
    static func importFile(_ url: URL, document: NoteDocument) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return importData(data, fileName: sanitise(url.lastPathComponent), document: document,
                          alt: url.deletingPathExtension().lastPathComponent)
    }

    private static func importData(_ data: Data, fileName: String, document: NoteDocument, alt: String) -> String? {
        let dir = attachmentsDirectory(for: document)
        var target = dir.appendingPathComponent(fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let base = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
            target = dir.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1
        }
        do { try FileIO.write(data, to: target) } catch { return nil }
        let cleanAlt = alt.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
        return "![\(cleanAlt)](\(relativePath(for: target, document: document)))"
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "HHmmss"; return f.string(from: Date())
    }

    private static func sanitise(_ name: String) -> String {
        name.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return imageTypes.contains { type.conforms(to: $0) }
    }
}
