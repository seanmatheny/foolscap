import SwiftUI
import FoolscapCore
import FoolscapUI

/// A manila-folder tab: rounded on top, open at the bottom where it meets
/// the divider rule.
struct FolderTabShape: Shape {
    func path(in r: CGRect) -> Path {
        let c: CGFloat = min(7, r.height / 3)
        let slant: CGFloat = 4
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + slant, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + slant + c, y: r.minY), control: CGPoint(x: r.minX + slant, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - slant - c, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - slant, y: r.minY + c), control: CGPoint(x: r.maxX - slant, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The row of top-level Kindle folders along the top of the Scribe page.
struct FolderTabRow: View {
    @Environment(\.notebookTheme) private var theme
    let tabs: [(id: String, name: String)]
    let selectedID: String?
    let select: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                    FolderTab(name: tab.name, color: theme.tabColor(at: index), isSelected: tab.id == selectedID)
                        .onTapGesture { select(tab.id) }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
            Rectangle().fill(theme.ink.color.opacity(0.22)).frame(height: 0.5)
        }
    }
}

struct FolderTab: View {
    let name: String
    let color: RGBA
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        // The label sizes the tab; the paper is a background so the tiled texture
        // cannot widen it.
        Text(name)
            .font(.system(size: 11.5, weight: .semibold, design: .serif))
            .lineLimit(1)
            .foregroundStyle(Color.black.opacity(0.72))
            .padding(.horizontal, 16)
            .frame(height: isSelected ? 24 : 21)
            .background {
                ZStack {
                    FolderTabShape().fill(color.color)
                    FolderTabShape().fill(LinearGradient(colors: [.white.opacity(0.30), .clear, .black.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    TextureOverlay(tile: "paper", opacity: 0.5).mask(FolderTabShape())
                    FolderTabShape().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                }
            }
            .opacity(isSelected ? 1 : (hovering ? 0.95 : 0.84))
            .shadow(color: .black.opacity(isSelected ? 0.22 : 0.12), radius: isSelected ? 2 : 1, y: -0.5)
            .contentShape(FolderTabShape())
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.22), value: isSelected)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
