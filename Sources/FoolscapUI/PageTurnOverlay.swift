import SwiftUI
import FoolscapCore

/// A loose page lying on the notebook: the flyleaf shown after the cover
/// opens. A click (or ↩, ⎋) turns it over around the spine, revealing the
/// notebook underneath, which has been there all along.
public struct PageTurnOverlay<Content: View>: View {
    @Environment(\.notebookTheme) private var theme
    @Environment(\.notebookTabEdge) private var tabEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isPresented: Bool
    let content: () -> Content
    @State private var anchor = PageAnchor()
    /// The rigid turn, kept for when the page cannot be photographed.
    @State private var angle: Double = 0
    @State private var turning = false

    public init(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self._isPresented = isPresented
        self.content = content
    }

    public var body: some View {
        if isPresented {
            let windowState = WindowState.shared
            let tabsLeft = tabEdge == .left
            // The hinge is the spine: on the right when the tabs are on the left.
            let spineOnRight = tabsLeft
            let topInset = NotebookMetrics.topMargin + windowState.fullScreenTopInset
            ZStack {
                PageView { content() }
                    .overlay { PageSnapshotHost(anchor: anchor) }
                    .modifier(PageTurnEffect(angle: angle, spineOnRight: spineOnRight))
                    .padding(NotebookMetrics.pageInsets(tabsLeft: tabsLeft))
                    .padding(.top, windowState.fullScreenTopInset)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let edge = anchor.pageHeight.map { (location.y - topInset) / max(1, $0) }
                turn(spineOnRight: spineOnRight, from: edge)
            }
            .background {
                Button("") { turn(spineOnRight: spineOnRight, from: nil) }.keyboardShortcut(.defaultAction).opacity(0)
                Button("") { turn(spineOnRight: spineOnRight, from: nil) }.keyboardShortcut(.cancelAction).opacity(0)
            }
            .ignoresSafeArea()
            .onAppear { PageCurlRenderer.warmUp() }
        }
    }

    /// Turn the page over, curling from `edge` (0 the top corner, 1 the bottom,
    /// nil somewhere) when it can be photographed, rigidly otherwise. The curl
    /// plays in its own window over the notebook, so the flyleaf itself goes
    /// at once and the notebook is there under the turning page.
    private func turn(spineOnRight: Bool, from edge: CGFloat?) {
        guard !turning else { return }
        turning = true
        guard !reduceMotion else { isPresented = false; return }
        let slow = ProcessInfo.processInfo.environment["FOOLSCAP_SLOW_OPEN"] != nil ? 4.0 : 1.0
        if let shot = anchor.capture(),
           anchor.curl(shot.image, style: PageCurlStyle.random(from: edge), spineOnRight: spineOnRight,
                       paper: theme.page.paperColor, duration: 0.55 * slow) {
            isPresented = false
        } else {
            withAnimation(.timingCurve(0.55, 0.0, 0.25, 1.0, duration: 0.55 * slow)) { angle = spineOnRight ? 150 : -150 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 * slow) { isPresented = false }
        }
    }
}

/// A page swinging around the spine: `angle` runs from 0 (lying flat) to ±150
/// (turned over onto the facing side). Animatable, so the blank underside
/// appears at the halfway point rather than fading in over the whole turn.
/// Used by the flyleaf and by the notebook when a tab is chosen.
struct PageTurnEffect: ViewModifier, Animatable {
    @Environment(\.notebookTheme) private var theme
    var angle: Double
    var spineOnRight: Bool

    nonisolated var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    private var progress: Double { min(1, max(0, abs(angle) / 150)) }

    func body(content: Content) -> some View {
        let lifted = progress > 0
        content
            .overlay {
                if progress > 0.5 {
                    theme.page.paperColor.color
                        .overlay(TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity, blend: theme.page.textureBlend))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .overlay(Color.black.opacity(0.28 * progress))
            .allowsHitTesting(!lifted)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0),
                              anchor: spineOnRight ? .trailing : .leading, anchorZ: 0, perspective: 0.45)
            .shadow(color: .black.opacity(0.4 * progress), radius: lifted ? 24 : 0, x: spineOnRight ? -20 : 20, y: 0)
    }
}
