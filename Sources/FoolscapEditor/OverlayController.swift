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
        init(key: String, view: NSView, lineIndex: Int, naturalSize: NSSize, isImage: Bool) {
            self.key = key; self.view = view; self.lineIndex = lineIndex; self.naturalSize = naturalSize; self.isImage = isImage
        }

        func displaySize(availableWidth: CGFloat) -> NSSize {
            if isImage {
                let scale = min(1, min(availableWidth / naturalSize.width, OverlayController.maxImageHeight / naturalSize.height))
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
        for line in map.lines {
            switch line.kind {
            case .imageLine(_, let path): wanted.append(("img:" + path, line))
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
        case .imageLine(_, let path):
            guard let image = loadImage(path) else { return nil }
            let iv = NSImageView(frame: NSRect(origin: .zero, size: image.size))
            iv.image = image
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 6
            iv.layer?.masksToBounds = true
            iv.layer?.borderWidth = 0.5
            iv.layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
            iv.toolTip = path
            return Overlay(key: key, view: iv, lineIndex: line.index, naturalSize: image.size, isImage: true)
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

    func invalidateImage(_ path: String) { imageCache[path] = nil; overlays["img:" + path]?.view.removeFromSuperview(); overlays["img:" + path] = nil }
}
