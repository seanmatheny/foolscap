import SwiftUI
import AppKit
import FoolscapCore

/// Where a page curls from and how tightly. Drawn afresh for every turn, so no
/// two turns are quite alike; a click near a corner curls the page from there.
public struct PageCurlStyle: Sendable {
    /// The fold's lean at the start, in radians: positive lifts the top corner
    /// first, negative the bottom, zero lifts the whole free edge together.
    public var tilt: Double
    public var startRadius: Double
    public var endRadius: Double

    /// `edgeFraction` is where along the free edge the turn was asked for, 0 at
    /// the top; nil (a menu, a key) picks somewhere.
    public static func random(from edgeFraction: CGFloat?) -> PageCurlStyle {
        let along = edgeFraction.map { min(1, max(0, Double($0))) } ?? Double.random(in: 0.15...0.85)
        let lean = (0.5 - along) * 2
        return PageCurlStyle(tilt: lean * (38 * .pi / 180) + Double.random(in: -0.1...0.1),
                             startRadius: Double.random(in: 30...55), endRadius: Double.random(in: 80...130))
    }
}

/// The fold at one moment of a turn, in page coordinates with the free edge at
/// x = 0. It starts touching the corner that lifts first, sweeps across the
/// page straightening as it goes, and ends past the spine by `overshoot` and
/// the roll's radius, so the turned page has left the window.
struct PageCurlGeometry {
    /// Unit normal to the fold, pointing at the lifted side.
    var axis: SIMD2<Double>
    /// The fold: the points with dot(p, axis) == line.
    var line: Double
    var radius: Double

    init(style: PageCurlStyle, size: CGSize, progress: Double, overshoot: Double) {
        let lean = style.tilt * (1 - progress)
        let normal = SIMD2(-cos(lean), -sin(lean))
        let w = Double(size.width), h = Double(size.height)
        let dots = [SIMD2(0, 0), SIMD2(w, 0), SIMD2(0, h), SIMD2(w, h)].map { ($0 * normal).sum() }
        axis = normal
        radius = style.startRadius + (style.endRadius - style.startRadius) * progress
        let maxDot = dots.max()!, minDot = dots.min()!
        line = maxDot - progress * (maxDot - minDot + overshoot + radius)
    }
}

/// The turn's pace: the cubic Bézier (0.55, 0, 0.25, 1), slow to lift, quick
/// across, easing down.
enum PageTurnPace {
    static func eased(_ x: Double) -> Double {
        let (x1, y1, x2, y2) = (0.55, 0.0, 0.25, 1.0)
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<24 {
            if bx(t) < x { lo = t } else { hi = t }
            t = (lo + hi) / 2
        }
        return by(t)
    }
}

/// Whether turn timings are logged (`FOOLSCAP_TURN_LOG=1`).
let pageTurnLogging = ProcessInfo.processInfo.environment["FOOLSCAP_TURN_LOG"] != nil

/// The AppKit side of a page: where it is in the window, a photograph of what
/// is on screen there, and the child window a turn plays in. Lay
/// `PageSnapshotHost` over the page; it takes no clicks.
@MainActor
public final class PageAnchor {
    weak var view: PageSnapshotView?
    /// The turn under way, if any; it closes itself when done.
    weak var turn: PageTurnWindow?
    public init() {}

    /// The page as it is on screen right now, and its size in points.
    func capture() -> (image: CGImage, size: CGSize)? {
        guard let view, let image = view.capture() else { return nil }
        return (image, view.bounds.size)
    }

    var pageHeight: CGFloat? { view?.bounds.height }

    /// Curl `image` (a photograph of this page) away over the spine, in a
    /// window of its own over the notebook; any turn still going ends first.
    /// Returns false when there is nothing to draw with yet.
    func curl(_ image: CGImage, style: PageCurlStyle, spineOnRight: Bool, paper: RGBA, duration: TimeInterval) -> Bool {
        turn?.finish()
        guard let pipeline = PageCurlRenderer.pipeline, let view, let window = view.window, let content = window.contentView,
              let started = PageTurnWindow(over: window, pageRect: view.convert(view.bounds, to: content), paper: paper)
        else { return false }
        turn = started
        started.play(image, pipeline: pipeline, style: style, spineOnRight: spineOnRight, paper: paper, duration: duration)
        return true
    }
}

struct PageSnapshotHost: NSViewRepresentable {
    let anchor: PageAnchor

    func makeNSView(context: Context) -> PageSnapshotView {
        let view = PageSnapshotView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: PageSnapshotView, context: Context) { anchor.view = view }
}

final class PageSnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Everything on screen within this view's frame, at the display's scale.
    /// The window server has the composited window ready (an app may read its
    /// own windows), which is fast; drawing the view tree again through Core
    /// Graphics is the slow way round, kept for when that is not available.
    func capture() -> CGImage? {
        guard let window else { return nil }
        let started = CACurrentMediaTime()
        defer { if pageTurnLogging { NSLog("Foolscap turn: photograph %.1f ms", (CACurrentMediaTime() - started) * 1000) } }
        if let image = captureFromWindowServer(window) { return image }
        return captureByDrawing(window)
    }

    /// `CGWindowListCreateImage`, which the SDK no longer offers to Swift but
    /// CoreGraphics still exports: an app may read its own windows with it,
    /// no screen-recording leave needed, and it is the composited pixels.
    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    private static let windowImage: WindowImageFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: WindowImageFunction.self)
    }()

    private func captureFromWindowServer(_ window: NSWindow) -> CGImage? {
        guard let windowImage = Self.windowImage else { return nil }
        let screenRect = window.convertToScreen(convert(bounds, to: nil))
        // Quartz counts from the top-left of the primary display.
        guard let primary = NSScreen.screens.first else { return nil }
        let quartz = CGRect(x: screenRect.minX, y: primary.frame.maxY - screenRect.maxY, width: screenRect.width, height: screenRect.height)
        let includingWindow: UInt32 = 1 << 3, ignoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        guard let image = windowImage(quartz, includingWindow, UInt32(window.windowNumber), ignoreFraming | bestResolution)?.takeRetainedValue(),
              image.width > 1, image.height > 1, Self.hasContent(image) else {
            if pageTurnLogging { NSLog("Foolscap turn: the window server gave no photograph; drawing instead") }
            return nil
        }
        return image
    }

    private func captureByDrawing(_ window: NSWindow) -> CGImage? {
        guard let content = window.contentView else { return nil }
        let rect = convert(bounds, to: content)
        guard rect.width > 1, rect.height > 1, let rep = content.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        content.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
    }

    /// Without leave to read the window, the window server hands back an empty
    /// image; a page always has something in the middle.
    private static func hasContent(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let length = CFDataGetLength(data)
        for (fx, fy) in [(0.5, 0.5), (0.2, 0.2), (0.8, 0.8)] {
            let offset = Int(Double(image.height) * fy) * image.bytesPerRow + Int(Double(image.width) * fx) * 4
            guard offset + 4 <= length else { continue }
            if (0..<4).contains(where: { bytes[offset + $0] != 0 }) { return true }
        }
        return false
    }
}

/// A page in flight: a transparent child window over the notebook, clipped to
/// it, that the curl is drawn into from its own thread. Under the curl lies a
/// blank sheet of the paper, standing in for the new page until the notebook
/// has drawn it. The window closes itself when the turn ends.
@MainActor
public final class PageTurnWindow: NSWindow {
    private let metalLayer = CAMetalLayer()
    private let blank = CALayer()
    private let pageInWindow: NSRect
    private var animator: PageCurlAnimator?
    private weak var notebook: NSWindow?
    /// Turns under way, held here until they end.
    private static var playing: [PageTurnWindow] = []

    /// `pageRect` is the page in `parent`'s content view coordinates.
    init?(over parent: NSWindow, pageRect: NSRect, paper: RGBA) {
        guard let content = parent.contentView, pageRect.width > 1, pageRect.height > 1 else { return nil }
        let size = pageRect.size
        // Room for the turned flap over the leather, the shadow and the facing side.
        let padX = NotebookMetrics.facingWidth + 140, padY = size.height * 0.4
        let screenPadded = parent.convertToScreen(content.convert(pageRect.insetBy(dx: -padX, dy: -padY), to: nil))
        let frame = screenPadded.intersection(parent.frame)
        let screenPage = parent.convertToScreen(content.convert(pageRect, to: nil))
        guard frame.width > 1, frame.height > 1 else { return nil }
        pageInWindow = NSRect(x: screenPage.minX - frame.minX, y: screenPage.minY - frame.minY, width: size.width, height: size.height)
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .transient]
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        contentView = root
        let scale = parent.backingScaleFactor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blank.frame = pageInWindow
        blank.backgroundColor = CGColor(srgbRed: paper.r, green: paper.g, blue: paper.b, alpha: 1)
        blank.cornerRadius = 3
        metalLayer.frame = root.bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: root.bounds.width * scale, height: root.bounds.height * scale)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        root.layer?.addSublayer(blank)
        root.layer?.addSublayer(metalLayer)
        CATransaction.commit()
        notebook = parent
        parent.addChildWindow(self, ordered: .above)
        Self.playing.append(self)
    }

    fileprivate func play(_ image: CGImage, pipeline: PageCurlRenderer.Pipeline, style: PageCurlStyle,
                          spineOnRight: Bool, paper: RGBA, duration: TimeInterval) {
        metalLayer.device = pipeline.device
        metalLayer.colorspace = image.colorSpace
        let scale = Double(metalLayer.contentsScale)
        // The shader counts from the top-left.
        let origin = CGPoint(x: pageInWindow.minX, y: metalLayer.bounds.height - pageInWindow.maxY)
        let animator = PageCurlAnimator(pipeline: pipeline, layer: metalLayer, image: image, frame: .init(
            origin: origin, size: pageInWindow.size, scale: scale, spineOnRight: spineOnRight,
            paper: paper, style: style, duration: duration))
        self.animator = animator
        // The window and its layers reach the window server before the first frame does.
        CATransaction.flush()
        animator.start { [weak self] in self?.finish() }
        // The notebook swaps the page in this same pass; the blank goes once it has drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.blank.isHidden = true
            CATransaction.commit()
            if pageTurnLogging { NSLog("Foolscap turn: notebook drew the new page") }
        }
    }

    func finish() {
        animator?.cancel()
        animator = nil
        notebook?.removeChildWindow(self)
        orderOut(nil)
        Self.playing.removeAll { $0 === self }
    }
}
