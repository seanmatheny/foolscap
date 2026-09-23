import SwiftUI
import AppKit

/// Turns the hosting window into a transparent, shadow-casting shape so the
/// notebook itself is the window: no title bar, no background, traffic lights
/// hidden until the pointer hovers the top of the cover.
public struct NotebookWindowChrome: NSViewRepresentable {
    /// Any value; a change triggers a shadow recompute (e.g. tab selection).
    let shapeVersion: AnyHashable

    public init(shapeVersion: AnyHashable) { self.shapeVersion = shapeVersion }

    public func makeNSView(context: Context) -> ChromeView { ChromeView() }

    public func updateNSView(_ view: ChromeView, context: Context) {
        view.configureIfNeeded()
        DispatchQueue.main.async { view.window?.invalidateShadow() }
    }

    public final class ChromeView: NSView {
        private var configured = false

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureIfNeeded()
        }

        func configureIfNeeded() {
            guard !configured, let window else { return }
            configured = true
            window.styleMask.insert(.fullSizeContentView)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            window.toolbar = nil
            TrafficLights.set(window: window, visible: false, animated: false)
            DispatchQueue.main.async { window.invalidateShadow() }
        }
    }
}

public enum TrafficLights {
    private static let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    @MainActor
    public static func set(window: NSWindow?, visible: Bool, animated: Bool = true) {
        guard let window else { return }
        let views = buttons.compactMap { window.standardWindowButton($0) }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                views.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
            }
        } else {
            views.forEach { $0.alphaValue = visible ? 1 : 0 }
        }
    }
}

/// A hover zone that reveals the traffic lights while the pointer is over it.
public struct TrafficLightHoverZone: View {
    @State private var window: NSWindow?
    public init() {}
    public var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .background(WindowFinder { window = $0 })
            .onHover { TrafficLights.set(window: window, visible: $0) }
    }
}

struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow) -> Void
    func makeNSView(context: Context) -> Finder { let f = Finder(); f.found = found; return f }
    func updateNSView(_ v: Finder, context: Context) {}
    final class Finder: NSView {
        var found: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found?(window) }
        }
    }
}
