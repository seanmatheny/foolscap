import SwiftUI
import FoolscapCore

/// What the notebook chrome needs to know about a section to draw its tab.
public struct NotebookTabItem: Identifiable, Hashable {
    public var id: String
    public var appearance: TabAppearance
    public init(id: String, appearance: TabAppearance) { self.id = id; self.appearance = appearance }
}

/// The whole notebook: leather cover, page block, index tabs and elastic band.
/// The page content is supplied by the caller for the selected tab.
public struct NotebookView<Page: View>: View {
    @Environment(\.notebookTheme) private var theme
    let tabs: [NotebookTabItem]
    @Binding var selection: String
    let page: (String) -> Page

    public init(tabs: [NotebookTabItem], selection: Binding<String>, @ViewBuilder page: @escaping (String) -> Page) {
        self.tabs = tabs; self._selection = selection; self.page = page
    }

    private let coverPad: CGFloat = 22
    private let tabWidth: CGFloat = 118

    public var body: some View {
        ZStack {
            // Desk
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)

            HStack(spacing: 0) {
                CoverBlock {
                    ZStack(alignment: .topTrailing) {
                        PageView {
                            page(selection)
                        }
                        .padding(EdgeInsets(top: coverPad, leading: coverPad + 14, bottom: coverPad, trailing: coverPad))
                        ElasticBandView()
                            .padding(.trailing, coverPad + 28)
                    }
                }
                IndexTabsView(tabs: tabs, selection: $selection)
                    .frame(width: tabWidth)
                    .padding(.top, coverPad + 40)
            }
            .padding(EdgeInsets(top: 34, leading: 28, bottom: 28, trailing: 8))
        }
        .ignoresSafeArea()
    }
}

/// The leather cover with stitching and a spine highlight.
struct CoverBlock<Content: View>: View {
    @Environment(\.notebookTheme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cover.baseColor.color)
            TextureOverlay(tile: theme.cover.textureTile, opacity: theme.cover.grainOpacity, blend: theme.cover.blend)
            // Light falls from the top-left
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.22)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            // Spine crease
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Stitching
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(theme.cover.stitchColor.color.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .padding(8)
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)
    }
}

struct ElasticBandView: View {
    @Environment(\.notebookTheme) private var theme
    var body: some View {
        Rectangle()
            .fill(theme.cover.bandColor.color)
            .overlay(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.3)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 12)
            .shadow(color: .black.opacity(0.45), radius: 3, x: 1, y: 0)
            .allowsHitTesting(false)
    }
}

struct IndexTabsView: View {
    @Environment(\.notebookTheme) private var theme
    let tabs: [NotebookTabItem]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                PaperTab(appearance: tab.appearance,
                         color: theme.tabColor(at: tab.appearance.colorIndex ?? index),
                         isSelected: tab.id == selection,
                         index: index)
                    .onTapGesture { selection = tab.id }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(tab.appearance.label)
            }
            Spacer()
        }
    }
}
