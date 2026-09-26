import SwiftUI
import AppKit
import ImageIO
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// The shelf: every book's cover, with its title and count beneath.
struct BookGrid: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 132), spacing: 20, alignment: .top)], alignment: .leading, spacing: 26) {
            ForEach(section.books) { book in
                BookCover(section: section, book: book)
            }
        }
        .padding(.top, 8)
    }
}

struct BookCover: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let book: SearchIndex.HighlightBookRecord
    @State private var hovering = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        Button { section.open(book: book.path) } label: {
            VStack(spacing: 7) {
                CoverThumbnail(url: section.coverURL(for: book.path), title: book.title, author: book.author, width: 96)
                    .shadow(color: .black.opacity(hovering ? 0.35 : 0.22), radius: hovering ? 7 : 4, x: 0, y: hovering ? 4 : 2)
                    .scaleEffect(hovering ? 1.03 : 1)
                Text(book.title)
                    .font(.system(size: 11.5 * scale, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(book.count - book.hiddenCount)")
                    .font(.system(size: 10.5 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
            .frame(width: 108)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(book.author.isEmpty ? book.title : "\(book.title) — \(book.author)")
    }
}

/// The cover JPEG beside the book file, downsampled once and cached; a
/// typographic card when the book has none.
struct CoverThumbnail: View {
    @Environment(\.notebookTheme) private var theme
    let url: URL?
    let title: String
    let author: String
    var width: CGFloat = 96
    @State private var image: NSImage?

    private var height: CGFloat { width * 1.5 }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                PlaceholderCover(title: title, author: author, width: width)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.18), lineWidth: 0.5))
        // A soft crease along the spine, like a paperback.
        .overlay(alignment: .leading) {
            LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing).frame(width: 7)
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await CoverCache.shared.image(for: url, maxPixels: Int(height * 3))
        }
    }
}

/// Paper-coloured card carrying the title and author, for books without a cover.
struct PlaceholderCover: View {
    @Environment(\.notebookTheme) private var theme
    let title: String
    let author: String
    var width: CGFloat = 96

    var body: some View {
        ZStack {
            theme.page.paperColor.color.brightness(theme.isDark ? 0.08 : -0.05)
            TextureOverlay(tile: "kraft", opacity: theme.isDark ? 0.12 : 0.35, blend: theme.isDark ? .screen : .multiply)
            VStack(spacing: 6) {
                Rectangle().fill(theme.accent.color.opacity(0.6)).frame(width: width * 0.3, height: 1.5)
                Text(title)
                    .font(.system(size: width / 9.5, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                if !author.isEmpty {
                    Text(author)
                        .font(.system(size: width / 12, design: .serif)).italic()
                        .foregroundStyle(theme.dimInk.color)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, width * 0.1)
            .foregroundStyle(theme.ink.color)
        }
        .frame(width: width, height: width * 1.5)
    }
}

/// Downsampled cover images, loaded off the main actor and kept for the session.
@MainActor
final class CoverCache {
    static let shared = CoverCache()
    private var images: [URL: NSImage] = [:]

    func image(for url: URL, maxPixels: Int) async -> NSImage? {
        if let cached = images[url] { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { images[url] = image }
        return image
    }

    func forget(_ url: URL) { images[url] = nil }
}

/// One book: cover and title at the top, a tag strip, then every highlight in reading order.
struct BookPage: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let path: String
    private var scale: CGFloat { theme.type.body.size / 15 }
    private var pitch: CGFloat { theme.linePitch }

    var body: some View {
        let items = section.highlights(inBook: path)
        let book = section.book(at: path)
        VStack(alignment: .leading, spacing: 0) {
            Button { section.showBooks() } label: {
                Label("Books", systemImage: "chevron.left").font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
            HStack(alignment: .top, spacing: 18) {
                CoverThumbnail(url: section.coverURL(for: path), title: book?.title ?? "", author: book?.author ?? "", width: 72)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book?.title ?? path).font(.system(size: 20 * scale, weight: .bold, design: .serif))
                    if let author = book?.author, !author.isEmpty {
                        Text(author).font(.system(size: 14 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                    }
                    let hidden = items.filter(\.isHidden).count
                    Text("\(items.count) highlight\(items.count == 1 ? "" : "s")" + (hidden > 0 ? ", \(hidden) hidden" : ""))
                        .font(.system(size: 12 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                }
                .padding(.top, 4)
            }
            .padding(.bottom, 14)
            let tags = bookTags(items)
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: "All", isOn: section.selectedTag == nil) { section.selectedTag = nil }
                        ForEach(tags, id: \.self) { tag in
                            FilterChip(label: "#" + tag, isOn: section.selectedTag == tag) { section.selectedTag = section.selectedTag == tag ? nil : tag }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.bottom, 10)
            }
            let shown = items.filter { section.selectedTag == nil || $0.tags.contains(section.selectedTag!) }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown) { item in
                    HighlightRow(section: section, item: item)
                        .id(item.id)
                }
            }
        }
    }

    private func bookTags(_ items: [HighlightItem]) -> [String] {
        var counts: [String: Int] = [:]
        for item in items { for tag in item.tags { counts[tag, default: 0] += 1 } }
        var tags = counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
        if let chosen = section.selectedTag, !tags.contains(chosen) { tags.append(chosen) }
        return tags
    }
}

/// One highlight in a book or in search results: the quote, its note, the
/// date, its tags and the ♥ / hidden state, controls on hover.
struct HighlightRow: View {
    @Environment(\.notebookTheme) private var theme
    @Bindable var section: HighlightsSection
    let item: HighlightItem
    var query: SearchQuery? = nil
    @State private var hovering = false
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1)
                .fill(item.isFavourite ? theme.accent.color.opacity(0.6) : theme.ink.color.opacity(hovering ? 0.25 : 0.12))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(item.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.system(size: 15 * scale, design: .serif))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let note = item.note {
                    Text(note).font(.system(size: 12.5 * scale, design: .serif)).italic().foregroundStyle(theme.dimInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .center, spacing: 8) {
                    if let added = item.meta.added {
                        Text(added.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11 * scale, design: .serif)).foregroundStyle(theme.dimInk.color)
                    }
                    ForEach(item.tags, id: \.self) { tag in
                        TagChip(tag: tag, scale: scale) { section.removeTag(tag, from: item) }
                    }
                    if item.isHidden {
                        Text("hidden")
                            .font(.system(size: 10.5 * scale, design: .serif)).italic()
                            .foregroundStyle(theme.dimInk.color)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(Capsule().stroke(theme.dimInk.color.opacity(0.4), lineWidth: 0.5))
                    }
                    Spacer()
                    HighlightControls(section: section, item: item, visible: hovering, size: 12 * scale)
                }
            }
        }
        .padding(.vertical, 9)
        .opacity(item.isHidden ? 0.5 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { HighlightMenu(section: section, item: item, showsBook: query != nil) }
        .overlay(alignment: .bottom) { Rectangle().fill(theme.ink.color.opacity(0.07)).frame(height: 0.5).padding(.leading, 14) }
    }
}
