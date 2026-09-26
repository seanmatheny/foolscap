import SwiftUI
import AppKit
import FoolscapCore
import FoolscapUI

/// Today's three highlights, set large, each with its book beneath.
struct TodayView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let items: [HighlightItem]
    /// Whether a card's book can be opened (not on the flyleaf).
    var showsBooks: Bool
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 34) {
            Text(Self.dateLine(Date()))
                .font(.system(size: 12 * scale, design: .serif)).kerning(0.6)
                .foregroundStyle(theme.dimInk.color)
                .textCase(.uppercase)
            if items.isEmpty {
                Text("Nothing to show today. Un-hide a few highlights, or import more.")
                    .font(.system(size: 15, design: .serif)).italic().foregroundStyle(theme.dimInk.color)
            }
            ForEach(items) { item in
                QuoteCard(section: section, item: item, showsBook: showsBooks)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: 720, alignment: .leading)
    }

    static func dateLine(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return "Three for " + f.string(from: date)
    }
}

/// One of the day's highlights: a quote with its attribution, the controls
/// appearing on hover.
struct QuoteCard: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let item: HighlightItem
    var showsBook: Bool
    @State private var hovering = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            RoundedRectangle(cornerRadius: 1).fill(theme.accent.color.opacity(0.55)).frame(width: 2.5)
                .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 19 * scale, design: .serif))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let note = item.note {
                    Text(note)
                        .font(.system(size: 13.5 * scale, design: .serif)).italic()
                        .foregroundStyle(theme.dimInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    attribution
                    Spacer()
                    HighlightControls(section: section, item: item, visible: hovering, size: 13 * scale)
                }
                if !item.tags.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(item.tags, id: \.self) { tag in
                            TagChip(tag: tag, scale: scale) { section.removeTag(tag, from: item) }
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { HighlightMenu(section: section, item: item, showsBook: showsBook) }
    }

    private var attribution: some View {
        let text = "— " + item.bookTitle + (item.bookAuthor.isEmpty ? "" : ", " + item.bookAuthor)
        return Group {
            if showsBook {
                Button { section.open(book: item.path, highlight: item.id) } label: {
                    Text(text).underline(hovering)
                }
                .buttonStyle(.plain)
                .help("Open the book")
            } else {
                Text(text)
            }
        }
        .font(.system(size: 13 * scale, design: .serif))
        .foregroundStyle(theme.dimInk.color)
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
        Button("Copy Quote") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
        }
        if showsBook { Button("Open in Book") { section.open(book: item.path, highlight: item.id) } }
    }
}

/// The page shown when the app opens: the day's three on a loose leaf.
struct FlyleafView: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    private var pitch: CGFloat { theme.linePitch }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    RulingView(pitch: pitch, topInset: pitch * 2 - 4, marginX: 58)
                        .frame(minHeight: geo.size.height)
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer().frame(height: pitch * 1.5)
                        TodayView(section: section, items: section.picks, showsBooks: false)
                        Spacer().frame(height: pitch * 1.5)
                        Text("Click to turn the page")
                            .font(.system(size: 11.5, design: .serif)).italic()
                            .foregroundStyle(theme.dimInk.color.opacity(0.8))
                        Spacer(minLength: pitch)
                    }
                    .padding(.leading, 58)
                    .padding(.trailing, 44)
                    .padding(.top, pitch)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .foregroundStyle(theme.ink.color)
        .task { await section.reload() }
    }
}
