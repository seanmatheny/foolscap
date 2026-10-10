import AppKit
import Foundation
import FoolscapCore
import FoolscapStore

/// The Scribe pages written on a day, read from the transcripts (whose page
/// headings carry the handwritten date), for the Daily page's appendix.
@MainActor
final class ScribeDayPagesProvider: DayPagesProvider {
    unowned let section: ScribeSection
    /// Parsed transcripts by notebook id, valid while the notebook's transcript key holds.
    private var parsed: [String: (key: String, parsed: ScribeTranscript.Parsed)] = [:]
    /// Where each page's thumbnail comes from.
    private var sources: [String: (notebook: ScribeItem, pageIndex: Int)] = [:]

    static let thumbnailWidth: CGFloat = 100

    init(section: ScribeSection) { self.section = section }

    nonisolated var changes: AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task { @MainActor [section] in
                for await _ in section.library.changes { continuation.yield() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// After a sync replaced the state: transcripts may have been rewritten.
    func invalidate() { parsed = [:] }

    func pages(on day: DayKey) async -> [DayPage] {
        let notebooks = section.state.notebooks
        let titles = ScribeTranscript.noteTitles(notebooks.map(\.ref))
        var result: [DayPage] = []
        for notebook in notebooks {
            let key = notebook.transcribedHash ?? ""
            let transcript: ScribeTranscript.Parsed
            if let cached = parsed[notebook.id], cached.key == key {
                transcript = cached.parsed
            } else {
                // A coordinated read on iCloud Drive can block for seconds.
                let url = section.transcriptURL(for: notebook)
                guard let read = await Task.detached(priority: .userInitiated, operation: {
                    (try? FileIO.read(url)).map { ScribeTranscript.parse(String(decoding: $0, as: UTF8.self)) }
                }).value else { continue }
                parsed[notebook.id] = (key, read)
                transcript = read
            }
            let title = titles[notebook.id] ?? notebook.name
            for page in transcript.pages(on: day) where !page.isEmpty {
                let route = SectionRoute(path: notebook.transcriptRelativePath, line: page.headingLine)
                let id = "\(ScribeSection.sectionID):\(route.path)#\(page.headingLine)"
                sources[id] = (notebook, page.number - 1)
                result.append(DayPage(id: id, sectionID: ScribeSection.sectionID, title: title, subtitle: "Page \(page.number)",
                                      headline: page.firstLine ?? title,
                                      text: page.paragraphs.map { $0.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n"),
                                      route: route))
            }
        }
        return result
    }

    func thumbnail(for page: DayPage, width: CGFloat, backingScale: CGFloat) async -> CGImage? {
        guard let (notebook, index) = sources[page.id] else { return nil }
        let version = notebook.pdfHash ?? String(notebook.updateTime)
        let renderer = section.renderer
        let url = section.pdfURL(for: notebook)
        if let cached = await renderer.cachedImage(id: notebook.id, version: version, page: index, width: width, backingScale: backingScale) {
            return cached.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        // A PDF iCloud has evicted is left alone: the Daily page never forces a download.
        guard !ICloudPlaceholders.needsDownload(url) else { return nil }
        return await renderer.image(id: notebook.id, url: url, version: version, page: index, width: width, backingScale: backingScale)?
            .image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
