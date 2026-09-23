import SwiftUI
import AppKit

/// Turns the hosting window into a transparent, shadow-casting shape so the
/// notebook itself is the window: no title bar, no background, traffic lights
/// hidden until the pointer hovers the top of the cover.
public struct NotebookWindowChrome: NSViewRepresentable {
    /// Any value; a change triggers a shadow recompute (e.g. tab selection).
    let shapeVersion: AnyHashable
    /// Painted behind the cover while full screen (the window is opaque there).
    let coverColor: NSColor

    public init(shapeVersion: AnyHashable, coverColor: NSColor) {
        self.shapeVersion = shapeVersion
        self.coverColor = coverColor
    }

    public func makeNSView(context: Context) -> ChromeView { ChromeView() }

    public func updateNSView(_ view: ChromeView, context: Context) {
        view.coverColor = coverColor
        view.configureIfNeeded()
        DispatchQueue.main.async { view.window?.invalidateShadow() }
    }

    /// Answers the full-screen presentation question for SwiftUI's own window
    /// delegate and forwards everything else to it untouched.
    final class DelegateProxy: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        override func responds(to sel: Selector!) -> Bool { super.responds(to: sel) || (original?.responds(to: sel) ?? false) }
        override func forwardingTarget(for sel: Selector!) -> Any? { original }
        func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposed: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
            proposed.union([.autoHideMenuBar, .autoHideDock])
        }
    }

    public final class ChromeView: NSView {
        private var configured = false
        var coverColor: NSColor = .black
        private var proxy: DelegateProxy?

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
            window.toolbar = nil
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.isMovableByWindowBackground = true
            TrafficLights.set(window: window, visible: false, animated: false)
            DispatchQueue.main.async { window.invalidateShadow() }
            // Native full screen: menu bar and Dock slide away like any other app.
            installProxy(on: window)
            NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.installProxy(on: window)
                    window.isOpaque = true
                    window.backgroundColor = self.coverColor
                }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let window = self?.window else { return }
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.invalidateShadow()
                }
            }
        }

        private func installProxy(on window: NSWindow) {
            if let proxy, window.delegate === proxy { return }
            let p = DelegateProxy()
            p.original = window.delegate
            window.delegate = p
            proxy = p
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
