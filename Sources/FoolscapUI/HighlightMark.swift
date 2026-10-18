import SwiftUI
import FoolscapCore

/// A highlighter-pen stroke behind text: slightly tilted, feathered at the
/// end, multiplied into the paper.
public struct HighlightMark: View {
    let color: RGBA
    /// On a black page a multiplied stroke vanishes, so dark themes screen it on instead.
    let isDark: Bool
    public init(color: RGBA, isDark: Bool = false) { self.color = color; self.isDark = isDark }

    public var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(stops: [.init(color: color.color, location: 0),
                                             .init(color: color.color, location: 0.9),
                                             .init(color: color.color.opacity(0.15), location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width + 8, height: geo.size.height * 0.78)
                .rotationEffect(.degrees(-0.6))
                .offset(x: -4, y: geo.size.height * 0.12)
                .blendMode(isDark ? .screen : .multiply)
        }
        .allowsHitTesting(false)
    }
}

/// `.highlighted` reads the theme for the blend, so plug-in views need not pass it.
private struct Highlighted: ViewModifier {
    @Environment(\.notebookTheme) private var theme
    let color: RGBA?
    func body(content: Content) -> some View {
        content.background {
            if let color, color.a > 0 { HighlightMark(color: color, isDark: theme.isDark) }
        }
    }
}

public extension View {
    /// Highlight the view like a marker pen, when `color` is visible.
    func highlighted(_ color: RGBA?) -> some View { modifier(Highlighted(color: color)) }

    /// Ring a list the way the daily page rings its Today tasks: a dashed line
    /// around a faint wash of `tint`. The ring is drawn around the view, not laid
    /// out, so rows inside keep to the ruling; `pitch` sets how round it is.
    func ringed(_ tint: RGBA, pitch: CGFloat, isDark: Bool) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: pitch * 0.75, style: .continuous)
            shape.fill(tint.color.opacity(isDark ? 0.10 : 0.14))
                .overlay(shape.strokeBorder(tint.color.opacity(isDark ? 0.55 : 0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .padding(.horizontal, -12)
                .padding(.vertical, -3)
                .allowsHitTesting(false)
        }
    }
}
