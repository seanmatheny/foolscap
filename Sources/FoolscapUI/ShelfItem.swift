import SwiftUI

/// A cover as it stands on a shelf (Highlights' books, Reference's notes): two shadows,
/// a tight one where it meets the shelf and a soft one it casts, drawn for a 96 pt
/// cover and scaled with `width`, and a slight lift under the pointer. Cover and shadow
/// are flattened into one layer (`drawingGroup`), so scrolling composites a texture
/// instead of re-blurring every shadow a frame.
public struct ShelfItem: ViewModifier {
    let width: CGFloat
    let lifted: Bool
    /// Flatten cover and shadow into one bitmap (`drawingGroup`): worth it for a shelf of
    /// dozens. On textured paper the flattened square shows as a paler box round the cover.
    var flattened = true

    public func body(content: Content) -> some View {
        let k = width / 96
        content
            .shadow(color: .black.opacity(0.28), radius: 1.5 * k, x: 0, y: 1 * k)
            .shadow(color: .black.opacity(0.32), radius: 10 * k, x: 0, y: 7 * k)
            .modifier(Flatten(on: flattened))
            .scaleEffect(lifted ? 1.03 : 1)
            .offset(y: lifted ? -2 : 0)
            .animation(.easeOut(duration: 0.12), value: lifted)
    }
}

private struct Flatten: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.padding(20).drawingGroup().padding(-20) } else { content }
    }
}

public extension View {
    func standingOnShelf(width: CGFloat, lifted: Bool, flattened: Bool = true) -> some View {
        modifier(ShelfItem(width: width, lifted: lifted, flattened: flattened))
    }
}
