import SwiftUI
import FoolscapCore

/// What the notebook chrome needs to know about a section to draw its tab.
public struct NotebookTabItem: Identifiable, Hashable {
    public var id: String
    public var appearance: TabAppearance
    public init(id: String, appearance: TabAppearance) { self.id = id; self.appearance = appearance }
}

/// Which side of the page the index tabs stick out of. The spine is on the
/// other side, so `.left` shows the notebook from the other cover.
public enum TabEdge: String, CaseIterable, Sendable {
    case left, right

    public var title: String { self == .left ? "Left" : "Right" }
}

private struct TabEdgeKey: EnvironmentKey { static let defaultValue: TabEdge = .left }
private struct ElasticBandKey: EnvironmentKey { static let defaultValue = false }

public extension EnvironmentValues {
    /// Set by the app from Settings; every piece of chrome reads it.
    var notebookTabEdge: TabEdge {
        get { self[TabEdgeKey.self] }
        set { self[TabEdgeKey.self] = newValue }
    }
    /// Whether the elastic closure band is drawn over the cover.
    var showsElasticBand: Bool {
        get { self[ElasticBandKey.self] }
        set { self[ElasticBandKey.self] = newValue }
    }
}

/// Cover geometry shared by the views below.
enum NotebookMetrics {
    static let spineRadius: CGFloat = 6      // the bound edge is nearly square
    static let edgeRadius: CGFloat = 16      // the opening edge is rounded
    static let topMargin: CGFloat = 30       // leather above the page; hosts the traffic lights
    static let sideMargin: CGFloat = 50      // leather beside the page on the tab side: hosts the index tabs
    static let bottomMargin: CGFloat = 20
    /// Beyond the page's inner edge: the fold, then this much of the facing
    /// page before the window ends. Nothing sits further in on that side.
    static let facingWidth: CGFloat = 40
    /// Stitching runs this far inside the cover's edge.
    static let stitchInset: CGFloat = 7
    /// The first index tab starts this far below the page's top.
    static let firstTabOffset: CGFloat = 22
    /// The jester stamped in the leather's corner on the tabs' side.
    static let stampSize: CGFloat = 32
    /// Its centre, from the window's top and its tab-side edge: halfway between the
    /// stitching and the page across, and between the stitching and the first tab down.
    static let stampCentre = CGPoint(x: (stitchInset + sideMargin) / 2, y: (stitchInset + topMargin + firstTabOffset) / 2)

    /// Where the page sits inside the cover: the tabs on one side, the fold
    /// and the facing page on the other. Shared with the overlays laid on it.
    static func pageInsets(tabsLeft: Bool) -> EdgeInsets {
        EdgeInsets(top: topMargin, leading: tabsLeft ? sideMargin : facingWidth,
                   bottom: bottomMargin, trailing: tabsLeft ? facingWidth : sideMargin)
    }
}

/// The whole notebook: leather cover, page block, index tabs and elastic band.
/// It is designed to fill a transparent window edge to edge, so nothing is
/// drawn outside the cover and the tabs.
public struct NotebookView<Page: View>: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge
    @Environment(\.showsElasticBand) private var showsBand
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tabs: [NotebookTabItem]
    @Binding var selection: String
    let page: (String) -> Page
    /// Whether a loose leaf (the flyleaf) lies on the page. A tab click then
    /// photographs the leaf with the page and turns it away, even when the tab
    /// is the one the notebook is already open at.
    let looseLeaf: Binding<Bool>?
    /// The page the notebook lies open at; `selection` only ever reaches it
    /// through `turnPage`, so the live page is never swapped before it has
    /// been photographed.
    @State private var shown: String?
    @State private var anchor = PageAnchor()
    /// A photograph taken as a tab was clicked, before the selection changed,
    /// and where along the page's edge the click was (0 at the top).
    @State private var pendingShot: (id: String, image: CGImage, size: CGSize, edge: CGFloat)?

    public init(tabs: [NotebookTabItem], selection: Binding<String>, looseLeaf: Binding<Bool>? = nil,
                @ViewBuilder page: @escaping (String) -> Page) {
        self.tabs = tabs; self._selection = selection; self.looseLeaf = looseLeaf; self.page = page
    }

    public var body: some View {
        let tabsLeft = tabEdge == .left
        let open = shown ?? selection
        CoverBlock {
            ZStack(alignment: tabsLeft ? .topLeading : .topTrailing) {
                // The facing page runs from under the page's inner edge to the window edge.
                FacingPageView(foldOnLeft: tabsLeft)
                    .frame(width: NotebookMetrics.facingWidth + 12)
                    .padding(.top, NotebookMetrics.topMargin)
                    .padding(.bottom, NotebookMetrics.bottomMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tabsLeft ? .topTrailing : .topLeading)
                PageView { page(open) }
                    // The drop shadow belongs to a plain shape behind the page: on the page
                    // itself it would put every photograph of the page through a blur.
                    .background {
                        if theme.flat {
                            PageShape(spineOnRight: tabsLeft).fill(theme.page.paperColor.color)
                        } else {
                            PageShape(spineOnRight: tabsLeft).fill(theme.page.paperColor.color)
                                .shadow(color: .black.opacity(0.25), radius: 3, x: tabsLeft ? -2 : 2, y: 0)
                        }
                    }
                    .overlay { PageSnapshotHost(anchor: anchor) }
                    // Index tabs are glued to the page edge, behind it, sticking out sideways.
                    .background(alignment: tabsLeft ? .topLeading : .topTrailing) {
                        IndexTabsView(tabs: tabs, selection: $selection) { id, edge in
                            // Photograph the page before the selection changes anything
                            // (a leaf lying on it is in the photograph too).
                            let leaf = looseLeaf?.wrappedValue == true
                            if id != open || leaf, let shot = anchor.capture() { pendingShot = (open, shot.image, shot.size, edge) }
                            if leaf { looseLeaf?.wrappedValue = false }
                            if id == open {
                                // Nothing to turn to: the leaf alone turns away, revealing this page.
                                if leaf, let shot = pendingShot { curl(shot.image, edge: shot.edge) }
                                pendingShot = nil
                            } else {
                                selection = id
                            }
                        }
                        .padding(.top, NotebookMetrics.firstTabOffset)
                        .offset(x: tabsLeft ? -PaperTab.width : PaperTab.width)
                    }
                    .coordinateSpace(.named("page"))
                    .padding(NotebookMetrics.pageInsets(tabsLeft: tabsLeft))
                // The fold: both pages curve down into the spine.
                FoldShadow()
                    .frame(width: 44)
                    .padding(.top, NotebookMetrics.topMargin)
                    .padding(.bottom, NotebookMetrics.bottomMargin)
                    .padding(tabsLeft ? .trailing : .leading, NotebookMetrics.facingWidth - 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tabsLeft ? .topTrailing : .topLeading)
                // The band wraps the cover beyond the tabs, so it never crosses the page.
                if showsBand {
                    ElasticBandView()
                        .padding(tabsLeft ? .leading : .trailing, 6)
                }
                // The cover's jester, stamped in the leather's corner on the tabs' side,
                // centred between the page, the first tab and the stitching. With the tabs
                // on the left that corner is the window buttons', so it steps aside for them.
                if !theme.flat {
                    CoverStamp(tabsLeft: tabsLeft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tabsLeft ? .topLeading : .topTrailing)
                }
                // Leather band above the page: reveals the traffic lights and drags the window.
                TrafficLightHoverZone()
                    .frame(height: NotebookMetrics.topMargin)
                    .frame(maxWidth: .infinity)
                    .gesture(WindowDragGesture())
            }
            // In full screen on a notched display the cover runs under the camera housing;
            // the page stays below it.
            .modifier(FullScreenTopInset())
        }
        .background(NotebookWindowChrome(shapeVersion: "\(selection)-\(tabEdge.rawValue)", coverColor: theme.cover.baseColor.nsColor))
        .ignoresSafeArea()
        .onAppear {
            if shown == nil { shown = selection }
            PageCurlRenderer.warmUp()
        }
        .onChange(of: selection) { old, new in turnPage(from: old, to: new) }
    }

    /// The page being read curls away over the spine, whichever way through
    /// the tabs the new one lies, while the new page takes its place beneath.
    /// The curl runs in a window of its own on a thread of its own, so it
    /// starts with the click and carries on while the new page is built.
    private func turnPage(from old: String, to new: String) {
        guard old != new else { return }
        let shot = pendingShot.flatMap { $0.id == old ? $0 : nil }
        pendingShot = nil
        let clicked = CACurrentMediaTime()
        defer {
            shown = new
            if pageTurnLogging { NSLog("Foolscap turn: main thread %.1f ms before the page swap", (CACurrentMediaTime() - clicked) * 1000) }
        }
        // Without a photograph or a curl to draw (the shader still compiling) the page just changes.
        guard let image = shot?.image ?? anchor.capture()?.image else { return }
        curl(image, edge: shot?.edge)
    }

    /// Curl `image`, a photograph of the page, away over the spine.
    private func curl(_ image: CGImage, edge: CGFloat?) {
        guard !reduceMotion else { return }
        let slow = ProcessInfo.processInfo.environment["FOOLSCAP_SLOW_OPEN"] != nil ? 4.0 : 1.0
        _ = anchor.curl(image, style: PageCurlStyle.random(from: edge), spineOnRight: tabEdge == .left,
                        paper: theme.page.paperColor, duration: 0.55 * slow)
    }
}

/// The jester stamped in the leather. It, and not the notebook, watches the window
/// state: a hover over the leather band (the drag handle) flips `trafficLightsShown`,
/// and that must not re-evaluate the whole notebook down to the editor.
struct CoverStamp: View {
    let tabsLeft: Bool
    var body: some View {
        let shown = WindowState.shared.trafficLightsShown
        Embossed(depth: 0.8) { JesterShape() }
            .frame(width: NotebookMetrics.stampSize, height: NotebookMetrics.stampSize)
            .padding(.top, NotebookMetrics.stampCentre.y - NotebookMetrics.stampSize / 2)
            .padding(tabsLeft ? .leading : .trailing, NotebookMetrics.stampCentre.x - NotebookMetrics.stampSize / 2)
            .opacity(tabsLeft && shown ? 0 : 1)
            .animation(.easeInOut(duration: 0.18), value: shown)
            .allowsHitTesting(false)
    }
}

/// The full-screen inset, read here rather than in the notebook's body for the same reason.
struct FullScreenTopInset: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.top, WindowState.shared.fullScreenTopInset)
    }
}

/// The cover outline: nearly square on the spine, rounded on the opening edge.
/// Square all round while full screen, where the window fills the display.
/// `spineOnRight` mirrors it for the tabs-on-the-left layout.
struct CoverShape: Shape {
    var square = false
    var spineOnRight = false
    func path(in r: CGRect) -> Path {
        if square { return Path(r) }
        // The fold side is cut by the window mid-page, so the cover is square there.
        let s: CGFloat = 0, e = NotebookMetrics.edgeRadius
        // Radii per corner: top-left, top-right, bottom-right, bottom-left.
        let (tl, tr, br, bl) = spineOnRight ? (e, s, s, e) : (s, e, e, s)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The leather cover with stitching and a spine highlight.
struct CoverBlock<Content: View>: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge
    @ViewBuilder let content: Content

    var body: some View {
        let square = WindowState.shared.isFullScreen
        let mirrored = tabEdge == .left
        let shape = CoverShape(square: square, spineOnRight: mirrored)
        ZStack {
            shape.fill(theme.cover.baseColor.color)
            // A flat cover is the colour alone: no grain, light, stitching or ridge.
            if !theme.flat {
                TextureOverlay(tile: theme.cover.textureTile, opacity: theme.cover.grainOpacity, blend: theme.cover.blend)
                // Light from the top-left, and a worn sheen along the edges.
                shape.fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.22)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                // Stitching just inside the edge: along the top, the opening edge and the
                // bottom, running off the fold side where the cover continues past the window.
                CoverStitches(square: square, spineOnRight: mirrored)
                    .stroke(theme.cover.stitchColor.color.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                // The spine: a ridge in the leather where it folds, in line with the pages' fold.
                SpineRidge()
                    .frame(width: 10)
                    .padding(mirrored ? .trailing : .leading, NotebookMetrics.facingWidth - 5)
                    .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
                // Edge highlight so the cover reads as thick.
                shape.stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            content
        }
        .clipShape(shape)
    }
}

/// The stitch line: an open path 7 pt inside the top, opening and bottom edges.
struct CoverStitches: Shape {
    var square = false
    var spineOnRight = false
    func path(in r: CGRect) -> Path {
        let inset = NotebookMetrics.stitchInset
        let box = r.insetBy(dx: inset, dy: inset)
        let e = square ? 0 : NotebookMetrics.edgeRadius - inset
        var p = Path()
        if spineOnRight {
            // Fold on the right: start at the right edge, run left along the top, down the left, back right.
            p.move(to: CGPoint(x: r.maxX, y: box.minY))
            p.addLine(to: CGPoint(x: box.minX + e, y: box.minY))
            if e > 0 { p.addArc(center: CGPoint(x: box.minX + e, y: box.minY + e), radius: e, startAngle: .degrees(-90), endAngle: .degrees(-180), clockwise: true) }
            p.addLine(to: CGPoint(x: box.minX, y: box.maxY - e))
            if e > 0 { p.addArc(center: CGPoint(x: box.minX + e, y: box.maxY - e), radius: e, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true) }
            p.addLine(to: CGPoint(x: r.maxX, y: box.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: box.minY))
            p.addLine(to: CGPoint(x: box.maxX - e, y: box.minY))
            if e > 0 { p.addArc(center: CGPoint(x: box.maxX - e, y: box.minY + e), radius: e, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
            p.addLine(to: CGPoint(x: box.maxX, y: box.maxY - e))
            if e > 0 { p.addArc(center: CGPoint(x: box.maxX - e, y: box.maxY - e), radius: e, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
            p.addLine(to: CGPoint(x: r.minX, y: box.maxY))
        }
        return p
    }
}

/// The leather folding over the spine: a shaded groove with a lit edge.
struct SpineRidge: View {
    var body: some View {
        // Kept faint: a crease the eye passes over, not a line it stops at.
        LinearGradient(stops: [.init(color: .black.opacity(0.0), location: 0),
                               .init(color: .black.opacity(0.14), location: 0.35),
                               .init(color: .black.opacity(0.22), location: 0.5),
                               .init(color: .white.opacity(0.06), location: 0.7),
                               .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
            .allowsHitTesting(false)
    }
}

extension CoverShape: InsettableShape {
    func inset(by amount: CGFloat) -> some InsettableShape { InsetCover(amount: amount, square: square, spineOnRight: spineOnRight) }
}

struct InsetCover: InsettableShape {
    var amount: CGFloat
    var square = false
    var spineOnRight = false
    func path(in rect: CGRect) -> Path { CoverShape(square: square, spineOnRight: spineOnRight).path(in: rect.insetBy(dx: amount, dy: amount)) }
    func inset(by extra: CGFloat) -> InsetCover { InsetCover(amount: amount + extra, square: square, spineOnRight: spineOnRight) }
}

/// The edge of the page opposite the one being read: paper curving up out of
/// the fold and off the window's edge, so the window reads as an open book.
struct FacingPageView: View {
    @Environment(\.notebookTheme) private var theme
    /// Whether the fold is on this strip's left (the tabs, and the page, are to the left).
    let foldOnLeft: Bool

    var body: some View {
        ZStack {
            theme.page.paperColor.color
            if !theme.flat {
                TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity, blend: theme.page.textureBlend)
                // Shade deepening into the fold.
                LinearGradient(stops: [.init(color: .black.opacity(0.22), location: 0),
                                       .init(color: .black.opacity(0.08), location: 0.45),
                                       .init(color: .clear, location: 1)],
                               startPoint: foldOnLeft ? .leading : .trailing, endPoint: foldOnLeft ? .trailing : .leading)
                // The page's top and bottom edges throw a little shadow on the leather beside them.
                VStack {
                    LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom).frame(height: 6)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .top, endPoint: .bottom).frame(height: 6)
                }
            }
        }
        // No `.shadow` here: it would render the strip offscreen and flatten the texture's blend.
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.28)).frame(height: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.28)).frame(height: 0.5) }
        .allowsHitTesting(false)
    }
}

/// The dark line of the fold between the two pages.
struct FoldShadow: View {
    @Environment(\.notebookTheme) private var theme
    var body: some View {
        Group {
            if theme.flat {
                // A hairline where the two pages meet.
                Color.clear.overlay { Rectangle().fill(theme.ink.color.opacity(0.18)).frame(width: 1) }
            } else {
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black.opacity(0.14), location: 0.42),
                                       .init(color: .black.opacity(0.32), location: 0.5),
                                       .init(color: .black.opacity(0.12), location: 0.58),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The elastic closure band, in the leather's own colour, darkened.
struct ElasticBandView: View {
    @Environment(\.notebookTheme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.cover.bandColor.color)
            // A rounded elastic: lit on one edge, shaded on the other, with a fine
            // highlight so it separates from dark leather. Flat covers get the strip alone.
            .overlay(LinearGradient(colors: [.white.opacity(theme.flat ? 0 : 0.24), .clear, .black.opacity(theme.flat ? 0 : 0.35)],
                                    startPoint: .leading, endPoint: .trailing))
            .overlay(Rectangle().stroke(Color.white.opacity(theme.flat ? 0 : 0.14), lineWidth: 0.5))
            .frame(width: 11)
            .shadow(color: .black.opacity(theme.flat ? 0 : 0.5), radius: 3, x: 1, y: 0)
            .allowsHitTesting(false)
    }
}

struct IndexTabsView: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge
    let tabs: [NotebookTabItem]
    @Binding var selection: String
    /// A click on a tab: its id and how far down the page's edge it was (0 at
    /// the top, 1 at the bottom); the page curls from that end.
    var select: (String, CGFloat) -> Void

    var body: some View {
        // Every tab is as long as the longest label, so the row reads as one set;
        // when the page is too short for them all, every tab shrinks to its icon.
        let fit = PaperTab.length(for: tabs.map(\.appearance), available: pageHeight - NotebookMetrics.firstTabOffset)
        VStack(alignment: tabEdge == .left ? .leading : .trailing, spacing: PaperTab.spacing) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PaperTab(appearance: tab.appearance,
                         color: theme.tabColor(at: tab.appearance.colorIndex ?? index),
                         isSelected: tab.id == selection,
                         index: index,
                         length: fit.length,
                         compact: fit.compact)
                    .onTapGesture(coordinateSpace: .named("page")) { location in
                        select(tab.id, location.y / max(1, pageHeight))
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(tab.appearance.label)
            }
            Spacer()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.bounds(of: .named("page"))?.height ?? 0 } action: { pageHeight = $0 }
        .animation(.easeOut(duration: 0.18), value: fit.compact)
    }

    @State private var pageHeight: CGFloat = 0
}
