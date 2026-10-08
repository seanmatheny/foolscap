import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// One notebook: every page as a facsimile with its transcript beneath,
/// stacked down a scrolling page. The stack is not lazy: a lazy stack guesses
/// the heights of pages it has not laid out, so scrolling to a page by id
/// landed anywhere from a page off to the end of the notebook. The bitmaps
/// are what cost, and `PageFacsimile` only holds one while on screen.
struct ScribeNotebookView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: ScribeSection
    let notebook: ScribeItem
    @State private var parsed: ScribeTranscript.Parsed?
    /// The parsed pages by number, so each page block finds its own directly.
    @State private var transcriptPages: [Int: ScribeTranscript.Page] = [:]
    @State private var pageSizes: [CGSize] = []
    @State private var isPlaceholder = false
    /// The PDF is on this Mac, so pages missing from the cache can be drawn.
    @State private var pdfReady = false
    @State private var copied = false
    /// Scrolled to within a few lines of the end: the jump button then goes back to the top.
    @State private var nearEnd = false
    /// The block at the top of the view: a page number, `topID` or `endID`.
    /// Setting it scrolls there; SwiftUI updates it as the user scrolls.
    @State private var position: Int?
    /// Notebooks this long get the jump button.
    static let jumpPages = 3

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    private var pdfURL: URL { section.pdfURL(for: notebook) }
    private var version: String { notebook.pdfHash ?? String(notebook.updateTime) }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .id(Self.topID)
                    if isPlaceholder {
                        Text("Downloading from iCloud…")
                            .font(.system(size: 13, design: .serif)).foregroundStyle(theme.dimInk.color)
                            .padding(.top, pitch)
                    }
                    let pageWidth = min(600, max(200, geo.size.width - 8))
                    // Keyed on the page number: `scrollPosition` addresses the
                    // ForEach identity, not an `.id` put on the block.
                    ForEach(Array(pageSizes.indices.map { $0 + 1 }), id: \.self) { number in
                        pageBlock(index: number - 1, size: pageSizes[number - 1], width: pageWidth)
                    }
                    Spacer(minLength: pitch * 2)
                        .id(Self.endID)
                }
                .padding(.top, pitch / 2)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position, anchor: .top)
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - pitch * 4
            } action: { _, near in nearEnd = near }
            .overlay(alignment: .bottomTrailing) {
                if pageSizes.count >= Self.jumpPages { jumpButton }
            }
            .onChange(of: position) { _, block in
                guard let block, !pageSizes.isEmpty else { return }
                // The header counts as page 1, the end spacer as the last page.
                section.reading(page: min(max(block, 1), pageSizes.count))
            }
            .onChange(of: section.pendingPage) { _, page in scroll(to: page) }
        }
        .foregroundStyle(theme.ink.color)
        .task(id: "\(notebook.id)|\(version)|\(notebook.transcribedHash ?? "")") { await load() }
    }

    private func scroll(to page: Int?, animated: Bool = true) {
        guard let page, !pageSizes.isEmpty else { return }
        guard pageSizes.indices.contains(page - 1) else {
            // The notebook has shrunk since: nothing to wait for.
            section.pendingPage = nil
            return
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { position = page }
        } else {
            position = page
        }
    }

    private static let topID = 0, endID = Int.max

    /// A small round button in the page's corner: to the last page of a long
    /// notebook, and back to the top from there.
    private var jumpButton: some View {
        let toTop = nearEnd
        return Button {
            withAnimation(.easeInOut(duration: 0.35)) { position = toTop ? Self.topID : Self.endID }
        } label: {
            Image(systemName: toTop ? "arrow.up.to.line" : "arrow.down.to.line")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.ink.color.opacity(0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(theme.page.paperColor.color.opacity(0.9))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1))
                .overlay(Circle().stroke(theme.ink.color.opacity(0.12), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(toTop ? "Back to the first page (⌘↑)" : "Skip to the last page (⌘↓)")
        .keyboardShortcut(toTop ? .upArrow : .downArrow, modifiers: .command)
        .padding(.trailing, 14).padding(.bottom, 14)
        .transition(.opacity)
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
        let page = transcriptPages[number]
        return VStack(alignment: .leading, spacing: pitch / 2) {
            Text("PAGE \(number)")
                .font(.system(size: 10 * scale, weight: .semibold, design: .serif)).tracking(1)
                .foregroundStyle(theme.dimInk.color)
                .padding(.top, pitch)
            PageFacsimile(renderer: section.renderer, id: notebook.id, url: pdfURL, version: version, page: index,
                          pdfReady: pdfReady, width: width, aspect: size.height / max(1, size.width))
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
        let version = self.version
        let renderer = section.renderer
        pdfReady = false
        await renderer.release(except: notebook.id)
        // Pages drawn before come from the cache, whether or not iCloud has
        // evicted the PDF since.
        if let sizes = await renderer.cachedPageSizes(id: notebook.id, version: version) { pageSizes = sizes }
        // A coordinated read on iCloud Drive can wait seconds for the file
        // provider, so it must not run on the main actor.
        let transcriptURL = section.transcriptURL(for: notebook)
        let transcript = Task.detached(priority: .userInitiated) {
            (try? FileIO.read(transcriptURL)).map { ScribeTranscript.parse(String(decoding: $0, as: UTF8.self)) }
        }
        // Opening an evicted PDF blocks until it has downloaded, and would hold
        // up the renderer meanwhile, so wait for the download here instead.
        if ICloudPlaceholders.needsDownload(pdf) {
            isPlaceholder = true
            ICloudPlaceholders.startDownload(pdf)
            // Nothing in the task id changes when the download lands, so wait
            // for it here; leaving the notebook cancels the wait.
            while ICloudPlaceholders.needsDownload(pdf) {
                if parsed == nil, let read = await transcript.value { show(read) }
                try? await Task.sleep(for: .milliseconds(250))
                if Task.isCancelled { return }
            }
            isPlaceholder = false
        }
        pdfReady = true
        pageSizes = await renderer.pageSizes(id: notebook.id, url: pdf, version: version)
        show(await transcript.value)
        // Everything is laid out: open where the notebook was left (or where a
        // search hit points), straight there without animation.
        scroll(to: section.pendingPage, animated: false)
    }

    private func show(_ read: ScribeTranscript.Parsed?) {
        parsed = read
        transcriptPages = Dictionary((read?.pages ?? []).map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

/// The page image, drawn while the cell is on screen and dropped when it
/// scrolls off (the renderer keeps it in its cache); its space is reserved from
/// the PDF's page size so the stack never jumps. The bitmap is drawn at the
/// width rounded up to a 50 pt step and scaled down to fit, so resizing the
/// window does not draw and cache a bitmap at every width it passes through.
struct PageFacsimile: View {
    let renderer: ScribePageRenderer
    let id: String
    let url: URL
    let version: String
    let page: Int
    let pdfReady: Bool
    let width: CGFloat
    let aspect: CGFloat
    @State private var image: NSImage?
    @State private var isVisible = false
    static let widthStep: CGFloat = 50

    private var renderWidth: CGFloat { (width / Self.widthStep).rounded(.up) * Self.widthStep }

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
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .task(id: "\(id)|\(version)|\(page)|\(Int(renderWidth))|\(pdfReady)|\(isVisible)") {
            guard isVisible else { image = nil; return }
            let backing = NSScreen.main?.backingScaleFactor ?? 2
            if let cached = await renderer.cachedImage(id: id, version: version, page: page, width: renderWidth, backingScale: backing) {
                image = cached.image
            } else if pdfReady {
                image = await renderer.image(id: id, url: url, version: version, page: page, width: renderWidth, backingScale: backing)?.image
            }
        }
    }
}
