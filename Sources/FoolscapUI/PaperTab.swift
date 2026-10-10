import SwiftUI
import FoolscapCore

/// An index tab glued to the page edge, sticking out sideways with its label
/// running along it. Rounded on the free edge, square where it meets the page.
/// `freeEdgeOnLeft` mirrors it for tabs on the left of the page.
public struct SideTabShape: Shape {
    public var freeEdgeOnLeft = false
    public init(freeEdgeOnLeft: Bool = false) { self.freeEdgeOnLeft = freeEdgeOnLeft }
    public func path(in r: CGRect) -> Path {
        let c: CGFloat = min(7, r.width / 2.5)
        var p = Path()
        if freeEdgeOnLeft {
            p.move(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + c, y: r.minY + 1))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + c + 1), control: CGPoint(x: r.minX, y: r.minY + 1))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c - 1))
            p.addQuadCurve(to: CGPoint(x: r.minX + c, y: r.maxY - 1), control: CGPoint(x: r.minX, y: r.maxY - 1))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY + 1))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c + 1), control: CGPoint(x: r.maxX, y: r.minY + 1))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c - 1))
            p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY - 1), control: CGPoint(x: r.maxX, y: r.maxY - 1))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }
        p.closeSubpath()
        return p
    }
}

public struct PaperTab: View {
    @Environment(\.notebookTabEdge) private var tabEdge
    let appearance: TabAppearance
    let color: RGBA
    let isSelected: Bool
    let index: Int
    /// The tab's extent along the page edge (all tabs share the longest label's).
    let length: CGFloat
    /// Icon only, for a page too short to carry every label.
    let compact: Bool
    @State private var hovering = false

    public init(appearance: TabAppearance, color: RGBA, isSelected: Bool, index: Int, length: CGFloat? = nil, compact: Bool = false) {
        self.appearance = appearance; self.color = color; self.isSelected = isSelected; self.index = index
        self.compact = compact
        self.length = length ?? (compact ? PaperTab.compactLength : PaperTab.length(for: appearance))
    }

    /// Visible width of the tab beyond the page edge.
    static let width: CGFloat = 30
    /// How far the tab reaches under the page.
    static let root: CGFloat = 10
    /// Between one tab and the next along the edge.
    public static let spacing: CGFloat = 10
    /// A tab showing only its icon.
    public static let compactLength: CGFloat = 40

    /// How long a tab needs to be for its label.
    nonisolated public static func length(for appearance: TabAppearance) -> CGFloat {
        CGFloat(appearance.label.count) * 7.2 + 44 + (appearance.systemImage == nil ? 0 : 14)
    }

    /// The length every tab in a set takes: the longest label's, or, when that many
    /// would run past the page's bottom edge, the icon-only length. `available` is
    /// the page's height below the first tab; 0 (not yet measured) keeps the labels.
    nonisolated public static func length(for appearances: [TabAppearance], available: CGFloat) -> (length: CGFloat, compact: Bool) {
        let full = appearances.map { length(for: $0) }.max() ?? length(for: TabAppearance(label: "Tasks"))
        guard available > 0, !appearances.isEmpty else { return (full, false) }
        let needed = full * CGFloat(appearances.count) + spacing * CGFloat(appearances.count - 1)
        return needed > available ? (compactLength, true) : (full, false)
    }

    public var body: some View {
        let left = tabEdge == .left
        let shape = SideTabShape(freeEdgeOnLeft: left)
        // Tucked under the page when unselected: towards the page, whichever side it is on.
        let tuck: CGFloat = isSelected ? 0 : (hovering ? 1.5 : 4)
        ZStack {
            // Clipped as a group: a mask on the texture itself would flatten its blend.
            ZStack {
                shape.fill(color.color)
                shape.fill(LinearGradient(colors: left ? [.black.opacity(0.10), .clear, .white.opacity(0.28)] : [.white.opacity(0.28), .clear, .black.opacity(0.10)],
                                          startPoint: .leading, endPoint: .trailing))
                TextureOverlay(tile: "paper", opacity: 0.5)
            }
            .clipShape(shape)
            shape.stroke(Color.black.opacity(0.22), lineWidth: 0.5)
            if compact {
                // Icon only, upright; a tab with no icon shows its initial.
                Group {
                    if let s = appearance.systemImage { Image(systemName: s).font(.system(size: 12, weight: .semibold)) }
                    else { Text(String(appearance.label.prefix(1))).font(.system(size: 12.5, weight: .semibold, design: .serif)) }
                }
                .foregroundStyle(Color.black.opacity(0.72))
                .frame(width: 1, height: 1)
                .offset(x: left ? -Self.root / 2 : Self.root / 2)
            } else {
                // On the right the label reads top to bottom; on the left, bottom to top
                // (like a book spine), with the icon kept at the top either way.
                HStack(spacing: 5) {
                    if !left, let s = appearance.systemImage { Image(systemName: s).font(.system(size: 10, weight: .semibold)) }
                    Text(appearance.label).font(.system(size: 11.5, weight: .semibold, design: .serif)).lineLimit(1)
                    if left, let s = appearance.systemImage { Image(systemName: s).font(.system(size: 10, weight: .semibold)) }
                }
                .fixedSize()
                .foregroundStyle(Color.black.opacity(0.72))
                .rotationEffect(.degrees(left ? -90 : 90))
                // Rotation does not change the layout footprint: collapse it so the
                // label's unrotated width cannot widen (and shift) the tab.
                .frame(width: 1, height: 1)
                .offset(x: left ? -Self.root / 2 : Self.root / 2)
            }
        }
        .frame(width: Self.width + Self.root, height: length)
        .offset(x: left ? tuck : -tuck)
        .opacity(isSelected ? 1 : 0.86)
        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.2), radius: isSelected ? 3 : 1.5, x: left ? -1.5 : 1.5, y: 1)
        .contentShape(shape)
        .help(compact ? appearance.label : "")
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.22), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
