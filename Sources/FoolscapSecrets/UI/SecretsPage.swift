import SwiftUI
import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapEditor
import FoolscapUI

/// The Secrets tab: the title row (padlock, countdown, search, New), the index
/// cards for the chosen letter, a faint letter watermark on the spine side and
/// the thumb index cut into the page beside the big tabs.
struct SecretsPage: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge
    @Bindable var section: SecretsSection
    @FocusState private var searchFocused: Bool
    @State private var pageHeight: CGFloat = 710

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }
    static let fieldGap: CGFloat = 3

    var body: some View {
        let palette = EditorPalette(theme: theme)
        let layout = ThumbIndexLayout(pageHeight: pageHeight)
        let group = layout.group(containing: section.selectedLetter)
        let unlocked = section.isUnlocked
        let left = tabEdge == .left
        GeometryReader { geo in
            ZStack(alignment: left ? .topLeading : .topTrailing) {
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        RulingView(pitch: pitch, topInset: pitch + PageRuling.ruleOffset(palette), marginX: PageRuling.textLeft)
                            .frame(minHeight: geo.size.height)
                        if unlocked, !section.showsAllLetters, let group {
                            Text(group.label)
                                .font(.system(size: 110 * scale, weight: .bold, design: .serif))
                                .foregroundStyle(theme.ink.color.opacity(0.06))
                                .padding(.top, pitch * 2.2)
                                .padding(.trailing, left ? 60 : 70)
                                .frame(maxWidth: .infinity, alignment: .topTrailing)
                                .allowsHitTesting(false)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            content(group: group)
                            Spacer(minLength: pitch * 2)
                        }
                        .padding(.leading, PageRuling.textLeft)
                        .padding(.trailing, 44)
                        .padding(.top, pitch + PageRuling.rowShift(palette))
                    }
                }
                if unlocked {
                    ThumbIndexView(layout: layout, selected: group, active: section.lettersWithMatches) { picked in
                        section.select(picked.letters.first { section.lettersWithEntries.contains($0) } ?? picked.letters[0])
                    }
                }
            }
            .onAppear { pageHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, h in pageHeight = h }
        }
        .foregroundStyle(theme.ink.color)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(characters: .alphanumerics.union(CharacterSet(charactersIn: "#")), phases: .down) { press in
            guard section.isUnlocked, !section.isEditing, !searchFocused, press.modifiers.isEmpty else { return .ignored }
            section.select(SecretLetter.filing(for: String(press.characters)))
            return .handled
        }
    }

    // MARK: Title row

    private var header: some View {
        let unlocked = section.isUnlocked
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Secrets").font(theme.type.heading.font).fontWeight(.bold)
            // The padlock is a switch: open, a click locks the vault; shut, it asks for Touch ID.
            Button {
                if unlocked { section.lockNow() } else if section.vault.hasDeviceWrap { Task { await section.unlockWithDevice() } }
            } label: {
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundStyle(unlocked ? theme.accent.color : theme.dimInk.color)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(unlocked ? "Lock (⌃⌘L)" : "Unlock with Touch ID")
            status
                .font(.system(size: 12.5 * scale, design: .serif))
                .foregroundStyle(theme.dimInk.color)
                .lineLimit(1)
            Spacer()
            if unlocked {
                searchField
                Button { section.beginAdd() } label: {
                    Label("New", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold, design: .serif))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(Capsule().fill(theme.accent.color.opacity(0.16)))
                        .overlay(Capsule().stroke(theme.accent.color.opacity(0.35), lineWidth: 0.5))
                        .foregroundStyle(theme.accent.color)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [.command])
                .help("New secret (⌘N)")
            }
        }
        .frame(height: pitch * 1.5 - Self.fieldGap)
    }

    @ViewBuilder private var status: some View {
        switch section.vault.state {
        case .unlocked:
            let count = section.entryCount
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let _ = section.unlockGeneration
                let entries = count == 1 ? "1 entry" : "\(count) entries"
                if let at = section.locksAt {
                    Text("\(entries) · locks in \(Self.countdown(until: at, now: context.date))")
                } else {
                    Text(entries)
                }
            }
        case .locked, .unlocking:
            if let at = section.lockedAt {
                Text("Locked at " + DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short))
            } else {
                Text("Locked")
            }
        case .failed:
            Text("Cannot be opened").foregroundStyle(.red)
        case .absent:
            Text("")
        }
    }

    static func countdown(until deadline: Date, now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.down)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.dimInk.color)
            TextField("Search titles, fields, notes", text: $section.searchText)
                .font(.system(size: 13 * scale, design: .serif))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .completesTags(in: $section.searchText, known: section.knownTags)
            if !section.searchText.isEmpty {
                Button { section.searchText = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(theme.dimInk.color)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.ink.color.opacity(searchFocused ? 0.07 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.ink.color.opacity(searchFocused ? 0.22 : 0.12), lineWidth: 0.5))
        .colorScheme(theme.isDark ? .dark : .light)
    }

    // MARK: Below the title

    @ViewBuilder private func content(group: LetterGroup?) -> some View {
        switch section.vault.state {
        case .absent:
            SetupView(section: section)
        case .locked, .unlocking, .failed:
            LockedView(section: section)
        case .unlocked:
            tagStrip.frame(height: pitch)
            cards(letters: group?.letters ?? [section.selectedLetter])
        }
    }

    /// One-click tag filters, most used first, as on the Tasks tab.
    private var tagStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(label: "All", isOn: section.showingAll) { section.showAll() }
                ForEach(section.stripTags, id: \.self) { tag in
                    FilterChip(label: "#" + tag, isOn: section.selectedTags.contains(tag)) { section.toggleTag(tag) }
                }
            }
            .padding(.trailing, 4).padding(.vertical, 2)
        }
    }

    private func cards(letters: [SecretLetter]) -> some View {
        let shown = section.entriesToShow(for: letters)
        let showsHeadings = section.showsAllLetters || letters.count > 1
        let nothing = shown.allSatisfy { $0.entries.isEmpty } && section.editingID != SecretsSection.newEntryID
        return VStack(alignment: .leading, spacing: pitch / 2) {
            if section.editingID == SecretsSection.newEntryID, let draft = section.draft {
                SecretEntryEditor(section: section, document: draft)
            }
            ForEach(shown) { under in
                if showsHeadings, !under.entries.isEmpty {
                    Text(under.letter.description)
                        .font(.system(size: 15 * scale, weight: .bold, design: .serif))
                        .foregroundStyle(theme.dimInk.color)
                        .frame(height: pitch, alignment: .bottomLeading)
                }
                ForEach(under.entries) { entry in
                    if section.editingID == entry.id, let draft = section.draft {
                        SecretEntryEditor(section: section, document: draft)
                    } else {
                        SecretCardView(section: section, entry: entry)
                    }
                }
            }
            if nothing {
                Text(emptyMessage(letters: letters))
                    .font(.system(size: 14 * scale, design: .serif)).italic()
                    .foregroundStyle(theme.dimInk.color)
                    .frame(height: pitch)
            }
        }
        .padding(.top, pitch / 2)
    }

    private func emptyMessage(letters: [SecretLetter]) -> String {
        let tags = section.selectedTags.map { "#" + $0 }.joined(separator: " ")
        if section.isSearching {
            let q = section.searchText.trimmingCharacters(in: .whitespaces)
            return tags.isEmpty ? "Nothing matches “\(q)”." : "Nothing matches “\(q)” with \(tags)."
        }
        if section.showsAllLetters { return tags.isEmpty ? "Nothing in the vault yet. New (⌘N) adds a card." : "Nothing carries \(tags)." }
        let where_ = letters.map(\.description).joined(separator: ", ")
        return tags.isEmpty ? "Nothing filed under \(where_) yet. New (⌘N) adds a card here."
            : "Nothing under \(where_) carries \(tags); the brighter letters do, and \(tags) in the strip lists them all."
    }
}
