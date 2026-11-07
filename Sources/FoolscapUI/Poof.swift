import SwiftUI
import QuartzCore
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The classic Mac "poof": a little cloud of smoke that bursts where something was and
/// thins to nothing, played when a task is ticked done. Drawn by hand (AppKit's own
/// `NSShowAnimationEffect` was deprecated in macOS 14 and the Dock stopped poofing long
/// before), as Core Animation layers in a view of its own, so it outlives the row that
/// asked for it when that row moves to another lane. On the Mac that view lives in a
/// transparent child window over the spot (like the page curl's `PageTurnWindow`): the
/// main window's content view is SwiftUI's hosting view, which never attaches a foreign
/// subview's layer to its layer tree, so a host added there was never drawn (found
/// 2026-11-08). On the phone the window attaches it at once, so the host is a subview.
@MainActor
public enum Poof {
    /// Play a poof centred on `point` in `view`'s coordinates.
    public static func play(in view: PlatformView, at point: CGPoint) {
        #if canImport(AppKit)
        guard let window = view.window else { return }
        PoofWindow.play(over: window, at: view.convert(point, to: nil))
        #else
        guard let root = view.window else { return }
        let centre = root.convert(point, from: view)
        let host = PoofHost(centre: centre)
        root.addSubview(host)
        host.play()
        #endif
    }

    /// Play a poof over the middle of `view`.
    public static func play(over view: PlatformView) {
        play(in: view, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    static let duration: TimeInterval = 0.55
    static let puffs = 9
    static let puffDelay: TimeInterval = 0.012
    /// How long the whole cloud takes, last puff included.
    static var lifetime: TimeInterval { duration + Double(puffs - 1) * puffDelay }
}

#if canImport(AppKit)
/// A transparent, mouse-ignoring child window the size of the cloud, laid over the notebook
/// window where the task was ticked; it holds the `PoofHost` and goes once the smoke has.
final class PoofWindow: NSWindow {
    private static var playing: [PoofWindow] = []
    private weak var notebook: NSWindow?

    /// `point` is in `parent`'s window coordinates.
    static func play(over parent: NSWindow, at point: NSPoint) {
        let e = PoofHost.extent
        let frame = parent.convertToScreen(NSRect(x: point.x - e / 2, y: point.y - e / 2, width: e, height: e))
        let window = PoofWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.fullScreenAuxiliary, .transient]
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        window.contentView = root
        let host = PoofHost(centre: CGPoint(x: e / 2, y: e / 2))
        root.addSubview(host)
        window.notebook = parent
        parent.addChildWindow(window, ordered: .above)
        playing.append(window)
        host.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + Poof.lifetime + 0.1) { window.finish() }
    }

    private func finish() {
        notebook?.removeChildWindow(self)
        orderOut(nil)
        Self.playing.removeAll { $0 === self }
    }
}
#endif

/// The view the cloud is drawn in: it ignores the pointer and removes itself once the smoke has gone.
/// The removal is timed, not the transaction's completion: that fires at once when the layers
/// are not yet in a render tree, which took the view away before a frame was drawn.
final class PoofHost: PlatformView {
    static let extent: CGFloat = 96

    init(centre: CGPoint) {
        let e = Self.extent
        super.init(frame: CGRect(x: centre.x - e / 2, y: centre.y - e / 2, width: e, height: e))
        #if canImport(AppKit)
        wantsLayer = true
        #else
        isUserInteractionEnabled = false
        #endif
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    #if canImport(AppKit)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    func play() {
        #if canImport(AppKit)
        guard let layer else { return }
        #else
        let layer = self.layer
        #endif
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        var generator = SystemRandomNumberGenerator()
        CATransaction.begin()
        for i in 0..<Poof.puffs {
            // Puffs leave the centre in every direction, the first one straight up and larger.
            let angle = CGFloat(i) / CGFloat(Poof.puffs) * 2 * .pi + CGFloat.random(in: -0.25...0.25, using: &generator)
            let reach = CGFloat.random(in: 14...24, using: &generator)
            let radius = i == 0 ? CGFloat(13) : CGFloat.random(in: 7...11, using: &generator)
            let puff = CAShapeLayer()
            puff.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius), transform: nil)
            puff.fillColor = CGColor(gray: 0.93, alpha: 1)
            puff.strokeColor = CGColor(gray: 0.55, alpha: 0.5)
            puff.lineWidth = 0.6
            puff.shadowColor = CGColor(gray: 0, alpha: 1)
            puff.shadowOpacity = 0.18
            puff.shadowRadius = 2
            puff.shadowOffset = .zero
            puff.position = centre
            layer.addSublayer(puff)

            let from = CGPoint(x: centre.x + cos(angle) * reach * 0.25, y: centre.y + sin(angle) * reach * 0.25)
            let to = CGPoint(x: centre.x + cos(angle) * reach, y: centre.y + sin(angle) * reach)
            let delay = Double(i) * Poof.puffDelay
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = from; move.toValue = to
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.35; grow.toValue = 1.25
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 0.9, 0]
            fade.keyTimes = [0, 0.15, 0.5, 1]
            let group = CAAnimationGroup()
            group.animations = [move, grow, fade]
            group.duration = Poof.duration
            group.beginTime = CACurrentMediaTime() + delay
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            puff.opacity = 0
            puff.add(group, forKey: "poof")
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + Poof.lifetime + 0.05) { [weak self] in self?.removeFromSuperview() }
    }
}

/// A hook a SwiftUI view keeps so it can poof where it stands: lay a `PoofAnchor` over the
/// spot and call `play()` on the handle.
@MainActor
public final class PoofHandle {
    weak var view: PlatformView?
    public init() {}
    public func play() {
        guard let view else { return }
        Poof.play(over: view)
    }
}

/// An empty view that lends its place to a `PoofHandle`.
public struct PoofAnchor: View {
    let handle: PoofHandle
    public init(_ handle: PoofHandle) { self.handle = handle }
    public var body: some View {
        PoofAnchorView(handle: handle).allowsHitTesting(false)
    }
}

#if canImport(AppKit)
private struct PoofAnchorView: NSViewRepresentable {
    let handle: PoofHandle
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        handle.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { handle.view = nsView }
}
#else
private struct PoofAnchorView: UIViewRepresentable {
    let handle: PoofHandle
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        handle.view = v
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) { handle.view = uiView }
}
#endif
