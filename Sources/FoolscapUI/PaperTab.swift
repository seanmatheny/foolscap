import SwiftUI
import FoolscapCore

/// A paper index tab sticking out of the page edge.
struct PaperTabShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c: CGFloat = min(8, r.height / 4)
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY + 2))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + c + 2), control: CGPoint(x: r.maxX, y: r.minY + 2))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c - 2))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c, y: r.maxY - 2), control: CGPoint(x: r.maxX, y: r.maxY - 2))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

public struct PaperTab: View {
    @Environment(\.notebookTheme) private var theme
    let appearance: TabAppearance
    let color: RGBA
    let isSelected: Bool
    let index: Int

    public init(appearance: TabAppearance, color: RGBA, isSelected: Bool, index: Int) {
        self.appearance = appearance; self.color = color; self.isSelected = isSelected; self.index = index
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let s = appearance.systemImage { Image(systemName: s).font(.system(size: 11, weight: .semibold)) }
            Text(appearance.label)
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(Color.black.opacity(0.72))
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(height: 36)
        .padding(.leading, NotebookMetrics.tabOverlap)
        .background(
            ZStack {
                PaperTabShape().fill(color.color)
                PaperTabShape().fill(LinearGradient(colors: [.white.opacity(0.25), .black.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                TextureOverlay(tile: "paper", opacity: 0.5).mask(PaperTabShape())
                PaperTabShape().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
            }
        )
        .rotationEffect(.degrees(isSelected ? 0 : (index.isMultiple(of: 2) ? 0.6 : -0.6)), anchor: .leading)
        .offset(x: isSelected ? 0 : -10)
        .shadow(color: .black.opacity(isSelected ? 0.4 : 0.25), radius: isSelected ? 4 : 2, x: 1, y: 2)
        .zIndex(isSelected ? 10 : 0)
        .contentShape(Rectangle())
        .animation(.spring(duration: 0.25), value: isSelected)
    }
}
