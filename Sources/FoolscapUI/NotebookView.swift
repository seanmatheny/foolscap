import SwiftUI
import FoolscapCore

/// What the notebook chrome needs to know about a section to draw its tab.
public struct NotebookTabItem: Identifiable, Hashable {
    public var id: String
    public var appearance: TabAppearance
    public init(id: String, appearance: TabAppearance) { self.id = id; self.appearance = appearance }
}

/// Cover geometry shared by the views below.
enum NotebookMetrics {
    static let spineRadius: CGFloat = 6      // the bound edge is nearly square
    static let edgeRadius: CGFloat = 16      // the opening edge is rounded
    static let topMargin: CGFloat = 30       // leather above the page; hosts the traffic lights
    static let sideMargin: CGFloat = 50      // leather to the right of the page: hosts the index tabs
    static let bottomMargin: CGFloat = 20
    static let spineMargin: CGFloat = 30
}

/// The whole notebook: leather cover, page block, index tabs and elastic band.
/// It is designed to fill a transparent window edge to edge, so nothing is
/// drawn outside the cover and the tabs.
public struct NotebookView<Page: View>: View {
    @Environment(\.notebookTheme) private var theme
    let tabs: [NotebookTabItem]
    @Binding var selection: String
    let page: (String) -> Page

    public init(tabs: [NotebookTabItem], selection: Binding<String>, @ViewBuilder page: @escaping (String) -> Page) {
        self.tabs = tabs; self._selection = selection; self.page = page
    }

    public var body: some View {
        CoverBlock {
            ZStack(alignment: .topTrailing) {
                PageView { page(selection) }
                    .shadow(color: .black.opacity(0.35), radius: 3, x: 2, y: 0)
                    // Index tabs are glued to the page edge, behind it, sticking out to the right.
                    .background(alignment: .topTrailing) {
                        IndexTabsView(tabs: tabs, selection: $selection)
                            .padding(.top, 22)
                            .offset(x: PaperTab.width)
                    }
                    .padding(EdgeInsets(top: NotebookMetrics.topMargin, leading: NotebookMetrics.spineMargin,
                                        bottom: NotebookMetrics.bottomMargin, trailing: NotebookMetrics.sideMargin))
                ElasticBandView()
                    .padding(.trailing, NotebookMetrics.sideMargin + 16)
                // Leather band above the page: reveals the traffic lights and drags the window.
                TrafficLightHoverZone()
                    .frame(height: NotebookMetrics.topMargin)
                    .frame(maxWidth: .infinity)
                    .gesture(WindowDragGesture())
            }
        }
        .background(NotebookWindowChrome(shapeVersion: selection))
        .ignoresSafeArea()
    }
}

/// The cover outline: nearly square on the spine, rounded on the opening edge.
struct CoverShape: Shape {
    func path(in r: CGRect) -> Path {
        let s = NotebookMetrics.spineRadius, e = NotebookMetrics.edgeRadius
        var p = Path()
        p.move(to: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - e, y: r.minY + e), radius: e, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - e))
        p.addArc(center: CGPoint(x: r.maxX - e, y: r.maxY - e), radius: e, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + s, y: r.maxY - s), radius: s, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + s))
        p.addArc(center: CGPoint(x: r.minX + s, y: r.minY + s), radius: s, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The leather cover with stitching and a spine highlight.
struct CoverBlock<Content: View>: View {
    @Environment(\.notebookTheme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            CoverShape().fill(theme.cover.baseColor.color)
            TextureOverlay(tile: theme.cover.textureTile, opacity: theme.cover.grainOpacity, blend: theme.cover.blend)
            // Light from the top-left, and a worn sheen along the edges.
            CoverShape().fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.22)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
            // Spine: the crease where the cover folds.
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                                   .init(color: .black.opacity(0.12), location: 0.5),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 26)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Stitching just inside the edge.
            CoverShape()
                .inset(by: 7)
                .stroke(theme.cover.stitchColor.color.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            // Edge highlight so the cover reads as thick.
            CoverShape().stroke(Color.white.opacity(0.10), lineWidth: 1)
            content
        }
        .clipShape(CoverShape())
    }
}

extension CoverShape: InsettableShape {
    func inset(by amount: CGFloat) -> some InsettableShape { InsetCover(amount: amount) }
}

struct InsetCover: InsettableShape {
    var amount: CGFloat
    func path(in rect: CGRect) -> Path { CoverShape().path(in: rect.insetBy(dx: amount, dy: amount)) }
    func inset(by extra: CGFloat) -> InsetCover { InsetCover(amount: amount + extra) }
}

struct ElasticBandView: View {
    @Environment(\.notebookTheme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.cover.bandColor.color)
            .overlay(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 11)
            .shadow(color: .black.opacity(0.5), radius: 3, x: 1, y: 0)
            .allowsHitTesting(false)
    }
}

struct IndexTabsView: View {
    @Environment(\.notebookTheme) private var theme
    let tabs: [NotebookTabItem]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PaperTab(appearance: tab.appearance,
                         color: theme.tabColor(at: tab.appearance.colorIndex ?? index),
                         isSelected: tab.id == selection,
                         index: index)
                    .onTapGesture { selection = tab.id }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(tab.appearance.label)
            }
            Spacer()
        }
    }
}
