import AppKit
import LinkPresentation
import FoolscapCore
import FoolscapStore

/// Places real views (images, link cards) under the markdown lines that
/// reference them. The text storage is untouched: the styler reserves space
/// below the line with paragraph spacing, and this controller positions a
/// subview in that space after each layout pass.
@MainActor
final class OverlayController {
    unowned let textView: MarkdownTextView
    private var overlays: [String: Overlay] = [:]      // keyed by image path or URL
    private var imageCache: [String: NSImage] = [:]

    nonisolated static let maxImageHeight: CGFloat = 320
    nonisolated static let linkCardHeight: CGFloat = 96
    nonisolated static let linkCardMaxWidth: CGFloat = 520

    final class Overlay {
        let key: String
        let view: NSView
        var lineIndex: Int
        /// Natural size; images scale to the available width, cards keep a fixed height.
        let naturalSize: NSSize
        let isImage: Bool
        /// Width the user chose by dragging, stored in the markdown as `|width`.
        var requestedWidth: CGFloat?
        init(key: String, view: NSView, lineIndex: Int, naturalSize: NSSize, isImage: Bool, requestedWidth: CGFloat? = nil) {
            self.key = key; self.view = view; self.lineIndex = lineIndex; self.naturalSize = naturalSize
            self.isImage = isImage; self.requestedWidth = requestedWidth
        }

        func displaySize(availableWidth: CGFloat) -> NSSize {
            if isImage {
                let maxWidth = min(availableWidth, requestedWidth ?? .greatestFiniteMagnitude)
                let cap = requestedWidth == nil ? OverlayController.maxImageHeight : .greatestFiniteMagnitude
                let scale = min(1, min(maxWidth / naturalSize.width, cap / naturalSize.height))
                return NSSize(width: (naturalSize.width * scale).rounded(), height: (naturalSize.height * scale).rounded())
            }
            return NSSize(width: min(availableWidth, naturalSize.width), height: naturalSize.height)
        }
    }

    init(textView: MarkdownTextView) { self.textView = textView }

    /// Recompute the overlay set from the block map; returns true when
    /// paragraph spacing needs to change (caller restyles).
    @discardableResult
    func sync(map: BlockMap) -> Bool {
        var wanted: [(key: String, line: ScannedLine)] = []
        var widths: [String: CGFloat?] = [:]
        for line in map.lines {
            switch line.kind {
            case .imageLine(let alt, let path):
                wanted.append(("img:" + path, line))
                widths["img:" + path] = BlockMap.imageAlt(alt).width.map { CGFloat($0) }
            case .urlLine(let url): wanted.append(("url:" + url, line))
            default: break
            }
        }
        var seen = Set<String>()
        var heights: [Int: CGFloat] = [:]
        var changed = false
        for (key, line) in wanted {
            seen.insert(key)
            let overlay: Overlay
            if let existing = overlays[key] {
                overlay = existing
                if overlay.lineIndex != line.index { overlay.lineIndex = line.index; changed = true }
                if let w = widths[key], overlay.requestedWidth != w { overlay.requestedWidth = w; changed = true }
            } else {
                guard let made = makeOverlay(key: key, line: line) else { continue }
                overlay = made
                overlays[key] = overlay
                textView.addSubview(overlay.view)
                changed = true
            }
            heights[line.index] = overlay.displaySize(availableWidth: availableWidth()).height + 8
        }
        for (key, overlay) in overlays where !seen.contains(key) {
            overlay.view.removeFromSuperview()
            overlays[key] = nil
            changed = true
        }
        if heights != textView.styler.overlayHeights {
            textView.styler.overlayHeights = heights
            changed = true
        }
        return changed
    }

    private func makeOverlay(key: String, line: ScannedLine) -> Overlay? {
        switch line.kind {
        case .imageLine(let alt, let path):
            guard let image = loadImage(path) else { return nil }
            let iv = ResizableImageView(image: image)
            iv.toolTip = path
            iv.onResize = { [weak self] width in self?.commitWidth(width, path: path) }
            return Overlay(key: key, view: iv, lineIndex: line.index, naturalSize: image.size, isImage: true,
                           requestedWidth: BlockMap.imageAlt(alt).width.map { CGFloat($0) })
        case .urlLine(let urlString):
            guard let url = URL(string: urlString) else { return nil }
            let card = LPLinkView(url: url)
            card.frame = NSRect(x: 0, y: 0, width: Self.linkCardMaxWidth, height: Self.linkCardHeight)
            LinkPreviewCache.shared.metadata(for: url) { [weak card] metadata in
                guard let card, let metadata else { return }
                card.metadata = metadata
            }
            return Overlay(key: key, view: card, lineIndex: line.index,
                           naturalSize: NSSize(width: Self.linkCardMaxWidth, height: Self.linkCardHeight), isImage: false)
        default:
            return nil
        }
    }

    private func availableWidth() -> CGFloat {
        max(120, textView.bounds.width - textView.textContainerInset.width * 2)
    }

    private func loadImage(_ path: String) -> NSImage? {
        if let img = imageCache[path] { return img }
        let base = textView.document.url.deletingLastPathComponent()
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
        if ICloudPlaceholders.isPlaceholder(url) { ICloudPlaceholders.startDownload(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 1800,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        // Points: treat the thumbnail as 2x so screenshots do not look enormous.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? CGFloat) ?? CGFloat(cg.width)
        let scale: CGFloat = pixelWidth > 1400 ? 2 : 1
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
        imageCache[path] = img
        return img
    }

    /// Position every overlay under its line. Called from the text view's layout().
    /// Returns true if reserved heights are stale (the width changed) and a restyle is needed.
    @discardableResult
    func reposition() -> Bool {
        let map = textView.styler.blockMap
        let width = availableWidth()
        var stale = false
        for overlay in overlays.values {
            guard overlay.lineIndex < map.lines.count,
                  let frame = textView.fragmentRect(for: map.lines[overlay.lineIndex].range) else {
                overlay.view.isHidden = true; continue
            }
            overlay.view.isHidden = false
            let size = overlay.displaySize(availableWidth: width)
            if textView.styler.overlayHeights[overlay.lineIndex] != size.height + 8 { stale = true }
            let x = textView.textContainerInset.width
            let y = frame.maxY - size.height - 4
            overlay.view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        }
        return stale
    }

    /// Write the chosen width back into the image line as `![alt|width](path)`.
    private func commitWidth(_ width: CGFloat, path: String) {
        guard let overlay = overlays["img:" + path], overlay.lineIndex < textView.styler.blockMap.lines.count else { return }
        let line = textView.styler.blockMap.lines[overlay.lineIndex]
        guard case .imageLine(let rawAlt, _) = line.kind else { return }
        let (alt, _) = BlockMap.imageAlt(rawAlt)
        let natural = overlay.naturalSize.width
        let chosen: Double? = abs(width - natural) < 4 ? nil : Double(min(width, natural))
        let replacement = BlockMap.imageLine(alt: alt, width: chosen, path: path)
        guard replacement != line.text, textView.shouldChangeText(in: line.range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: line.range, with: replacement)
        textView.didChangeText()
    }

    func invalidateImage(_ path: String) { imageCache[path] = nil; overlays["img:" + path]?.view.removeFromSuperview(); overlays["img:" + path] = nil }
}


/// An image with a drag handle in its bottom-right corner. Dragging scales the
/// image (aspect kept); releasing reports the new width.
final class ResizableImageView: NSView {
    let imageView = NSImageView()
    var onResize: ((CGFloat) -> Void)?
    private var dragStart: (point: NSPoint, width: CGFloat)?
    private var showHandle = false
    private var trackingArea: NSTrackingArea?
    static let handleSize: CGFloat = 18

    init(image: NSImage) {
        super.init(frame: NSRect(origin: .zero, size: image.size))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = bounds
        addSubview(imageView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var handleRect: NSRect {
        NSRect(x: bounds.maxX - Self.handleSize, y: bounds.minY, width: Self.handleSize, height: Self.handleSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { showHandle = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { showHandle = false; needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        (handleRect.contains(p) ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showHandle || dragStart != nil else { return }
        let r = handleRect.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.maxX, y: r.minY + r.height)); path.line(to: NSPoint(x: r.maxX - r.width, y: r.minY))
        path.move(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.5)); path.line(to: NSPoint(x: r.maxX - r.width * 0.5, y: r.minY))
        NSColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = 2.5; path.stroke()
        NSColor.black.withAlphaComponent(0.6).setStroke(); path.lineWidth = 1; path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard handleRect.contains(p) else { super.mouseDown(with: event); return }
        dragStart = (convert(event.locationInWindow, to: nil), frame.width)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let image = imageView.image else { return }
        let now = convert(event.locationInWindow, to: nil)
        let width = max(80, start.width + (now.x - start.point.x))
        let aspect = image.size.height / max(1, image.size.width)
        setFrameSize(NSSize(width: width, height: (width * aspect).rounded()))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { super.mouseUp(with: event); return }
        dragStart = nil
        onResize?(frame.width)
    }
}
