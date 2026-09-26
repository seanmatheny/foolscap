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
    @State private var angle: Double = 0
    @State private var turning = false

    public init(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self._isPresented = isPresented
        self.content = content
    }

    private var progress: Double { min(1, max(0, abs(angle) / 150)) }

    public var body: some View {
        if isPresented {
            let windowState = WindowState.shared
            let tabsLeft = tabEdge == .left
            // The hinge is the spine: on the right when the tabs are on the left.
            let spineOnRight = tabsLeft
            ZStack {
                PageView {
                    ZStack {
                        content()
                        // Past the halfway point the page shows its blank underside.
                        theme.page.paperColor.color
                            .overlay(TextureOverlay(tile: theme.page.textureTile, opacity: theme.page.textureOpacity, blend: theme.page.textureBlend))
                            .opacity(progress > 0.5 ? 1 : 0)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(Color.black.opacity(0.28 * progress).allowsHitTesting(false))
                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0),
                                  anchor: spineOnRight ? .trailing : .leading, anchorZ: 0, perspective: 0.45)
                .shadow(color: .black.opacity(0.4 * progress), radius: 24, x: spineOnRight ? -20 : 20, y: 0)
                .padding(EdgeInsets(top: NotebookMetrics.topMargin,
                                    leading: tabsLeft ? NotebookMetrics.sideMargin : NotebookMetrics.spineMargin,
                                    bottom: NotebookMetrics.bottomMargin,
                                    trailing: tabsLeft ? NotebookMetrics.spineMargin : NotebookMetrics.sideMargin))
                .padding(.top, windowState.fullScreenTopInset)
            }
            .contentShape(Rectangle())
            .onTapGesture { turn(spineOnRight: spineOnRight) }
            .background {
                Button("") { turn(spineOnRight: spineOnRight) }.keyboardShortcut(.defaultAction).opacity(0)
                Button("") { turn(spineOnRight: spineOnRight) }.keyboardShortcut(.cancelAction).opacity(0)
            }
            .ignoresSafeArea()
        }
    }

    private func turn(spineOnRight: Bool) {
        guard !turning else { return }
        turning = true
        guard !reduceMotion else { isPresented = false; return }
        let slow = ProcessInfo.processInfo.environment["FOOLSCAP_SLOW_OPEN"] != nil ? 4.0 : 1.0
        withAnimation(.timingCurve(0.55, 0.0, 0.25, 1.0, duration: 0.7 * slow)) {
            angle = spineOnRight ? 150 : -150
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75 * slow) { isPresented = false }
    }
}
