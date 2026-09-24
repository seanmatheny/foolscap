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
    private var overlays: [Key: Overlay] = [:]
    /// Decoded thumbnails by image path; bounded, since each is up to 1800 px.
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()
    /// Display sizes read from image headers, so space is reserved before decoding.
    private var imageSizes: [String: NSSize] = [:]
    private var decoding: Set<String> = []
    /// Images that could not be read, and when: not retried on every styling pass.
    private var failures: [String: Date] = [:]
    private static let failureRetryInterval: TimeInterval = 10

    nonisolated static let maxImageHeight: CGFloat = 320
    nonisolated static let linkCardHeight: CGFloat = 96
    nonisolated static let linkCardMaxWidth: CGFloat = 520

    /// An overlay's identity: its image path or URL, and which occurrence of it
    /// in the note (the same picture can appear twice). Line numbers are not part
    /// of it, so typing above an overlay moves it instead of rebuilding it.
    struct Key: Hashable {
        var target: String      // "img:" + path or "url:" + URL
        var occurrence: Int
    }

    final class Overlay {
        let key: Key
        let view: NSView
        var lineIndex: Int
        /// Natural size; images scale to the available width, cards keep a fixed height.
        var naturalSize: NSSize
        let isImage: Bool
        /// Width the user chose by dragging, stored in the markdown as `|width`.
        var requestedWidth: CGFloat?
        init(key: Key, view: NSView, lineIndex: Int, naturalSize: NSSize, isImage: Bool, requestedWidth: CGFloat? = nil) {
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
        var wanted: [(key: Key, line: ScannedLine, width: CGFloat?)] = []
        var occurrences: [String: Int] = [:]
        func key(_ target: String) -> Key {
            let n = occurrences[target, default: 0]
            occurrences[target] = n + 1
            return Key(target: target, occurrence: n)
        }
        for line in map.lines {
            switch line.kind {
            case .imageLine(let alt, let path):
                wanted.append((key("img:" + path), line, BlockMap.imageAlt(alt).width.map { CGFloat($0) }))
            case .urlLine(let url): wanted.append((key("url:" + url), line, nil))
            default: break
            }
        }
        var seen = Set<Key>()
        var heights: [Int: CGFloat] = [:]
        var changed = false
        for (key, line, width) in wanted {
            seen.insert(key)
            let overlay: Overlay
            if let existing = overlays[key] {
                overlay = existing
                if overlay.lineIndex != line.index { overlay.lineIndex = line.index; changed = true }
                if overlay.isImage, overlay.requestedWidth != width { overlay.requestedWidth = width; changed = true }
            } else {
                guard let made = makeOverlay(key: key, line: line) else { continue }
                overlay = made
                overlays[key] = overlay
                textView.addSubview(overlay.view)
                changed = true
            }
            heights[line.index] = reserved(for: overlay.displaySize(availableWidth: availableWidth()).height)
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

    /// Total height of an overlay paragraph (its collapsed line plus the picture),
    /// rounded up to whole ruled lines so the text after it stays on the ruling.
    private func reserved(for height: CGFloat) -> CGFloat {
        let pitch = textView.palette.pitch
        return (ceil((height + 10) / pitch)) * pitch
    }

    private func makeOverlay(key: Key, line: ScannedLine) -> Overlay? {
        switch line.kind {
        case .imageLine(let alt, let path):
            let image = imageCache.object(forKey: path as NSString)
            guard let size = image?.size ?? imageSize(path) else { return nil }
            let iv = ResizableImageView(image: image, size: size, path: path)
            iv.onResize = { [weak self] width in self?.commitWidth(width, key: key) }
            iv.onReveal = { [weak self] in self?.revealLine(forKey: key) }
            if image == nil { decode(path) }
            return Overlay(key: key, view: iv, lineIndex: line.index, naturalSize: size, isImage: true,
                           requestedWidth: BlockMap.imageAlt(alt).width.map { CGFloat($0) })
        case .urlLine(let urlString):
            guard let url = URL(string: urlString) else { return nil }
            let card = LinkCardView(url: url)
            card.onReveal = { [weak self] in self?.revealLine(forKey: key) }
            if let metadata = LinkPreviewCache.shared.cached(url) {
                card.linkView.metadata = metadata
            } else {
                // A URL being typed makes a new card per keystroke: only fetch
                // for one that is still in place after a short pause.
                Task { @MainActor [weak card] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let card, card.superview != nil else { return }
                    LinkPreviewCache.shared.metadata(for: url) { [weak card] metadata in
                        guard let card, let metadata else { return }
                        card.linkView.metadata = metadata
                    }
                }
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

    // MARK: Images

    private func fileURL(_ path: String) -> URL {
        let base = textView.document.url.deletingLastPathComponent()
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path).standardizedFileURL
    }

    /// The picture's display size from its header (no decoding), or nil if it
    /// cannot be read; failures are remembered for a while.
    private func imageSize(_ path: String) -> NSSize? {
        if let size = imageSizes[path] { return size }
        if let failed = failures[path], Date().timeIntervalSince(failed) < Self.failureRetryInterval { return nil }
        let url = fileURL(path)
        if ICloudPlaceholders.isPlaceholder(url) { ICloudPlaceholders.startDownload(url) }
        guard let size = Self.headerSize(url) else { failures[path] = Date(); return nil }
        failures[path] = nil
        imageSizes[path] = size
        return size
    }

    /// Decode the thumbnail off the main thread, then fill in every overlay showing it.
    private func decode(_ path: String) {
        guard decoding.insert(path).inserted else { return }
        let url = fileURL(path)
        Task.detached(priority: .userInitiated) { [weak self] in
            let thumbnail = Self.thumbnail(url)
            await self?.decoded(path, thumbnail, refresh: true)
        }
    }

    /// Printing draws straight away: decode whatever is still pending, synchronously.
    func finishDecodingNow() {
        for overlay in overlays.values {
            guard let iv = overlay.view as? ResizableImageView, iv.imageView.image == nil else { continue }
            decoded(iv.path, Self.thumbnail(fileURL(iv.path)), refresh: false)
        }
    }

    private func decoded(_ path: String, _ thumbnail: Thumbnail?, refresh: Bool) {
        decoding.remove(path)
        let waiting = overlays.values.filter { ($0.view as? ResizableImageView)?.path == path }
        guard let thumbnail else {
            // Unreadable after all: drop the reserved space until the retry interval passes.
            failures[path] = Date()
            imageSizes[path] = nil
            for overlay in waiting { overlay.view.removeFromSuperview(); overlays[overlay.key] = nil }
            if refresh, !waiting.isEmpty { textView.refreshOverlays() }
            return
        }
        let image = NSImage(cgImage: thumbnail.image, size: thumbnail.size)
        imageCache.setObject(image, forKey: path as NSString, cost: thumbnail.image.width * thumbnail.image.height * 4)
        imageSizes[path] = image.size
        var resized = false
        for overlay in waiting {
            guard let iv = overlay.view as? ResizableImageView, iv.imageView.image == nil else { continue }
            iv.imageView.image = image
            if overlay.naturalSize != image.size { overlay.naturalSize = image.size; resized = true }
        }
        if refresh, resized { textView.refreshOverlays() }
    }

    /// A decoded thumbnail, handed from the decoding task to the main actor once.
    private struct Thumbnail: @unchecked Sendable {
        let image: CGImage
        let size: NSSize
    }

    private nonisolated static func thumbnail(_ url: URL) -> Thumbnail? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxThumbnailPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        // Points: treat the thumbnail as 2x so screenshots do not look enormous.
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? CGFloat) ?? CGFloat(cg.width)
        let scale: CGFloat = pixelWidth > 1400 ? 2 : 1
        return Thumbnail(image: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    private nonisolated static let maxThumbnailPixels: CGFloat = 1800

    /// The size `thumbnail(_:)` will produce, worked out from the header alone.
    /// ImageIO's rounding may differ by a pixel; the decoded size replaces it.
    private nonisolated static func headerSize(_ url: URL) -> NSSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let pixelHeight = props[kCGImagePropertyPixelHeight] as? CGFloat,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        var w = pixelWidth, h = pixelHeight
        // EXIF orientations 5-8 are quarter turns: the thumbnail comes out transposed.
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
        let longest = max(w, h)
        if longest > maxThumbnailPixels {
            w = (w * maxThumbnailPixels / longest).rounded()
            h = (h * maxThumbnailPixels / longest).rounded()
        }
        let scale: CGFloat = pixelWidth > 1400 ? 2 : 1
        return NSSize(width: w / scale, height: h / scale)
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
                  let bottom = textView.lineBottom(for: map.lines[overlay.lineIndex].range) else {
                overlay.view.isHidden = true; continue
            }
            overlay.view.isHidden = false
            let size = overlay.displaySize(availableWidth: width)
            if textView.styler.overlayHeights[overlay.lineIndex] != reserved(for: size.height) { stale = true }
            let x = textView.textContainerInset.width
            // Directly under the text line, inside the paragraph spacing reserved for it.
            overlay.view.frame = NSRect(x: x, y: bottom + 4, width: size.width, height: size.height)
        }
        return stale
    }

    /// Write the chosen width back into the image line as `![alt|width](path)`.
    private func commitWidth(_ width: CGFloat, key: Key) {
        guard let overlay = overlays[key], overlay.lineIndex < textView.styler.blockMap.lines.count else { return }
        let line = textView.styler.blockMap.lines[overlay.lineIndex]
        guard case .imageLine(let rawAlt, let path) = line.kind else { return }
        let (alt, _) = BlockMap.imageAlt(rawAlt)
        let natural = overlay.naturalSize.width
        let chosen: Double? = abs(width - natural) < 4 ? nil : Double(min(width, natural))
        let replacement = BlockMap.imageLine(alt: alt, width: chosen, path: path)
        guard replacement != line.text, textView.shouldChangeText(in: line.range, replacementString: replacement) else { return }
        textView.textStorage?.replaceCharacters(in: line.range, with: replacement)
        textView.didChangeText()
    }

    /// Show the markdown behind an overlay and put the caret at its end.
    private func revealLine(forKey key: Key) {
        guard let overlay = overlays[key], overlay.lineIndex < textView.styler.blockMap.lines.count else { return }
        let index = overlay.lineIndex
        textView.styler.forceReveal(line: index)
        let line = textView.styler.blockMap.lines[index]
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: line.range.location + line.range.length, length: 0))
        textView.scrollRangeToVisible(line.range)
    }
}


/// A LinkPresentation card with a discreet copy button that appears on hover.
final class LinkCardView: NSView {
    let linkView: LPLinkView
    private let copyButton = NSButton()
    private let revealButton = NSButton()
    private let url: URL
    private var trackingArea: NSTrackingArea?
    var onReveal: (() -> Void)?

    init(url: URL) {
        self.url = url
        linkView = LPLinkView(url: url)
        super.init(frame: NSRect(x: 0, y: 0, width: OverlayController.linkCardMaxWidth, height: OverlayController.linkCardHeight))
        linkView.frame = bounds
        linkView.autoresizingMask = [.width, .height]
        addSubview(linkView)
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy link")
        copyButton.contentTintColor = .white
        copyButton.wantsLayer = true
        copyButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        copyButton.layer?.cornerRadius = 6
        copyButton.frame = NSRect(x: bounds.maxX - 30, y: bounds.maxY - 30, width: 24, height: 24)
        copyButton.autoresizingMask = [.minXMargin, .minYMargin]
        copyButton.target = self
        copyButton.action = #selector(copyLink)
        copyButton.toolTip = "Copy link"
        copyButton.isHidden = true
        addSubview(copyButton)
        revealButton.bezelStyle = .accessoryBarAction
        revealButton.isBordered = false
        revealButton.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Show the link")
        revealButton.contentTintColor = .white
        revealButton.wantsLayer = true
        revealButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        revealButton.layer?.cornerRadius = 6
        revealButton.frame = NSRect(x: bounds.maxX - 58, y: bounds.maxY - 30, width: 24, height: 24)
        revealButton.autoresizingMask = [.minXMargin, .minYMargin]
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.toolTip = url.absoluteString
        revealButton.isHidden = true
        addSubview(revealButton)
    }

    @objc private func reveal() { onReveal?() }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @objc private func copyLink() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy link")
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { copyButton.isHidden = false; revealButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { copyButton.isHidden = true; revealButton.isHidden = true }
}

/// An image with hover badges: a resize grip (bottom-right, drag to scale)
/// and a path badge (top-right, tooltip shows the file; click reveals the markdown).
final class ResizableImageView: NSView {
    let imageView = NSImageView()
    let path: String
    var onResize: ((CGFloat) -> Void)?
    var onReveal: (() -> Void)?
    private var dragStart: (point: NSPoint, width: CGFloat)?
    private var trackingArea: NSTrackingArea?
    private let resizeBadge = BadgeView(symbol: "arrow.up.left.and.arrow.down.right")
    private let pathBadge = BadgeView(symbol: "doc.text")

    /// `image` may be nil while the thumbnail is decoded; `size` reserves its frame.
    init(image: NSImage?, size: NSSize, path: String) {
        self.path = path
        super.init(frame: NSRect(origin: .zero, size: size))
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
        for badge in [resizeBadge, pathBadge] { badge.isHidden = true; addSubview(badge) }
        resizeBadge.toolTip = "Drag to resize"
        pathBadge.toolTip = path
        pathBadge.onClick = { [weak self] in self?.onReveal?() }
        layoutBadges()
        updateTrackingAreas()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func layoutBadges() {
        resizeBadge.frame = NSRect(x: bounds.maxX - 28, y: bounds.minY + 6, width: 22, height: 22)
        pathBadge.frame = NSRect(x: bounds.maxX - 28, y: bounds.maxY - 28, width: 22, height: 22)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutBadges()
        updateTrackingAreas()
    }

    private var handleRect: NSRect { NSRect(x: bounds.maxX - 32, y: bounds.minY, width: 32, height: 32) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(handleRect, cursor: NSCursor.frameResize(position: .bottomRight, directions: .all))
    }

    override func mouseEntered(with event: NSEvent) { resizeBadge.isHidden = false; pathBadge.isHidden = false }
    override func mouseExited(with event: NSEvent) {
        if dragStart == nil { resizeBadge.isHidden = true; pathBadge.isHidden = true }
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
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { super.mouseUp(with: event); return }
        dragStart = nil
        onResize?(frame.width)
    }

    /// A translucent rounded square with a white SF Symbol.
    final class BadgeView: NSView {
        var onClick: (() -> Void)?
        private let symbolView = NSImageView()
        init(symbol: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
            layer?.cornerRadius = 5
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            symbolView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            symbolView.contentTintColor = .white
            symbolView.frame = bounds
            symbolView.autoresizingMask = [.width, .height]
            addSubview(symbolView)
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func mouseDown(with event: NSEvent) {
            if let onClick { onClick() } else { super.mouseDown(with: event) }
        }
        override func mouseDragged(with event: NSEvent) { if onClick == nil { superview?.mouseDragged(with: event) } }
        override func mouseUp(with event: NSEvent) { if onClick == nil { superview?.mouseUp(with: event) } }
    }
}
