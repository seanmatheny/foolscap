import SwiftUI
import FoolscapCore
import FoolscapStore
import FoolscapUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

// The parts of Settings both apps show: the Notebook sections (theme, paper, type,
// page, cover), the pens, and the swatches. The Mac's PreferencesView puts them in
// its tabs; the phone's Settings page lists them on paper.

/// A section's own settings, shown under its heading in Preferences.
public struct SectionSettingsPane: Identifiable {
    public var id: String
    public var title: String
    public var view: AnyView
    public init(id: String, title: String, view: AnyView) { self.id = id; self.title = title; self.view = view }
}

/// Settings keys the app mirrors into the theme and the chrome environment.
public enum PreferenceKeys {
    public static let ruling = "ruling"
    public static let marginRule = "marginRule"
    public static let elasticBand = "elasticBand"
    public static let tabEdge = "tabEdge"
    public static let paperTexture = "paperTexture"
    /// Font family names; empty means the theme's own face.
    public static let bodyFont = "bodyFont"
    public static let headingFont = "headingFont"
    public static let monoFont = "monoFont"
}

/// Settings ▸ Notebook: the theme and its paper, the type, the page and the cover.
public struct NotebookSettingsSections: View {
    @Binding var themeID: String
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("openingAnimation") private var openingAnimation = true
    @AppStorage(PreferenceKeys.ruling) private var ruling = Ruling.blank.rawValue
    @AppStorage(PreferenceKeys.marginRule) private var marginRule = false
    @AppStorage(PreferenceKeys.elasticBand) private var elasticBand = false
    @AppStorage(PreferenceKeys.tabEdge) private var tabEdge = TabEdge.left.rawValue
    @AppStorage(PreferenceKeys.paperTexture) private var paperTexture = PaperTexture.none.rawValue
    @AppStorage(PreferenceKeys.bodyFont) private var bodyFont = ""
    @AppStorage(PreferenceKeys.headingFont) private var headingFont = ""
    @AppStorage(PreferenceKeys.monoFont) private var monoFont = ""

    public init(themeID: Binding<String>) { _themeID = themeID }

    public var body: some View {
        Section("Theme") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                ForEach(NotebookTheme.builtIn) { theme in
                    ThemeSwatch(theme: theme, isSelected: theme.id == themeID)
                        .onTapGesture { themeID = theme.id }
                }
            }
            .padding(.vertical, 4)
            // A flat theme has no paper to choose: its page stays plain.
            if !(NotebookTheme.builtIn(id: themeID)?.flat ?? false) {
                LabeledContent("Paper") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 10) {
                        ForEach(PaperTexture.allCases, id: \.self) { texture in
                            PaperSwatch(texture: texture, theme: NotebookTheme.builtIn(id: themeID) ?? .classicBlack,
                                        isSelected: texture.rawValue == paperTexture)
                                .onTapGesture { paperTexture = texture.rawValue }
                        }
                    }
                    .frame(width: 330)
                }
            }
        }
        Section("Type") {
            let theme = NotebookTheme.builtIn(id: themeID) ?? .classicBlack
            FontFamilyPicker("Text", selection: $bodyFont, themeFace: theme.type.body.family)
            FontFamilyPicker("Headings", selection: $headingFont, themeFace: theme.type.heading.family)
            FontFamilyPicker("Code", selection: $monoFont, themeFace: theme.type.mono.family)
            Text("Each theme has faces of its own; a choice here is kept across themes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Page") {
            LabeledContent("Text size") {
                HStack {
                    Slider(value: $textScale, in: 0.8...1.6, step: 0.05).frame(width: 200)
                    Text("\(Int((textScale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    Button("Reset") { textScale = 1 }.disabled(textScale == 1)
                }
            }
            Text("Also ⌘+ and ⌘− in the View menu. Line height scales with the text.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Ruling", selection: $ruling) {
                ForEach([Ruling.blank, .lined, .dotted, .grid], id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle("Red margin line", isOn: $marginRule)
            Text("Rules follow the text size and take their colour from the theme.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Cover") {
            Picker("Index tabs", selection: $tabEdge) {
                ForEach(TabEdge.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Toggle("Elastic band around the cover", isOn: $elasticBand)
            Toggle("Open the cover when the app starts", isOn: $openingAnimation)
        }
    }
}

/// A menu of the installed font families, the theme's own face first, each item set in its face.
public struct FontFamilyPicker: View {
    let label: String
    @Binding var selection: String
    let themeFace: String?

    public init(_ label: String, selection: Binding<String>, themeFace: String?) {
        self.label = label; _selection = selection; self.themeFace = themeFace
    }

    /// Every family with a visible name, once; the font panel's hidden families (`.SF…`) left out.
    static let families: [String] = {
        #if canImport(AppKit)
        let all = NSFontManager.shared.availableFontFamilies
        #else
        let all = UIFont.familyNames
        #endif
        return all.filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    public var body: some View {
        Picker(label, selection: $selection) {
            Text("Theme face" + (themeFace.map { " (\($0))" } ?? "")).tag("")
            Divider()
            ForEach(Self.families, id: \.self) { family in
                Text(family).font(.custom(family, size: 13)).tag(family)
            }
        }
        .frame(maxWidth: 360)
    }
}

/// Settings ▸ Tasks: up to eight tags given a highlighter pen, in the order the
/// lanes sort, and the sort toggle. Edits are written as typed; `TaskPens.load`
/// drops blank and repeated tags when the app reads them back.
public struct PensSettings: View {
    @Environment(\.notebookTheme) private var theme
    let knownTags: [String]
    @AppStorage(TaskPens.key) private var json = "[]"
    @AppStorage(TaskPens.sortKey) private var sortsLanes = true
    @State private var pens: [TagPen] = []

    public init(knownTags: [String]) { self.knownTags = knownTags }

    public var body: some View {
        Section("Pens") {
            ForEach(pens.indices, id: \.self) { i in
                penRow(i)
            }
            if pens.count < TaskPens.limit {
                Button("Add Pen") {
                    pens.append(TagPen(tag: "", colour: PenColour.allCases.first { c in !pens.contains { $0.colour == c } } ?? .yellow))
                }
            }
            Text("A task carrying a pen's tag is stroked in its colour, in the Tasks tab and on today's page; the tag's chip is left off the row. A task with two penned tags takes the pen higher in the list. Up to \(TaskPens.limit) pens.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Order") {
            Toggle("Sort tasks by pen", isOn: $sortsLanes)
            Text("Each lane lists penned tasks first, pen by pen in the order above, then the rest; priority still orders the tasks within a pen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { pens = decode(json) }
        .onChange(of: pens) { _, pens in
            let encoded = TaskPens.encode(pens)
            if encoded != json { json = encoded }
        }
        // A restore, or another window, rewrote the default.
        .onChange(of: json) { _, json in
            let stored = decode(json)
            if stored != pens { pens = stored }
        }
    }

    private func decode(_ json: String) -> [TagPen] { TaskPens.parse(json) ?? [] }

    private func penRow(_ i: Int) -> some View {
        HStack(spacing: 8) {
            Text("#").foregroundStyle(.secondary)
            TextField("", text: Binding(get: { pens[i].tag }, set: { pens[i].tag = Self.cleaned($0) }), prompt: Text("tag"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 150)
            Menu {
                let penned = Set(pens.map(\.tag))
                ForEach(knownTags.filter { !penned.contains($0) }, id: \.self) { tag in
                    Button("#" + tag) { pens[i].tag = tag }
                }
            } label: { Image(systemName: "tag") }
            .borderlessMenu()
            .help("Pick a tag from the notebook")
            .disabled(knownTags.isEmpty)
            Spacer()
            HStack(spacing: 5) {
                ForEach(PenColour.allCases, id: \.self) { colour in
                    let on = pens[i].colour == colour
                    Circle()
                        .fill(colour.rgba(onDark: false).opacity(1).color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(on ? 0.8 : 0.15), lineWidth: on ? 2 : 0.5))
                        .contentShape(Circle())
                        .onTapGesture { pens[i].colour = colour }
                        .help(colour.title)
                }
            }
            HStack(spacing: 2) {
                Button { pens.swapAt(i, i - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(i == 0).help("Sort earlier")
                Button { pens.swapAt(i, i + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(i == pens.count - 1).help("Sort later")
                Button { pens.remove(at: i) } label: { Image(systemName: "xmark.circle") }
                    .help("Remove the pen")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    /// A tag as typed in a note: no `#`, no spaces.
    private static func cleaned(_ text: String) -> String {
        String(text.drop { $0 == "#" }).filter { !$0.isWhitespace }
    }
}

private extension View {
    /// A menu shown as its icon alone; the borderless style is the Mac's.
    @ViewBuilder
    func borderlessMenu() -> some View {
        #if canImport(AppKit)
        menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        #else
        menuIndicator(.hidden).fixedSize()
        #endif
    }
}

/// A corner of the current theme's paper in one texture, with its name.
struct PaperSwatch: View {
    let texture: PaperTexture
    let theme: NotebookTheme
    let isSelected: Bool

    var body: some View {
        let page = theme.onPaper(texture).page
        VStack(spacing: 4) {
            ZStack {
                page.paperColor.color
                TextureOverlay(tile: page.textureTile, opacity: page.textureOpacity, blend: page.textureBlend)
            }
            .frame(width: 60, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.accentColor : Color.black.opacity(0.15), lineWidth: isSelected ? 2.5 : 0.5))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            Text(texture.title).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
        .help(texture == .none ? "Plain paper" : "\(texture.title) paper")
    }
}

/// A tiny notebook: cover colour, paper and ruling, with the theme's name.
struct ThemeSwatch: View {
    let theme: NotebookTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(theme.cover.baseColor.color)
                TextureOverlay(tile: theme.cover.textureTile, opacity: theme.cover.grainOpacity, blend: theme.cover.blend)
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.page.paperColor.color)
                    .overlay(
                        VStack(spacing: 5) {
                            ForEach(0..<6, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(theme.ink.color.opacity(i == 0 ? 0.75 : 0.3))
                                    .frame(width: i == 0 ? 34 : 54, height: i == 0 ? 3 : 1.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(8)
                    )
                    .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 8))
            }
            .frame(width: 112, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.black.opacity(0.15), lineWidth: isSelected ? 2.5 : 0.5))
            .shadow(color: .black.opacity(theme.flat ? 0 : 0.25), radius: 3, y: 2)
            Text(theme.name).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        }
        .contentShape(Rectangle())
    }
}
