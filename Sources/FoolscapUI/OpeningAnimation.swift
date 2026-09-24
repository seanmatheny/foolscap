import SwiftUI
import FoolscapCore

/// The jester silhouette from the app icon, as a SwiftUI shape (1024-unit design space).
public struct JesterShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 1024
        let dx = rect.midX - 512 * scale, dy = rect.midY - 512 * scale
        // Design coordinates have y up; flip into SwiftUI's y-down space.
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + x * scale, y: dy + (1024 - y) * scale) }
        var p = Path()
        func oval(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
            p.addEllipse(in: CGRect(x: pt(cx - r, cy + r).x, y: pt(cx - r, cy + r).y, width: 2 * r * scale, height: 2 * r * scale))
        }
        oval(512, 430, 150)
        p.move(to: pt(352, 470))
        p.addCurve(to: pt(672, 470), control1: pt(380, 700), control2: pt(644, 700))
        p.closeSubpath()
        func horn(_ b1: (CGFloat, CGFloat), _ b2: (CGFloat, CGFloat), _ tip: (CGFloat, CGFloat), _ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat)) {
            p.move(to: pt(b1.0, b1.1))
            p.addCurve(to: pt(tip.0, tip.1), control1: pt(c1.0, c1.1), control2: pt((c1.0 + tip.0) / 2, (c1.1 + tip.1) / 2))
            p.addCurve(to: pt(b2.0, b2.1), control1: pt((c2.0 + tip.0) / 2, (c2.1 + tip.1) / 2), control2: pt(c2.0, c2.1))
            p.closeSubpath()
            oval(tip.0, tip.1, 36)
        }
        horn((372, 520), (470, 630), (140, 560), (300, 560), (250, 800))
        horn((554, 630), (652, 520), (884, 560), (774, 800), (724, 560))
        horn((458, 620), (566, 620), (548, 930), (420, 850), (680, 800))
        let xs: [CGFloat] = [290, 401, 512, 623, 734]
        p.move(to: pt(xs.first! - 34, 310))
        p.addLine(to: pt(xs.last! + 34, 310))
        for (i, x) in xs.reversed().enumerated() {
            p.addLine(to: pt(x, 195))
            if i < xs.count - 1 { p.addLine(to: pt(x - 55, 255)) }
        }
        p.closeSubpath()
        for x in xs { oval(x, 195, 26) }
        return p
    }
}

/// The closed front cover: leather, stitching, and a blind-embossed jester and wordmark.
struct ClosedCoverFace: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge

    var body: some View {
        let mirrored = tabEdge == .left
        let shape = CoverShape(spineOnRight: mirrored)
        ZStack {
            shape.fill(theme.cover.baseColor.color)
            TextureOverlay(tile: theme.cover.textureTile, opacity: theme.cover.grainOpacity, blend: theme.cover.blend)
            shape.fill(LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.25)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 1)],
                           startPoint: mirrored ? .trailing : .leading, endPoint: mirrored ? .leading : .trailing)
                .frame(width: 40)
                .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
            shape.inset(by: 7)
                .stroke(theme.cover.stitchColor.color.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            VStack(spacing: 18) {
                Embossed { JesterShape().aspectRatio(1, contentMode: .fit) }
                    .frame(width: 180, height: 180)
                Embossed { Text("Foolscap").font(.system(size: 30, weight: .semibold, design: .serif)).kerning(2) }
                    .frame(height: 40)
            }
            .offset(y: -10)
        }
        .clipShape(shape)
    }
}

/// Blind emboss: the shape pressed into the leather, lit from the top-left.
struct Embossed<Content: View>: View {
    @Environment(\.notebookTheme) private var theme
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            content.foregroundStyle(Color.white.opacity(theme.isDark ? 0.35 : 0.18)).offset(x: 1.2, y: 1.2)
            content.foregroundStyle(Color.black.opacity(0.55)).offset(x: -1, y: -1)
            content.foregroundStyle(theme.cover.baseColor.color).brightness(-0.06)
        }
    }
}

/// Plays once at launch: the closed cover swings open around the spine.
public struct CoverOpeningOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notebookTabEdge) private var tabEdge
    @AppStorage("openingAnimation") private var enabled = true
    @State private var angle: Double = 0
    @State private var done = false

    public init() {}

    private var progress: Double { min(1, max(0, abs(angle) / 165)) }

    public var body: some View {
        if !done {
            // The hinge is the spine: on the right when the tabs are on the left.
            let spineOnRight = tabEdge == .left
            ZStack {
                // The page darkens under the lifting cover, then brightens as it clears.
                Color.black.opacity(0.35 * (1 - progress) * (progress < 0.5 ? 1 : (1 - (progress - 0.5) * 2)))
                    .allowsHitTesting(false)
                ClosedCoverFace()
                    .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0),
                                      anchor: spineOnRight ? .trailing : .leading, anchorZ: 0, perspective: 0.45)
                    .shadow(color: .black.opacity(0.5 * (1 - progress)), radius: 30, x: spineOnRight ? -24 : 24, y: 0)
            }
            .ignoresSafeArea()
            .onAppear {
                guard enabled, !reduceMotion, !CommandLine.arguments.contains("--no-opening") else { done = true; return }
                // FOOLSCAP_SLOW_OPEN stretches the swing for screenshots.
                let slow = ProcessInfo.processInfo.environment["FOOLSCAP_SLOW_OPEN"] != nil ? 4.0 : 1.0
                withAnimation(.timingCurve(0.55, 0.0, 0.25, 1.0, duration: 1.15 * slow).delay(0.35 * slow)) {
                    angle = spineOnRight ? 165 : -165
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6 * slow) { done = true }
            }
        }
    }
}
