import SwiftUI
import FoolscapCore

/// Wraps popover content in paper: the theme's colours and colour scheme,
/// instead of whatever the system appearance happens to be.
public struct PaperPopover<Content: View>: View {
    @Environment(\.notebookTheme) private var theme
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .foregroundStyle(theme.ink.color)
            .tint(theme.accent.color)
            .padding(14)
            .background(
                ZStack {
                    theme.page.paperColor.color
                    TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity)
                }
            )
            .colorScheme(theme.isDark ? .dark : .light)
    }
}

/// A text field drawn as a soft inset on the paper.
public struct PaperFieldStyle: ViewModifier {
    @Environment(\.notebookTheme) private var theme
    public func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(0.15), lineWidth: 0.5))
    }
}

public extension View {
    func paperField() -> some View { modifier(PaperFieldStyle()) }
}
