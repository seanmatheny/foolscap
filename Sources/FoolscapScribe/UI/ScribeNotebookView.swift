import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// One notebook: every page as a facsimile with its transcript beneath,
/// stacked down a scrolling page.
struct ScribeNotebookView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: ScribeSection
    let notebook: ScribeItem
    @State private var parsed: ScribeTranscript.Parsed?
    @State private var pageSizes: [CGSize] = []
    @State private var isPlaceholder = false
    @State private var copied = false

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    private var pdfURL: URL { section.pdfURL(for: notebook) }
    private var version: String { notebook.pdfHash ?? String(notebook.updateTime) }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy, so only the pages on screen are drawn.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        header
                        if isPlaceholder {
                            Text("Downloading from iCloud…")
                                .font(.system(size: 13, design: .serif)).foregroundStyle(theme.dimInk.color)
                                .padding(.top, pitch)
                        }
                        let pageWidth = min(600, max(200, geo.size.width - 8))
                        ForEach(Array(pageSizes.enumerated()), id: \.offset) { index, size in
                            pageBlock(index: index, size: size, width: pageWidth)
                                .id(index + 1)
                        }
                        Spacer(minLength: pitch * 2)
                    }
                    .padding(.top, pitch / 2)
                }
                .onChange(of: section.pendingPage) { _, page in scroll(to: page, proxy: proxy) }
                .onChange(of: pageSizes.count) { _, _ in scroll(to: section.pendingPage, proxy: proxy) }
            }
        }
        .foregroundStyle(theme.ink.color)
        .task(id: "\(notebook.id)|\(version)|\(notebook.transcribedHash ?? "")") { await load() }
    }

    private func scroll(to page: Int?, proxy: ScrollViewProxy) {
        guard let page, pageSizes.indices.contains(page - 1) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(page, anchor: .top) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(parsed?.title ?? notebook.name).font(theme.type.heading.font).fontWeight(.bold).lineLimit(2)
                Spacer()
                headerButton(copied ? "Copied" : "Copy text", symbol: copied ? "checkmark" : "doc.on.doc") { copyText() }
                    .disabled(parsed == nil)
                headerButton("Open PDF", symbol: "arrow.up.forward.square") { NSWorkspace.shared.open(pdfURL) }
            }
            Text(subtitle).font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
        }
        .frame(minHeight: pitch * 1.5)
    }

    private var subtitle: String {
        var parts = [notebook.path]
        if let n = notebook.totalPages { parts.append("\(n) page\(n == 1 ? "" : "s")") }
        if let t = notebook.modificationTime {
            parts.append("changed " + DateFormatter.localizedString(from: Date(timeIntervalSince1970: Double(t)), dateStyle: .medium, timeStyle: .short))
        }
        return parts.joined(separator: " · ")
    }

    private func headerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium, design: .serif))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(theme.accent.color.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private func pageBlock(index: Int, size: CGSize, width: CGFloat) -> some View {
        let number = index + 1
        let page = parsed?.pages.first { $0.number == number }
        return VStack(alignment: .leading, spacing: pitch / 2) {
            Text("PAGE \(number)")
                .font(.system(size: 10 * scale, weight: .semibold, design: .serif)).tracking(1)
                .foregroundStyle(theme.dimInk.color)
                .padding(.top, pitch)
            PageFacsimile(renderer: section.renderer, id: notebook.id, url: pdfURL, version: version, page: index,
                          width: width, aspect: size.height / max(1, size.width))
            if let page, !page.isEmpty {
                VStack(alignment: .leading, spacing: pitch / 2) {
                    ForEach(Array(page.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(paragraph.enumerated()), id: \.offset) { _, line in
                                lineText(line)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .padding(.leading, 4)
            } else {
                Text(parsed == nil ? "Not read yet — the next sync recognises the handwriting." : "No handwriting recognised on this page.")
                    .font(.system(size: 13 * scale, design: .serif)).italic().foregroundStyle(theme.dimInk.color)
                    .padding(.leading, 4)
            }
        }
    }

    private func lineText(_ line: ScribeTranscript.Line) -> Text {
        let body = theme.type.body.font
        if let task = line.task {
            return Text(line.before).font(body)
                + Text("TODO: ").font(body).bold().foregroundColor(theme.accent.color)
                + Text(task).font(body)
        }
        return Text(line.before).font(body)
    }

    private func copyText() {
        guard let parsed else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parsed.plainText, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }

    private func load() async {
        let pdf = pdfURL
        if ICloudPlaceholders.isPlaceholder(pdf) {
            isPlaceholder = true
            ICloudPlaceholders.startDownload(pdf)
        } else {
            isPlaceholder = false
        }
        await section.renderer.release(except: notebook.id)
        pageSizes = await section.renderer.pageSizes(id: notebook.id, url: pdf)
        // A coordinated read on iCloud Drive can wait seconds for the file
        // provider, so it must not run on the main actor.
        let transcriptURL = section.transcriptURL(for: notebook)
        parsed = await Task.detached(priority: .userInitiated) {
            (try? FileIO.read(transcriptURL)).map { ScribeTranscript.parse(String(decoding: $0, as: UTF8.self)) }
        }.value
    }
}

/// The page image, drawn once the cell is on screen; its space is reserved
/// from the PDF's page size so the stack does not jump.
struct PageFacsimile: View {
    let renderer: ScribePageRenderer
    let id: String
    let url: URL
    let version: String
    let page: Int
    let width: CGFloat
    let aspect: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            }
        }
        .frame(width: width, height: (width * aspect).rounded())
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.18), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .task(id: "\(id)|\(version)|\(page)|\(Int(width))") {
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            image = await renderer.image(id: id, url: url, version: version, page: page, width: width, backingScale: backing)?.image
        }
    }
}
