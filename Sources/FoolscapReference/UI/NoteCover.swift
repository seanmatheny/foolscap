import SwiftUI
import FoolscapCore
import FoolscapUI

/// A Reference note as a little cloth-bound notebook: the cloth and its pattern, a
/// quarter-bound spine, the icon or monogram pressed into the board and a paper label
/// with the title. 3:4, drawn at any width.
struct NoteCover: View {
    @Environment(\.notebookTheme) private var theme
    let cover: ResolvedCover
    let title: String
    var width: CGFloat = 112
    var showsLabel = true

    private var height: CGFloat { (width * 4 / 3).rounded() }

    var body: some View {
        let cloth = cover.cloth.rgba(onDark: theme.isDark)
        let spine = max(6, width * 0.11)
        ZStack(alignment: .topLeading) {
            cloth.color
            CoverPatternView(pattern: cover.pattern, cloth: cloth, width: width)
                .padding(.leading, spine)
            if !theme.flat {
                TextureOverlay(tile: "leather-grain", opacity: 0.45, blend: .softLight)
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.18)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            // Quarter binding: a darker strip of cloth round the spine.
            Rectangle().fill(cloth.mixed(with: .hex(0x000000), fraction: theme.flat ? 0.22 : 0.32).color)
                .frame(width: spine)
            if !theme.flat {
                LinearGradient(colors: [.black.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: spine * 0.7)
                    .offset(x: spine)
                Rectangle().fill(.white.opacity(0.12)).frame(width: 0.5).offset(x: spine)
            }
            // The stamp sits at the same height on every cover, however long the label.
            stamp(cloth: cloth)
                .frame(width: width * 0.5, height: width * 0.36)
                .position(x: spine + (width - spine) / 2, y: showsLabel ? height * 0.36 : height / 2)
            if showsLabel {
                label(cloth: cloth)
                    .position(x: spine + (width - spine) / 2, y: height * 0.76)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: max(2, width / 40)))
        // The grain's blend resolves inside the cover, not against the shelf's shadow layer
        // (which showed it as a pale box round each cover).
        .compositingGroup()
        .overlay(RoundedRectangle(cornerRadius: max(2, width / 40)).stroke(Color.black.opacity(0.2), lineWidth: 0.5))
    }

    @ViewBuilder private func stamp(cloth: RGBA) -> some View {
        let depth = max(0.5, width / 150)
        if let symbol = cover.symbol {
            Embossed(depth: depth, base: cloth) {
                Image(systemName: symbol).resizable().aspectRatio(contentMode: .fit)
            }
        } else {
            Embossed(depth: depth, base: cloth) {
                Text(cover.monogram)
                    .font(theme.type.heading.face(width * (cover.monogram.count > 1 ? 0.26 : 0.32), weight: .bold))
                    .kerning(width / 80)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    /// A cream label stuck on the board, like an exercise book's; printed in a pale tint
    /// of the cloth on a flat theme.
    private func label(cloth: RGBA) -> some View {
        let paper: RGBA = theme.flat ? cloth.mixed(with: .hex(0xFFFFFF), fraction: 0.82)
            : (theme.isDark ? .hex(0xE4DDC9) : .hex(0xF5EFDD))
        let ink: RGBA = theme.flat ? cloth.mixed(with: .hex(0x000000), fraction: 0.55) : .hex(0x2A2622)
        return Text(title)
            .font(theme.type.body.face(max(8, width / 10.5), weight: .semibold))
            .foregroundStyle(ink.color)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, width * 0.05).padding(.vertical, width * 0.035)
            .frame(width: width * 0.66)
            .frame(minHeight: width * 0.2)
            .background(
                RoundedRectangle(cornerRadius: 1.5).fill(paper.color)
                    .overlay(RoundedRectangle(cornerRadius: 1.5).inset(by: width * 0.018)
                        .stroke(ink.color.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: .black.opacity(theme.flat ? 0 : 0.25), radius: 0.5, y: 0.5)
            )
    }
}

/// The cloth's figure, drawn faintly in a tint of the cloth: light on a dark cloth,
/// dark on a light one.
struct CoverPatternView: View {
    let pattern: CoverPattern
    let cloth: RGBA
    let width: CGFloat

    var body: some View {
        let luminance = 0.2126 * cloth.r + 0.7152 * cloth.g + 0.0722 * cloth.b
        let ink = luminance > 0.42 ? Color.black.opacity(0.13) : Color.white.opacity(0.11)
        let s = max(4, width / 11)
        let line = max(0.5, width / 160)
        Canvas { context, size in
            Self.draw(pattern, in: &context, size: size, step: s, line: line, ink: ink)
        }
    }

    static func draw(_ pattern: CoverPattern, in context: inout GraphicsContext, size: CGSize, step s: CGFloat, line: CGFloat, ink: Color) {
        var path = Path()
        let w = size.width, h = size.height
        switch pattern {
        case .plain:
            return
        case .pinstripe:
            var x = s / 2
            while x < w { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)); x += s * 0.7 }
            context.stroke(path, with: .color(ink), lineWidth: line)
        case .dots:
            var row = 0
            var y = s / 2
            while y < h + s {
                var x = (row % 2 == 0 ? s / 2 : s)
                while x < w + s {
                    let r = s * 0.11
                    path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += s
                }
                y += s * 0.85; row += 1
            }
            context.fill(path, with: .color(ink))
        case .chevron:
            var y: CGFloat = 0
            while y < h + s {
                var x: CGFloat = 0
                path.move(to: CGPoint(x: 0, y: y))
                while x < w + s {
                    path.addLine(to: CGPoint(x: x + s / 2, y: y - s * 0.35))
                    path.addLine(to: CGPoint(x: x + s, y: y))
                    x += s
                }
                y += s * 0.8
            }
            context.stroke(path, with: .color(ink), lineWidth: line)
        case .grid:
            let g = s * 1.1
            var x = g / 2
            while x < w { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)); x += g }
            var y = g / 2
            while y < h { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)); y += g }
            context.stroke(path, with: .color(ink), lineWidth: line * 0.8)
        case .diagonal:
            var x = -h
            while x < w { path.move(to: CGPoint(x: x, y: h)); path.addLine(to: CGPoint(x: x + h, y: 0)); x += s * 0.75 }
            context.stroke(path, with: .color(ink), lineWidth: line)
        case .waves:
            var y = s / 2
            while y < h + s {
                path.move(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                while x < w {
                    path.addQuadCurve(to: CGPoint(x: x + s, y: y), control: CGPoint(x: x + s / 2, y: y - s * 0.45))
                    path.addQuadCurve(to: CGPoint(x: x + 2 * s, y: y), control: CGPoint(x: x + 1.5 * s, y: y + s * 0.45))
                    x += 2 * s
                }
                y += s * 0.8
            }
            context.stroke(path, with: .color(ink), lineWidth: line)
        case .herringbone:
            let c = s * 0.8
            var column = 0
            var x: CGFloat = 0
            while x < w + c {
                var y: CGFloat = -c
                while y < h + c {
                    if column % 2 == 0 {
                        path.move(to: CGPoint(x: x, y: y)); path.addLine(to: CGPoint(x: x + c, y: y + c))
                    } else {
                        path.move(to: CGPoint(x: x, y: y + c)); path.addLine(to: CGPoint(x: x + c, y: y))
                    }
                    y += c * 0.5
                }
                x += c; column += 1
            }
            context.stroke(path, with: .color(ink), lineWidth: line)
        }
    }
}
