import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

/// What a page becomes when added to the day's note: its first line as a
/// heading and the text as a quote, escaped so recognised text cannot make tags.
public enum DayPageMarkdown {
    public static func heading(for page: DayPage) -> String { "## " + MarkdownEscaping.escape(page.headline) }

    public static func block(for page: DayPage) -> String {
        var lines = [heading(for: page)]
        for (index, paragraph) in page.text.components(separatedBy: "\n\n").enumerated() {
            if index > 0 { lines.append(">") }
            lines += paragraph.components(separatedBy: "\n").map { "> " + MarkdownEscaping.escape($0) }
        }
        return lines.joined(separator: "\n")
    }

    /// Whether the note already holds the page (its heading line), so it is added once.
    public static func isPresent(in text: String, page: DayPage) -> Bool {
        let heading = heading(for: page)
        return text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == heading }
    }
}

/// "From your Scribe": the handwritten pages dated this day, after the note, read
/// live from their transcripts. A click opens the page in its tab; "Add to this
/// note" copies the text in, once, on request.
struct DayPagesAppendix: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.editorInsertion) private var insertion
    @Bindable var section: DailyNotesSection
    let day: DayKey
    let document: NoteDocument
    let providers: [any DayPagesProvider]
    @State private var pages: [DayPage] = []
    @State private var thumbnails: [String: CGImage] = [:]

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    static let thumbnailWidth: CGFloat = 100

    var body: some View {
        let palette = EditorPalette(theme: theme)
        let font = palette.body
        let lineHeight = font.ascender - font.descender + font.leading
        let slack = max(0, pitch - lineHeight)
        Group {
            if !pages.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "pencil.and.scribble")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.dimInk.color)
                            .frame(width: 12)
                        Text("From your Scribe")
                            .font(.system(size: 17 * scale, weight: .bold, design: .serif))
                        Text("\(pages.count)").font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                    }
                    .frame(height: pitch)
                    ForEach(pages) { page in
                        pageRow(page, font: Font(font), slack: slack)
                            .padding(.top, pitch)
                    }
                }
                .foregroundStyle(theme.ink.color)
            }
        }
        .task(id: "\(day.string)|\(providers.count)") {
            await load()
            // Every provider's change stream, merged; leaving the day ends the listeners.
            let streams = providers.map(\.changes)
            let merged = AsyncStream<Void> { continuation in
                let listeners = streams.map { stream in Task { for await _ in stream { continuation.yield() } } }
                continuation.onTermination = { _ in for listener in listeners { listener.cancel() } }
            }
            for await _ in merged { await load() }
        }
    }

    private func pageRow(_ page: DayPage, font: Font, slack: CGFloat) -> some View {
        let added = DayPageMarkdown.isPresent(in: document.text, page: page)
        return HStack(alignment: .top, spacing: 14) {
            Button { open(page) } label: { thumbnail(page) }
                .buttonStyle(.plain)
                .help("Open the page in the Scribe tab")
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button { open(page) } label: {
                        Text(page.title + " · " + page.subtitle)
                            .font(.system(size: 12 * scale, weight: .medium, design: .serif))
                            .foregroundStyle(theme.dimInk.color)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button {
                        insertion?.append(DayPageMarkdown.block(for: page))
                    } label: {
                        Label(added ? "Added" : "Add to this note", systemImage: added ? "checkmark" : "text.insert")
                            .font(.system(size: 11.5, weight: .medium, design: .serif))
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(theme.accent.color.opacity(added ? 0.07 : 0.14)))
                    }
                    .buttonStyle(.plain)
                    .disabled(added || insertion == nil)
                }
                .frame(height: pitch)
                Text(page.text)
                    .font(font)
                    .lineSpacing(slack)
                    .padding(.vertical, slack / 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        // The note's text changing (the block added, or removed again) re-reads presence.
        .id("\(page.id)|\(document.editCount)")
    }

    private func thumbnail(_ page: DayPage) -> some View {
        let width = Self.thumbnailWidth
        return ZStack {
            Color.white
            if let image = thumbnails[page.id] {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            }
        }
        .frame(width: width, height: thumbnails[page.id].map { CGFloat($0.height) / CGFloat($0.width) * width }.map { $0.rounded() } ?? (width * 4 / 3).rounded())
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        .task(id: page.id) {
            guard thumbnails[page.id] == nil else { return }
            for provider in providers {
                if let image = await provider.thumbnail(for: page, width: width, backingScale: NSScreen.main?.backingScaleFactor ?? 2) {
                    thumbnails[page.id] = image
                    return
                }
            }
        }
    }

    private func open(_ page: DayPage) { section.openRoute?(page.sectionID, page.route) }

    private func load() async {
        var found: [DayPage] = []
        for provider in providers { found += await provider.pages(on: day) }
        pages = found
    }
}
