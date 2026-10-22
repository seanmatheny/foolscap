import SwiftUI
import FoolscapCore
import FoolscapUI

/// Today's three highlights, set large, each with its book beneath.
struct TodayView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let items: [HighlightItem]
    /// Whether a card's book can be opened.
    var showsBooks: Bool
    /// The flyleaf sets its title in the middle of the page; the quotes keep
    /// their left rule in a column beneath it.
    var centered = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text(Self.dateLine(Date()))
                .font(theme.type.heading.face(20 * scale, weight: .bold))
                .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
            if items.isEmpty {
                Text("Nothing to show today. Un-hide a few highlights, or import more.")
                    .font(theme.type.body.face(15)).italic().foregroundStyle(theme.dimInk.color)
            }
            ForEach(items) { item in
                QuoteCard(section: section, item: item, showsBook: showsBooks)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: 720, alignment: centered ? .center : .leading)
    }

    static func dateLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return "Highlights for " + f.string(from: date)
    }
}

/// One of the day's highlights: a quote with its attribution, the controls
/// appearing on hover.
struct QuoteCard: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Bindable var section: HighlightsSection
    let item: HighlightItem
    var showsBook: Bool
    @State private var hovering = false
    @State private var overCover = false
    @Environment(\.turnLooseLeaf) private var turnLooseLeaf
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        Group {
            if compact {
                // A phone's column has no room beside the cover: the quote goes under it.
                VStack(alignment: .leading, spacing: 12) {
                    cover
                    quote
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    cover
                    quote
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { HighlightMenu(section: section, item: item, showsBook: showsBook, openBook: openBook) }
    }

    /// From the flyleaf the notebook turns to the Highlights tab as well; turning to another
    /// tab takes the leaf with it, so the leaf is only turned by hand when the tab is already open.
    private func openBook() {
        section.open(book: item.path, highlight: item.id)
        guard let turnLooseLeaf else { return }
        if section.turnToTab?() != true { turnLooseLeaf() }
    }

    /// The book's cover beside its quote, as on the shelf; it opens the book where the attribution does.
    @ViewBuilder private var cover: some View {
        let url = section.coverURL(for: item.path)
        if showsBook {
            Button { openBook() } label: {
                ShelfCover(url: url, title: item.bookTitle, author: item.bookAuthor, width: 54 * scale, lifted: overCover)
            }
            .buttonStyle(.plain)
            .onHover { overCover = $0 }
            .help("Open the book")
            .padding(.top, 4)
        } else {
            ShelfCover(url: url, title: item.bookTitle, author: item.bookAuthor, width: 54 * scale, lifted: false)
                .padding(.top, 4)
        }
    }

    private var quote: some View {
        // The rule is an overlay of the text block, so it always spans the block's final
        // height (a sibling in an HStack can be measured before long text has wrapped).
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(theme.type.body.face((compact ? 17 : 19) * scale))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let note = item.note {
                Text(note)
                    .font(theme.type.body.face(13.5 * scale)).italic()
                    .foregroundStyle(theme.dimInk.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                attribution
                if !compact { LocationLabel(section: section, item: item, size: 12.5 * scale) }
                Spacer()
                // A phone has no pointer to hover the controls in; the menu has them, and only a
                // set heart shows, so the title keeps the width.
                if !compact || item.isFavourite {
                    HighlightControls(section: section, item: item, visible: hovering, size: 13 * scale)
                }
            }
            if !item.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(item.tags, id: \.self) { tag in
                        TagChip(tag: tag, scale: scale) { section.removeTag(tag, from: item) }
                    }
                }
            }
        }
        .padding(.leading, 18.5)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(theme.accent.color.opacity(0.55)).frame(width: 2.5).padding(.vertical, 4)
        }
    }

    private var attribution: some View {
        let text = "— " + item.bookTitle + (item.bookAuthor.isEmpty ? "" : ", " + item.bookAuthor)
        return Group {
            if showsBook {
                Button { openBook() } label: {
                    Text(text).underline(hovering)
                }
                .buttonStyle(.plain)
                .help("Open the book")
            } else {
                Text(text)
            }
        }
        .font(theme.type.body.face(14 * scale))
        .italic()
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(theme.accent.color)
    }
}

/// ♥, "don't show again" and tag, on hover; the heart stays visible when set.
struct HighlightControls: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let item: HighlightItem
    let visible: Bool
    var size: CGFloat = 12
    @State private var askTag = false

    var body: some View {
        HStack(spacing: 12) {
            Button { section.toggleFavourite(item) } label: {
                Image(systemName: item.isFavourite ? "heart.fill" : "heart").font(.system(size: size))
                    .foregroundStyle(item.isFavourite ? theme.accent.color : theme.dimInk.color)
            }
            .buttonStyle(.plain)
            .help(item.isFavourite ? "Show this less often" : "Show this more often")
            .opacity(visible || item.isFavourite ? 1 : 0)
            Button { section.setHidden(item, !item.isHidden) } label: {
                Image(systemName: item.isHidden ? "eye" : "eye.slash").font(.system(size: size))
                    .foregroundStyle(theme.dimInk.color)
            }
            .buttonStyle(.plain)
            .help(item.isHidden ? "Show among the day's highlights again" : "Never show among the day's highlights")
            .opacity(visible ? 1 : 0)
            Button { askTag = true } label: {
                Image(systemName: "tag").font(.system(size: size)).foregroundStyle(theme.dimInk.color)
            }
            .buttonStyle(.plain)
            .help("Add a tag")
            .opacity(visible ? 1 : 0)
            .popover(isPresented: $askTag, arrowEdge: .bottom) {
                TagPopover(allTags: section.knownTags, existing: item.tags) { section.addTag($0, to: item); askTag = false }
            }
        }
    }
}

struct HighlightMenu: View {
    @Bindable var section: HighlightsSection
    let item: HighlightItem
    var showsBook: Bool
    /// How the card this menu belongs to opens its book, when not simply in place.
    var openBook: (() -> Void)?

    var body: some View {
        Button(item.isFavourite ? "Remove Heart" : "Heart") { section.toggleFavourite(item) }
        Button(item.isHidden ? "Show Among the Day's Highlights" : "Don't Show Again") { section.setHidden(item, !item.isHidden) }
        Menu("Add Tag") {
            ForEach(section.knownTags.filter { !item.tags.contains($0) }, id: \.self) { tag in
                Button("#" + tag) { section.addTag(tag, to: item) }
            }
        }
        if !item.tags.isEmpty {
            Menu("Remove Tag") {
                ForEach(item.tags, id: \.self) { tag in Button("#" + tag) { section.removeTag(tag, from: item) } }
            }
        }
        Divider()
        Button("Copy Quote") { Platform.copyText(item.text) }
        if showsBook {
            Button("Open in Book") {
                if let openBook { openBook() } else { section.open(book: item.path, highlight: item.id) }
            }
        }
        if let url = section.kindleURL(for: item) {
            Button("Open in Kindle") { Platform.openURL(url) }
        }
    }
}

/// "Location 3283" in the small dim face, when the highlight has one; a link
/// into the Kindle app when the book can be named to it.
struct LocationLabel: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let item: HighlightItem
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        if let location = item.meta.location {
            // Plain digits, as the Kindle prints them ("Location 1205").
            let text = Text(verbatim: "Location \(String(location))").font(theme.type.body.face(size)).foregroundStyle(theme.dimInk.color)
            if let url = section.kindleURL(for: item) {
                Button { Platform.openURL(url) } label: { text.underline(hovering) }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .help("Open in Kindle at this location")
            } else {
                text
            }
        }
    }
}

/// The page shown when the app opens: the day's three on a loose leaf, the
/// jester from the cover printed small in its top corner.
struct FlyleafView: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Bindable var section: HighlightsSection
    private var pitch: CGFloat { theme.linePitch }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .top) {
                    Color.clear.frame(minHeight: geo.size.height)
                    // Printed in the paper's own tone: a wash of ink thin enough for the grain
                    // to come through, a shade darker on light paper and lighter on dark.
                    JesterShape()
                        .fill(theme.ink.color.opacity(0.08))
                        .frame(width: pitch * 2.75, height: pitch * 2.75)
                        .padding([.top, .trailing], pitch)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .allowsHitTesting(false)
                    VStack(alignment: .center, spacing: 0) {
                        Spacer().frame(height: pitch * 1.5)
                        TodayView(section: section, items: section.picks, showsBooks: true, centered: true)
                        Spacer().frame(height: pitch * 1.5)
                        Text(compact ? "Tap to turn the page" : "Click to turn the page")
                            .font(theme.type.body.face(11.5)).italic()
                            .foregroundStyle(theme.dimInk.color.opacity(0.8))
                        Spacer(minLength: pitch)
                    }
                    .padding(.leading, PageColumn.textLeft)
                    .padding(.trailing, PageColumn.trailing(compact: compact))
                    .padding(.top, pitch)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .foregroundStyle(theme.ink.color)
        .task { await section.reload() }
    }
}
