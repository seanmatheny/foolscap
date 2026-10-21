#if canImport(UIKit) && !canImport(AppKit)
import SwiftUI
import FoolscapCore
import FoolscapUI

/// What the bar above the phone's keyboard shows: the tag list while a `#tag` is
/// being typed, else the Format commands.
@MainActor @Observable
public final class EditorAccessoryModel {
    public let tags = TagCompletionModel()
    public var theme: NotebookTheme = .classicBlack
    @ObservationIgnored public var onCommand: (EditorCommand) -> Void = { _ in }
    /// Set when the editor takes pictures: the bar then leads with a photo button.
    @ObservationIgnored public var onPickPhoto: (() -> Void)?

    public init() {}
}

/// A strip of paper above the keyboard: tag suggestions as chips when there are
/// any (a tap completes the tag), otherwise the Format commands the Mac keeps in
/// its menu, as buttons.
public struct EditorAccessoryBar: View {
    public static let height: CGFloat = 44

    @Bindable var model: EditorAccessoryModel

    public init(model: EditorAccessoryModel) { self.model = model }

    private static let commands: [(EditorCommand, String)] = [
        (.bold, "bold"), (.italic, "italic"), (.strikethrough, "strikethrough"), (.code, "chevron.left.forwardslash.chevron.right"),
        (.link, "link"), (.heading1, "1.square"), (.heading2, "2.square"), (.heading3, "3.square"),
        (.bulletList, "list.bullet"), (.numberedList, "list.number"), (.task, "checklist"), (.toggleTaskDone, "checkmark.circle"),
        (.quote, "text.quote"), (.codeBlock, "curlybraces"), (.horizontalRule, "minus"),
        (.foldSection, "chevron.up"), (.unfoldSection, "chevron.down"),
    ]

    public var body: some View {
        let theme = model.theme
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if model.tags.tags.isEmpty {
                    if let pick = model.onPickPhoto {
                        Button(action: pick) {
                            Image(systemName: "photo")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 40, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.ink.color)
                        .accessibilityLabel("Insert Photo")
                    }
                    ForEach(Array(Self.commands.enumerated()), id: \.offset) { _, entry in
                        Button { model.onCommand(entry.0) } label: {
                            Image(systemName: entry.1)
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 40, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.ink.color)
                        .accessibilityLabel(entry.0.title)
                    }
                } else {
                    ForEach(Array(model.tags.tags.enumerated()), id: \.element) { i, tag in
                        let selected = i == model.tags.selection
                        Button { model.tags.pick(tag) } label: {
                            Text("#" + tag)
                                .font(theme.type.body.face(15, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? theme.ink.color : theme.accent.color)
                                .padding(.horizontal, 12)
                                .frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.color.opacity(selected ? 0.18 : 0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Self.height)
        }
        .frame(height: Self.height)
        .background {
            ZStack {
                theme.page.paperColor.color
                TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity, blend: theme.page.textureBlend)
            }
            .overlay(alignment: .top) { Rectangle().fill(theme.ink.color.opacity(0.15)).frame(height: 0.5) }
        }
        .environment(\.notebookTheme, theme)
        .colorScheme(theme.isDark ? .dark : .light)
    }
}
#endif
