import SwiftUI
import AppKit
import FoolscapCore
import FoolscapEditor
import FoolscapUI

/// The recto of a spread: a page's transcript typeset on the notebook's ruled
/// paper, every line sitting on a rule as the daily note's do, so it reads as the
/// typed twin of the handwritten page beside it. `minHeight` matches it to the
/// facsimile so the two leaves are the same size.
struct ScribeTranscriptSheet: View {
    @Environment(\.notebookTheme) private var theme
    /// nil while the transcript has not been read yet.
    let page: ScribeTranscript.Page?
    let transcriptAvailable: Bool
    let width: CGFloat
    var minHeight: CGFloat = 0

    /// Text column left edge inside the sheet; the margin rule sits
    /// `RulingView.marginRuleOffset` left of it.
    static let textLeft: CGFloat = 28
    static let textRight: CGFloat = 14

    private var pitch: CGFloat { theme.linePitch }
    private var scale: CGFloat { theme.type.body.size / 15 }

    var body: some View {
        let palette = EditorPalette(theme: theme)
        let font = palette.body
        // A body line set in the editor is exactly `pitch` tall; SwiftUI's Text is the
        // font's natural height, so the difference is spread around each line.
        let lineHeight = font.ascender - font.descender + font.leading
        let slack = max(0, pitch - lineHeight)
        ZStack(alignment: .topLeading) {
            theme.page.paperColor.color
            RulingView(pitch: pitch, topInset: PageRuling.ruleOffset(palette), marginX: Self.textLeft)
            VStack(alignment: .leading, spacing: 0) {
                if let page, !page.isEmpty {
                    ForEach(Array(page.paragraphs.enumerated()), id: \.offset) { index, paragraph in
                        if index > 0 { Spacer().frame(height: pitch) }
                        paragraphText(paragraph, font: Font(font))
                            .lineSpacing(slack)
                            .padding(.vertical, slack / 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    Text(transcriptAvailable ? "No handwriting recognised on this page." : "Not read yet — the next sync recognises the handwriting.")
                        .font(.system(size: 13 * scale, design: .serif)).italic().foregroundStyle(theme.dimInk.color)
                        .frame(height: pitch)
                }
            }
            .textSelection(.enabled)
            .padding(.leading, Self.textLeft).padding(.trailing, Self.textRight)
            .padding(.top, PageRuling.rowShift(palette))
            .padding(.bottom, pitch)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: width)
        .frame(minHeight: minHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(theme.ink.color.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
    }

    /// One paragraph as a single Text so wrapped lines share the line spacing;
    /// a TODO marker is set in the accent as it is in the stacked view.
    private func paragraphText(_ paragraph: [ScribeTranscript.Line], font: Font) -> Text {
        var text = Text("")
        for (index, line) in paragraph.enumerated() {
            if index > 0 { text = text + Text("\n") }
            text = text + Self.lineText(line, font: font, accent: theme.accent.color)
        }
        return text
    }

    static func lineText(_ line: ScribeTranscript.Line, font: Font, accent: Color) -> Text {
        if let task = line.task {
            return Text(line.before).font(font)
                + Text("TODO: ").font(font).bold().foregroundColor(accent)
                + Text(task).font(font)
        }
        return Text(line.before).font(font)
    }
}
