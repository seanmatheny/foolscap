import SwiftUI
import FoolscapCore

/// An index tab glued to the page edge, sticking out sideways with its label
/// running top to bottom. Rounded on the free edge, square where it meets the page.
struct SideTabShape: Shape {
    func path(in r: CGRect) -> Path {
        let c: CGFloat = min(7, r.width / 2.5)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY + 1))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c + 1), control: CGPoint(x: r.maxX, y: r.minY + 1))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c - 1))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY - 1), control: CGPoint(x: r.maxX, y: r.maxY - 1))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

public struct PaperTab: View {
    let appearance: TabAppearance
    let color: RGBA
    let isSelected: Bool
    let index: Int
    @State private var hovering = false

    public init(appearance: TabAppearance, color: RGBA, isSelected: Bool, index: Int) {
        self.appearance = appearance; self.color = color; self.isSelected = isSelected; self.index = index
    }

    /// Visible width of the tab beyond the page edge.
    static let width: CGFloat = 30
    /// How far the tab reaches under the page.
    static let root: CGFloat = 10

    private var length: CGFloat { CGFloat(appearance.label.count) * 7.2 + 44 }

    public var body: some View {
        ZStack {
            SideTabShape().fill(color.color)
            SideTabShape().fill(LinearGradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.10)], startPoint: .leading, endPoint: .trailing))
            TextureOverlay(tile: "paper", opacity: 0.5).mask(SideTabShape())
            SideTabShape().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
            HStack(spacing: 5) {
                if let s = appearance.systemImage { Image(systemName: s).font(.system(size: 10, weight: .semibold)) }
                Text(appearance.label).font(.system(size: 11.5, weight: .semibold, design: .serif)).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(Color.black.opacity(0.72))
            .rotationEffect(.degrees(90))
            // Rotation does not change the layout footprint: collapse it so the
            // label's unrotated width cannot widen (and shift) the tab.
            .frame(width: 1, height: 1)
            .offset(x: Self.root / 2)
        }
        .frame(width: Self.width + Self.root, height: length)
        .offset(x: isSelected ? 0 : (hovering ? -1.5 : -4))
        .opacity(isSelected ? 1 : 0.86)
        .shadow(color: .black.opacity(isSelected ? 0.35 : 0.2), radius: isSelected ? 3 : 1.5, x: 1.5, y: 1)
        .contentShape(SideTabShape())
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.22), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
