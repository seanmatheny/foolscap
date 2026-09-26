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
    let tabs: [NotebookTabItem]
    @Binding var selection: String
    let page: (String) -> Page

    public init(tabs: [NotebookTabItem], selection: Binding<String>, @ViewBuilder page: @escaping (String) -> Page) {
        self.tabs = tabs; self._selection = selection; self.page = page
    }

    public var body: some View {
        let windowState = WindowState.shared
        let tabsLeft = tabEdge == .left
        CoverBlock {
            ZStack(alignment: tabsLeft ? .topLeading : .topTrailing) {
                // The facing page runs from under the page's inner edge to the window edge.
                FacingPageView(foldOnLeft: tabsLeft)
                    .frame(width: NotebookMetrics.facingWidth + 12)
                    .padding(.top, NotebookMetrics.topMargin)
                    .padding(.bottom, NotebookMetrics.bottomMargin)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tabsLeft ? .topTrailing : .topLeading)
                PageView { page(selection) }
                    .shadow(color: .black.opacity(0.35), radius: 3, x: tabsLeft ? -2 : 2, y: 0)
                    // Index tabs are glued to the page edge, behind it, sticking out sideways.
                    .background(alignment: tabsLeft ? .topLeading : .topTrailing) {
                        IndexTabsView(tabs: tabs, selection: $selection)
                            .padding(.top, 22)
                            .offset(x: tabsLeft ? -PaperTab.width : PaperTab.width)
                    }
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
                // Leather band above the page: reveals the traffic lights and drags the window.
                TrafficLightHoverZone()
                    .frame(height: NotebookMetrics.topMargin)
                    .frame(maxWidth: .infinity)
                    .gesture(WindowDragGesture())
            }
            // In full screen on a notched display the cover runs under the camera housing;
            // the page stays below it.
            .padding(.top, windowState.fullScreenTopInset)
        }
        .background(NotebookWindowChrome(shapeVersion: "\(selection)-\(tabEdge.rawValue)", coverColor: theme.cover.baseColor.nsColor))
        .ignoresSafeArea()
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
        let inset: CGFloat = 7
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
        LinearGradient(stops: [.init(color: .black.opacity(0.0), location: 0),
                               .init(color: .black.opacity(0.35), location: 0.35),
                               .init(color: .black.opacity(0.5), location: 0.5),
                               .init(color: .white.opacity(0.12), location: 0.7),
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
            TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity, blend: theme.page.textureBlend)
            // Shade deepening into the fold.
            LinearGradient(stops: [.init(color: .black.opacity(0.38), location: 0),
                                   .init(color: .black.opacity(0.14), location: 0.45),
                                   .init(color: .clear, location: 1)],
                           startPoint: foldOnLeft ? .leading : .trailing, endPoint: foldOnLeft ? .trailing : .leading)
            // The page's top and bottom edges throw a little shadow on the leather beside them.
            VStack {
                LinearGradient(colors: [.black.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom).frame(height: 6)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.22)], startPoint: .top, endPoint: .bottom).frame(height: 6)
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
    var body: some View {
        LinearGradient(stops: [.init(color: .clear, location: 0),
                               .init(color: .black.opacity(0.30), location: 0.42),
                               .init(color: .black.opacity(0.62), location: 0.5),
                               .init(color: .black.opacity(0.26), location: 0.58),
                               .init(color: .clear, location: 1)],
                       startPoint: .leading, endPoint: .trailing)
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
            // highlight so it separates from dark leather.
            .overlay(LinearGradient(colors: [.white.opacity(0.24), .clear, .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
            .overlay(Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .frame(width: 11)
            .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 0)
            .allowsHitTesting(false)
    }
}

struct IndexTabsView: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge
    let tabs: [NotebookTabItem]
    @Binding var selection: String

    var body: some View {
        // Every tab is as long as the longest label, so the row reads as one set.
        let length = tabs.map { PaperTab.length(for: $0.appearance) }.max() ?? PaperTab.length(for: TabAppearance(label: "Tasks"))
        VStack(alignment: tabEdge == .left ? .leading : .trailing, spacing: 10) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PaperTab(appearance: tab.appearance,
                         color: theme.tabColor(at: tab.appearance.colorIndex ?? index),
                         isSelected: tab.id == selection,
                         index: index,
                         length: length)
                    .onTapGesture { selection = tab.id }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(tab.appearance.label)
            }
            Spacer()
        }
    }
}
