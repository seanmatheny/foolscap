import SwiftUI
import FoolscapCore
import FoolscapUI

/// Choosing a note's cover: a preview, the cloths, the patterns and the icons (each
/// row led by "Automatic", the look the title gives). Each pick is saved at once.
struct CoverPicker: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.compactPage) private var compact
    @Environment(\.dismiss) private var dismiss
    @Bindable var section: ReferenceSection
    let note: ReferenceNote
    @State private var choice: CoverChoice
    @State private var query = ""

    init(section: ReferenceSection, note: ReferenceNote) {
        self.section = section
        self.note = note
        _choice = State(initialValue: section.choices[note.key] ?? CoverChoice())
    }

    private var derived: (cloth: CoverCloth, pattern: CoverPattern) { ReferenceCover.derived(title: note.title) }

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }.font(theme.type.body.face(15, weight: .semibold))
                    }
                    .padding(.bottom, 6)
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(theme.page.paperColor.color.ignoresSafeArea())
                .foregroundStyle(theme.ink.color)
                .tint(theme.accent.color)
                .colorScheme(theme.isDark ? .dark : .light)
            } else {
                PaperPopover { content.frame(width: 344) }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                NoteCover(cover: ReferenceCover.resolve(title: note.title, choice: choice), title: note.title, width: 66)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.title).font(theme.type.heading.face(17, weight: .bold)).lineLimit(2)
                    Text(choice.isEmpty ? "As its title has it" : "Your choice")
                        .font(theme.type.body.face(12)).foregroundStyle(theme.dimInk.color)
                    if !choice.isEmpty {
                        Button("Back to Automatic") { set(CoverChoice()) }
                            .buttonStyle(.plain)
                            .font(theme.type.body.face(12, weight: .semibold))
                            .foregroundStyle(theme.accent.color)
                    }
                }
                Spacer(minLength: 0)
            }
            heading("Cloth")
            clothRow
            heading("Pattern")
            patternRow
            heading("Icon")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.dimInk.color)
                TextField("Search icons", text: $query).textFieldStyle(.plain).font(theme.type.body.face(13))
            }
            .paperField()
            ScrollView {
                symbolGrid.padding(.vertical, 2)
            }
            .frame(height: compact ? nil : 210)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased()).font(theme.type.body.face(10, weight: .semibold)).kerning(0.6).foregroundStyle(theme.dimInk.color)
    }

    private func set(_ new: CoverChoice) {
        choice = new
        Task { await section.setCover(new, for: note) }
    }

    // MARK: Cloth

    private var clothRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 24, maximum: 28), spacing: 6)], alignment: .leading, spacing: 6) {
            swatch(derived.cloth, selected: choice.cloth == nil, automatic: true) { var c = choice; c.cloth = nil; set(c) }
            ForEach(CoverCloth.allCases, id: \.self) { cloth in
                swatch(cloth, selected: choice.cloth == cloth, automatic: false) { var c = choice; c.cloth = cloth; set(c) }
            }
        }
    }

    private func swatch(_ cloth: CoverCloth, selected: Bool, automatic: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(cloth.rgba(onDark: theme.isDark).color)
                .frame(width: 22, height: 22)
                .overlay {
                    if automatic { Text("A").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.85)) }
                }
                .padding(2)
                .overlay(Circle().stroke(selected ? theme.accent.color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(automatic ? "Automatic (\(cloth.title))" : cloth.title)
    }

    // MARK: Pattern

    private var patternRow: some View {
        let cloth = (choice.cloth ?? derived.cloth).rgba(onDark: theme.isDark)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 30, maximum: 34), spacing: 6)], alignment: .leading, spacing: 6) {
            patternTile(derived.pattern, cloth: cloth, selected: choice.pattern == nil, automatic: true) { var c = choice; c.pattern = nil; set(c) }
            ForEach(CoverPattern.allCases, id: \.self) { pattern in
                patternTile(pattern, cloth: cloth, selected: choice.pattern == pattern, automatic: false) {
                    var c = choice; c.pattern = pattern; set(c)
                }
            }
        }
    }

    private func patternTile(_ pattern: CoverPattern, cloth: RGBA, selected: Bool, automatic: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                cloth.color
                CoverPatternView(pattern: pattern, cloth: cloth, width: 70)
                if automatic { Text("A").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.85)) }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? theme.accent.color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(automatic ? "Automatic (\(pattern.title))" : pattern.title)
    }

    // MARK: Icons

    private var symbolGrid: some View {
        let groups = ReferenceSymbols.matching(query)
        let columns = [GridItem(.adaptive(minimum: 34, maximum: 40), spacing: 4)]
        return VStack(alignment: .leading, spacing: 10) {
            if query.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                    iconCell(symbol: nil)
                }
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title).font(theme.type.body.face(11, weight: .semibold)).foregroundStyle(theme.dimInk.color)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                        ForEach(group.symbols, id: \.self) { iconCell(symbol: $0) }
                    }
                }
            }
            if groups.isEmpty {
                Text("No icon matches “\(query)”.").font(theme.type.body.face(12)).foregroundStyle(theme.dimInk.color)
            }
        }
    }

    /// One icon to pick; nil is the monogram.
    private func iconCell(symbol: String?) -> some View {
        let selected = choice.symbol == symbol
        return Button { var c = choice; c.symbol = symbol; set(c) } label: {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 16))
                } else {
                    Text(ReferenceCover.monogram(note.title)).font(theme.type.heading.face(13, weight: .bold))
                }
            }
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? theme.accent.color.opacity(0.18) : theme.ink.color.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? theme.accent.color : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol ?? "Monogram")
    }
}
