import SwiftUI
import FoolscapCore

/// A highlighter-pen stroke behind text: slightly tilted, feathered at the
/// end, multiplied into the paper.
public struct HighlightMark: View {
    let color: RGBA
    public init(color: RGBA) { self.color = color }

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
                .blendMode(.multiply)
        }
        .allowsHitTesting(false)
    }
}

public extension View {
    /// Highlight the view like a marker pen, when `color` is visible.
    func highlighted(_ color: RGBA?) -> some View {
        background {
            if let color, color.a > 0 { HighlightMark(color: color) }
        }
    }
}
