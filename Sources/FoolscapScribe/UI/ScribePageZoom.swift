import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// The geometry of a zoomed page, kept pure so it can be tested: how big the
/// page is on screen and how wide a bitmap to ask the renderer for.
enum ScribeZoomLayout {
    /// Pinch and the buttons move between these.
    static let minZoom: CGFloat = 1, maxZoom: CGFloat = 4
    /// Bitmaps are asked for in steps this wide, so a pinch does not draw a page at
    /// every width it passes through.
    static let widthStep: CGFloat = 100
    /// Room left around the page at 1× for the caption above and the controls below.
    static let topInset: CGFloat = 44, bottomInset: CGFloat = 52, sideInset: CGFloat = 24

    /// The page at 1×: as tall as the area allows, or as wide, whichever binds.
    static func fitSize(area: CGSize, aspect: CGFloat) -> CGSize {
        let width = max(1, area.width - 2 * sideInset)
        let height = max(1, area.height - topInset - bottomInset)
        let aspect = max(0.1, aspect)
        if width * aspect <= height { return CGSize(width: width, height: (width * aspect).rounded()) }
        return CGSize(width: (height / aspect).rounded(), height: height)
    }

    static func clamp(_ zoom: CGFloat) -> CGFloat { min(maxZoom, max(minZoom, zoom)) }

    /// The display width to render at for a page shown `fitWidth × zoom` wide: the
    /// next step up, but never more pixels than the Scribe itself drew.
    static func renderWidth(fitWidth: CGFloat, zoom: CGFloat, backingScale: CGFloat) -> CGFloat {
        let wanted = (fitWidth * zoom / widthStep).rounded(.up) * widthStep
        let cap = (CGFloat(ScribePageRenderer.maxPixelWidth) / max(1, backingScale)).rounded(.down)
        return max(widthStep, min(wanted, cap))
    }
}

/// A page lifted off the spread and laid over the notebook area, as Quick Look
/// lifts a file: fitted to the height at first, pinched or stepped up to 4×, dragged
/// about when larger than the area. ← → step through the notebook; ⎋, Space or a
/// click beside the page put it back.
struct ScribePageZoom: View {
    @Environment(\.notebookTheme) private var theme
    let renderer: ScribePageRenderer
    let notebookID: String
    let title: String
    let pdfURL: URL
    let version: String
    let pageSizes: [CGSize]
    /// Captions by page number ("PAGE 3 · THU 24 JUL 2026").
    let caption: (Int) -> String
    @Binding var page: Int
    /// The spread's bitmap of the page, shown scaled up until the sharp one is drawn.
    let placeholder: NSImage?
    let dismiss: () -> Void

    @State private var zoom: CGFloat = 1
    /// The pinch under way, applied on top of `zoom` until it ends.
    @State private var pinch: CGFloat = 1
    @State private var image: NSImage?
    @State private var sharp = false

    private var aspect: CGFloat {
        guard pageSizes.indices.contains(page) else { return 4 / 3 }
        let size = pageSizes[page]
        return size.height / max(1, size.width)
    }

    var body: some View {
        GeometryReader { geo in
            let fit = ScribeZoomLayout.fitSize(area: geo.size, aspect: aspect)
            let shown = ScribeZoomLayout.clamp(zoom * pinch)
            let size = CGSize(width: (fit.width * shown).rounded(), height: (fit.height * shown).rounded())
            ZStack {
                // The notebook dims behind the lifted page.
                Color.black.opacity(0.62)
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    sheet(size: size)
                        .padding(.top, ScribeZoomLayout.topInset)
                        .padding(.bottom, ScribeZoomLayout.bottomInset)
                        .padding(.horizontal, ScribeZoomLayout.sideInset)
                        // Centred while it fits; scrollable once it does not. The scroll
                        // view takes every click, so the one beside the page is caught here.
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { dismiss() }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: geo.size.width, height: geo.size.height)
                .gesture(MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        zoom = ScribeZoomLayout.clamp(zoom * value.magnification)
                        pinch = 1
                    })
                captionBar
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                controls(pageCount: pageSizes.count)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .background {
                // Hidden buttons carry the keys: SwiftUI's key handling wants focus, and
                // nothing on the Scribe tab holds it.
                Group {
                    Button("") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("") { dismiss() }.keyboardShortcut(.space, modifiers: [])
                    Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { setZoom(zoom * 1.5) }.keyboardShortcut("=", modifiers: [])
                    Button("") { setZoom(zoom / 1.5) }.keyboardShortcut("-", modifiers: [])
                }
                .opacity(0)
            }
            .task(id: "\(page)|\(Int(ScribeZoomLayout.renderWidth(fitWidth: fit.width, zoom: zoom, backingScale: backing)))") {
                await draw(fitWidth: fit.width)
            }
        }
        .transition(.opacity)
    }

    private var backing: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    private func sheet(size: CGSize) -> some View {
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image).resizable().interpolation(sharp ? .none : .high)
            } else if !sharp {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .onTapGesture(count: 2) { setZoom(zoom > 1 ? 1 : 2) }
        // A single click on the page stays on the page (the frame around it dismisses).
        .onTapGesture { }
    }

    private var captionBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(caption(page + 1))
                .font(.system(size: 10, weight: .semibold, design: .serif)).tracking(1)
            Text(title).font(.system(size: 11.5, design: .serif)).lineLimit(1)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Put the page back (⎋)")
        }
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private func controls(pageCount: Int) -> some View {
        HStack(spacing: 6) {
            control("chevron.left", help: "Previous page (←)") { step(-1) }.disabled(page <= 0)
            Text("\(page + 1) / \(max(pageCount, page + 1))")
                .font(.system(size: 11.5, weight: .medium, design: .serif)).monospacedDigit()
                .frame(minWidth: 52)
            control("chevron.right", help: "Next page (→)") { step(1) }.disabled(page + 1 >= pageCount)
            Rectangle().fill(.white.opacity(0.25)).frame(width: 0.5, height: 14).padding(.horizontal, 4)
            control("minus.magnifyingglass", help: "Smaller (-)") { setZoom(zoom / 1.5) }.disabled(zoom <= ScribeZoomLayout.minZoom)
            Text("\(Int((zoom * 100).rounded()))%")
                .font(.system(size: 11.5, weight: .medium, design: .serif)).monospacedDigit()
                .frame(minWidth: 44)
            control("plus.magnifyingglass", help: "Larger (=)") { setZoom(zoom * 1.5) }.disabled(zoom >= ScribeZoomLayout.maxZoom)
        }
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 10).frame(height: 30)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        .padding(.bottom, 12)
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func setZoom(_ value: CGFloat) {
        withAnimation(.easeOut(duration: 0.18)) { zoom = ScribeZoomLayout.clamp(value) }
    }

    private func step(_ delta: Int) {
        let next = page + delta
        guard next >= 0, next < max(pageSizes.count, 1) else { return }
        // The sharp bitmap belongs to the page being left.
        image = nil
        sharp = false
        page = next
    }

    /// The spread's bitmap first (scaled up, soft but immediate), then the page
    /// drawn at the zoomed width.
    private func draw(fitWidth: CGFloat) async {
        if image == nil, let placeholder { image = placeholder }
        let width = ScribeZoomLayout.renderWidth(fitWidth: fitWidth, zoom: zoom, backingScale: backing)
        if let cached = await renderer.cachedImage(id: notebookID, version: version, page: page, width: width, backingScale: backing) {
            image = cached.image; sharp = true
            return
        }
        // An evicted PDF would block the renderer until iCloud brings it back; the
        // spread's bitmap stands in meanwhile.
        guard !ICloudPlaceholders.needsDownload(pdfURL) else { return }
        if let drawn = await renderer.image(id: notebookID, url: pdfURL, version: version, page: page, width: width,
                                            backingScale: backing, persist: false) {
            guard !Task.isCancelled else { return }
            image = drawn.image; sharp = true
        }
    }
}
