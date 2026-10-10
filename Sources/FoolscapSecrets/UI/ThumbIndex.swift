import SwiftUI
import FoolscapCore
import FoolscapUI

/// One cut of the thumb index: a letter, or a run of letters on a short page.
public struct LetterGroup: Hashable, Identifiable, Sendable {
    public var letters: [SecretLetter]
    public var id: String { label }

    public var label: String {
        guard let first = letters.first, let last = letters.last else { return "" }
        return first == last ? first.description : "\(first)–\(last)"
    }

    /// Adjacent pairs merged first when the page is short, rarest letters first.
    static let mergeOrder: [(Character, Character)] = [
        ("Y", "Z"), ("X", "Y"), ("U", "V"), ("Q", "R"), ("I", "J"), ("K", "L"), ("O", "P"),
        ("E", "F"), ("G", "H"), ("A", "B"), ("C", "D"), ("M", "N"), ("S", "T"), ("W", "X"),
    ]

    /// A–Z and `#` in at most `capacity` cuts; `#` is always its own last cut.
    public static func groups(capacity: Int) -> [LetterGroup] {
        var groups = SecretLetter.letters.map { LetterGroup(letters: [$0]) }
        let room = max(2, capacity) - 1
        var merges = mergeOrder.makeIterator()
        while groups.count > room {
            if let (a, b) = merges.next() {
                guard let i = groups.firstIndex(where: { $0.letters.contains(.letter(a)) }),
                      let j = groups.firstIndex(where: { $0.letters.contains(.letter(b)) }), i != j else { continue }
                let (lo, hi) = (min(i, j), max(i, j))
                groups[lo].letters += groups[hi].letters
                groups.remove(at: hi)
            } else {
                // Past the list: fold pairs from the end until it fits.
                let last = groups.count - 1
                groups[last - 1].letters += groups[last].letters
                groups.removeLast()
            }
        }
        return groups + [LetterGroup(letters: [.other])]
    }
}

/// How the strip is laid out for a page of a given height: 27 cuts at up to 26 pt
/// when they fit, else fewer, grouped cuts.
public struct ThumbIndexLayout: Equatable {
    public static let maxPitch: CGFloat = 26
    public static let minPitch: CGFloat = 21
    public static let topInset: CGFloat = 6
    public var pitch: CGFloat
    public var groups: [LetterGroup]

    public init(pageHeight: CGFloat) {
        let room = max(0, pageHeight - Self.topInset * 2)
        let fit = room / 27
        if fit >= Self.minPitch {
            pitch = min(Self.maxPitch, fit)
            groups = LetterGroup.groups(capacity: 27)
        } else {
            pitch = Self.maxPitch
            groups = LetterGroup.groups(capacity: Int(room / Self.maxPitch))
        }
    }

    public func group(containing letter: SecretLetter) -> LetterGroup? { groups.first { $0.letters.contains(letter) } }
}

/// The address book's thumb index, cut into the page just inside its tab-side
/// edge: one cut per letter, the ones with entries in the tab's colour, the
/// selected one standing a little further into the page.
struct ThumbIndexView: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge
    let layout: ThumbIndexLayout
    let selected: LetterGroup?
    /// Letters with entries (or, while searching, with matches).
    let active: Set<SecretLetter>
    let onSelect: (LetterGroup) -> Void

    static let width: CGFloat = 24
    static let selectedWidth: CGFloat = 34

    var body: some View {
        let left = tabEdge == .left
        VStack(alignment: left ? .leading : .trailing, spacing: 0) {
            ForEach(layout.groups) { group in
                ThumbCut(group: group, isSelected: group == selected, isActive: group.letters.contains { active.contains($0) },
                         color: theme.tabColor(at: 5), freeEdgeOnLeft: !left, height: layout.pitch - 2) { onSelect(group) }
                    .frame(height: layout.pitch, alignment: .center)
            }
        }
        .padding(.top, ThumbIndexLayout.topInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ThumbCut: View {
    let group: LetterGroup
    let isSelected: Bool
    let isActive: Bool
    let color: RGBA
    let freeEdgeOnLeft: Bool
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = SideTabShape(freeEdgeOnLeft: freeEdgeOnLeft)
        let width: CGFloat = isSelected ? ThumbIndexView.selectedWidth : (hovering ? ThumbIndexView.width + 3 : ThumbIndexView.width)
        Button(action: action) {
            ZStack {
                ZStack {
                    shape.fill(color.color)
                    shape.fill(LinearGradient(colors: freeEdgeOnLeft ? [.black.opacity(0.10), .clear, .white.opacity(0.22)] : [.white.opacity(0.22), .clear, .black.opacity(0.10)],
                                              startPoint: .leading, endPoint: .trailing))
                    TextureOverlay(tile: "paper", opacity: 0.5)
                }
                .clipShape(shape)
                shape.stroke(Color.black.opacity(isSelected ? 0.3 : 0.22), lineWidth: 0.5)
                Text(group.label)
                    .font(.system(size: group.letters.count > 1 ? 9.5 : (isSelected ? 13 : 11.5), weight: .semibold, design: .serif))
                    .foregroundStyle(Color.black.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 2)
            }
            .frame(width: width, height: height)
            .opacity(isSelected ? 1 : (isActive ? 0.92 : 0.38))
            .shadow(color: .black.opacity(isSelected ? 0.3 : 0), radius: 3, x: freeEdgeOnLeft ? -1.5 : 1.5, y: 1)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.22), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(group.letters.count > 1 ? "Entries filed under \(group.label)" : "")
    }
}
