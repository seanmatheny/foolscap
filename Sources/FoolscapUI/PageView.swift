import SwiftUI
import FoolscapCore

/// Draws the ruling on the paper. Line pitch matches the editor's line height.
public struct RulingView: View {
    @Environment(\.notebookTheme) private var theme
    public var pitch: CGFloat
    public var topInset: CGFloat
    public var marginX: CGFloat

    public init(pitch: CGFloat = 26, topInset: CGFloat = 60, marginX: CGFloat = 64) {
        self.pitch = pitch; self.topInset = topInset; self.marginX = marginX
    }

    public var body: some View {
        Canvas { ctx, size in
            let rule = theme.page.ruleColor.color
            switch theme.page.ruling {
            case .blank: break
            case .lined:
                var y = topInset
                while y < size.height {
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(rule), lineWidth: 0.8)
                    y += pitch
                }
            case .grid:
                var y = topInset.truncatingRemainder(dividingBy: pitch)
                while y < size.height {
                    var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(p, with: .color(rule), lineWidth: 0.5); y += pitch
                }
                var x = marginX.truncatingRemainder(dividingBy: pitch)
                while x < size.width {
                    var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(p, with: .color(rule), lineWidth: 0.5); x += pitch
                }
            case .dotted:
                var y = topInset
                while y < size.height {
                    var x = marginX.truncatingRemainder(dividingBy: pitch)
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(rule))
                        x += pitch
                    }
                    y += pitch
                }
            }
            if theme.page.marginRule {
                var p = Path(); p.move(to: CGPoint(x: marginX - 14, y: 0)); p.addLine(to: CGPoint(x: marginX - 14, y: size.height))
                ctx.stroke(p, with: .color(theme.page.marginRuleColor.color), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// One paper page: paper colour, texture, ruling, and the section's content on top.
public struct PageView<Content: View>: View {
    @Environment(\.notebookTheme) private var theme
    let content: Content
    public var showRuling: Bool

    public init(showRuling: Bool = true, @ViewBuilder content: () -> Content) {
        self.showRuling = showRuling
        self.content = content()
    }

    public var body: some View {
        ZStack {
            theme.page.paperColor.color
            TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity)
            if showRuling { RulingView() }
            // Inner shadow along the spine side
            LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.15), lineWidth: 0.5))
    }
}
