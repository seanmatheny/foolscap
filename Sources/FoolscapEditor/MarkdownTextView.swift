import AppKit
import UniformTypeIdentifiers
import FoolscapCore
import FoolscapStore

/// Editor geometry.
enum EditorMetrics {
    static let leftInset: CGFloat = 58
    static let rightInset: CGFloat = 36
    static let marginRuleOffset: CGFloat = 16   // red line sits this far left of the text
    static let topLines: CGFloat = 1            // ruled lines above the first text line
}

/// A TextKit 2 text view whose storage is the document's markdown. Draws the
/// paper ruling itself so lines scroll with the text and text sits on them.
public final class MarkdownTextView: NSTextView {
    var palette: EditorPalette
    let styler: MarkdownStyler
    let document: NoteDocument
    private(set) lazy var overlays = OverlayController(textView: self)
    private var syncingOverlays = false
    /// Distance from a line fragment's top to the baseline, measured from layout.
    private var measuredBaseline: CGFloat?
    /// Known tags for `#` completion, most used first (set by the editor wrapper).
    var knownTags: () -> [String] = { [] }
    private var completionScheduled = false
    private var insertingCompletion = false
    /// The last word accepted (or cancelled) from the completion list, so the
    /// list does not pop straight back up over it.
    private var lastCompletion: (location: Int, word: String)?
    /// Tags fetched by `offerTagCompletion`, reused by the `completions` call
    /// that `complete(nil)` makes straight away (one lookup per keystroke).
    private var offeredTags: [String]?

    public init(document: NoteDocument, palette: EditorPalette) {
        self.palette = palette
        self.document = document
        self.styler = MarkdownStyler(palette: palette)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = document.textStorage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        super.init(frame: .zero, textContainer: container)
        configure()
        styler.onStyled = { [weak self] in self?.overlaysChanged() }
        styler.textView = self
        styler.attach(to: document.textStorage)
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .png, .tiff])
    }

    /// Plain-text views only declare text as pasteable, which disables the
    /// Paste menu item (and ⌘V) whenever the clipboard holds a screenshot.
    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    // MARK: Active line (markdown syntax is revealed only where the caret is)

    private var lastCaret = 0

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        // A caret can't rest on a collapsed image/URL line: step over it in the
        // direction of travel, so clicks and arrow keys never expand the markdown.
        if ranges.count == 1, ranges[0].rangeValue.length == 0 {
            let caret = ranges[0].rangeValue.location
            if let line = styler.blockMap.line(at: caret), styler.isCollapsed(line: line.index) {
                let length = (string as NSString).length
                let forward = caret >= lastCaret
                let target = forward ? min(length, line.range.location + line.range.length + 1)
                                     : max(0, line.range.location - 1)
                ranges = [NSValue(range: NSRange(location: target, length: 0))]
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if ranges.count == 1, ranges[0].rangeValue.length == 0 { lastCaret = ranges[0].rangeValue.location }
        styler.selectionChanged()
    }

    // MARK: Tag completion

    /// The system completion list, fed with known tags while a `#tag` is being
    /// typed. It opens by itself after the first character following the `#`;
    /// Return or Tab accepts, Escape closes, typing on keeps narrowing it.
    public override var rangeForUserCompletion: NSRange {
        if let partial = TagCompletion.partial(in: string, caret: selectedRange().location) { return partial.range }
        return super.rangeForUserCompletion
    }

    public override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let ns = string as NSString
        guard charRange.length > 0, charRange.location + charRange.length <= ns.length,
              ns.character(at: charRange.location) == 0x23 /* # */ else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        let typed = ns.substring(with: NSRange(location: charRange.location + 1, length: charRange.length - 1))
        index.pointee = 0
        return TagCompletion.matches(for: typed, in: offeredTags ?? knownTags()).map { "#" + $0 }
    }

    public override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        insertingCompletion = true
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        insertingCompletion = false
        if flag { lastCompletion = (charRange.location, word) }
    }

    public override func didChangeText() {
        super.didChangeText()
        guard !insertingCompletion, !completionScheduled else { return }
        completionScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.completionScheduled = false
            self?.offerTagCompletion()
        }
    }

    private func offerTagCompletion() {
        guard window?.firstResponder === self, selectedRange().length == 0, !hasMarkedText(),
              let partial = TagCompletion.partial(in: string, caret: selectedRange().location), !partial.text.isEmpty else { return }
        let word = (string as NSString).substring(with: partial.range)
        if let last = lastCompletion, last.location == partial.range.location, last.word == word { return }
        // `complete` beeps when it has nothing to offer: only call it when it does.
        let tags = knownTags()
        guard !TagCompletion.matches(for: partial.text, in: tags).isEmpty else { return }
        offeredTags = tags
        defer { offeredTags = nil }
        complete(nil)
    }

    // MARK: Overlays

    /// An overlay's size changed or it went away (e.g. its image finished decoding).
    func refreshOverlays() { overlaysChanged() }

    /// Printing (PDF export) draws synchronously: images still decoding would be blank.
    public override func beginDocument() {
        overlays.finishDecodingNow()
        super.beginDocument()
    }

    private func overlaysChanged() {
        guard !syncingOverlays else { return }
        syncingOverlays = true
        defer { syncingOverlays = false }
        let before = styler.overlayHeights
        if overlays.sync(map: styler.blockMap) {
            let after = styler.overlayHeights
            let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            if !changed.isEmpty { styler.restyle(lines: Array(changed)) }
            needsDisplay = true
        }
        // layout() redraws the backdrops if the text under them moved.
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        if overlays.reposition() {
            // Width changed: reserve new heights on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in self?.overlaysChanged() }
        }
        // Ruling and code backdrops are ours, not TextKit's: redraw them when they moved.
        let visible = decorations(in: visibleRect)
        if visible != laidOutDecorations || bounds.size != laidOutSize {
            laidOutDecorations = visible
            laidOutSize = bounds.size
            needsDisplay = true
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    // MARK: Paste and drop

    public override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pasteImage(from: pb) { return }
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), !s.contains(" ") {
            if selectedRange().length > 0, let selected = (string as NSString?)?.substring(with: selectedRange()) {
                insertMarkdown("[\(selected)](\(s))", ownLine: false)
            } else {
                insertMarkdown(s, ownLine: true)
            }
            return
        }
        pasteAsPlainText(sender)
    }

    private func pasteImage(from pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.allSatisfy(AttachmentImporter.isImageFile) {
            for url in urls { if let md = AttachmentImporter.importFile(url, document: document) { insertMarkdown(md, ownLine: true) } }
            return true
        }
        // Text wins over images when both are present (e.g. a web selection).
        if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb) {
            if let md = AttachmentImporter.importImage(image, document: document) { insertMarkdown(md, ownLine: true) }
            return true
        }
        return false
    }

    /// Insert text at the selection; `ownLine` puts it on a line of its own.
    func insertMarkdown(_ text: String, ownLine: Bool) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        var range = selectedRange()
        var insert = text
        if ownLine {
            let before = range.location > 0 ? ns.substring(with: NSRange(location: range.location - 1, length: 1)) : "\n"
            let afterIndex = range.location + range.length
            let after = afterIndex < ns.length ? ns.substring(with: NSRange(location: afterIndex, length: 1)) : "\n"
            if before != "\n" { insert = "\n" + insert }
            // Always leave a line after a block so its overlay has a paragraph to reserve space in.
            if after != "\n" || afterIndex >= ns.length { insert += "\n" }
            range = NSRange(location: afterIndex, length: 0)
        }
        guard shouldChangeText(in: range, replacementString: insert) else { return }
        storage.replaceCharacters(in: range, with: insert)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (insert as NSString).length, length: 0))
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppableImageURLs(sender) != nil { return .copy }
        return super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if droppableImageURLs(sender) != nil { return .copy }
        return super.draggingUpdated(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = droppableImageURLs(sender) {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            for url in urls { if let md = AttachmentImporter.importFile(url, document: document) { insertMarkdown(md, ownLine: true) } }
            return true
        }
        if let image = NSImage(pasteboard: sender.draggingPasteboard) {
            if let md = AttachmentImporter.importImage(image, document: document) { insertMarkdown(md, ownLine: true) }
            return true
        }
        return super.performDragOperation(sender)
    }

    private func droppableImageURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, urls.allSatisfy(AttachmentImporter.isImageFile) else { return nil }
        return urls
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = [.width]
        applyPalette()
    }

    func applyPalette() {
        // Plain-text views paint with these, not with storage attributes.
        textColor = palette.ink
        font = palette.body
        insertionPointColor = palette.ink
        selectedTextAttributes = [.backgroundColor: palette.selection]
        linkTextAttributes = [.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: palette.accent.withAlphaComponent(0.5), .cursor: NSCursor.pointingHand]
        typingAttributes = palette.baseAttributes
        textContainerInset = NSSize(width: EditorMetrics.leftInset, height: palette.pitch * EditorMetrics.topLines)
        measuredBaseline = nil
        needsDisplay = true
    }

    /// Re-apply all display attributes (after a palette change).
    func restyleAll() {
        styler.palette = palette
        styler.restyleAll()
    }

    // MARK: Clicks

    /// Clicking a task's checkbox cycles its status; clicks on links open them.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if event.clickCount == 1, let line = styler.blockMap.line(at: index), case .task = line.kind,
           let parsed = TaskLineParser.parse(line.text) {
            let markRange = NSRange(location: line.range.location + parsed.markOffset - 1, length: 3)
            if NSLocationInRange(index, NSRange(location: markRange.location, length: markRange.length + 1)),
               let replaced = TaskLineParser.replacingStatus(in: line.text, with: parsed.status.next),
               shouldChangeText(in: line.range, replacementString: replaced) {
                textStorage?.replaceCharacters(in: line.range, with: replaced)
                didChangeText()
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Ruling

    private func baselineOffset() -> CGFloat {
        if let measuredBaseline { return measuredBaseline }
        guard let tlm = textLayoutManager, let start = tlm.documentRange.location as NSTextLocation? else { return palette.pitch * 0.78 }
        var result: CGFloat?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first {
                result = line.glyphOrigin.y
            }
            return false
        }
        if let r = result, r > 0 { measuredBaseline = r }
        return result ?? palette.pitch * 0.78
    }

    public override func draw(_ dirtyRect: NSRect) {
        drawRuling(in: dirtyRect)
        let visible = decorations(in: dirtyRect)
        drawCodeBlocks(visible)
        drawQuoteBars(visible)
        super.draw(dirtyRect)
    }

    // MARK: Code backdrops and quote bars

    struct Decoration: Equatable {
        enum Kind: Equatable {
            /// `language` is nil when the fence line lies outside the measured text.
            case code(language: String?)
            case quote
        }
        var kind: Kind
        /// The block's layout fragments, in view coordinates.
        var rect: NSRect
    }

    /// The backdrops visible at the last layout pass: layout() redraws only when they change.
    private var laidOutDecorations: [Decoration] = []
    private var laidOutSize: NSSize = .zero

    /// Code blocks and quotes whose text lies under `rect`. Only the characters
    /// under the rect (plus a margin) are measured, so drawing never lays out the
    /// rest of the document; a block that runs on past them is extended beyond it.
    func decorations(in rect: NSRect) -> [Decoration] {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager else { return [] }
        let lines = styler.blockMap.lines
        guard !lines.isEmpty else { return [] }
        let doc = tlm.documentRange
        let pitch = palette.pitch
        let margin = pitch * 2
        // Character span under the rect, looked up in the existing layout (no layout forced).
        let top = CGPoint(x: 0, y: max(0, rect.minY - margin - textContainerInset.height))
        let bottom = CGPoint(x: 0, y: rect.maxY + margin - textContainerInset.height)
        let first = tlm.textLayoutFragment(for: top).map { cm.offset(from: doc.location, to: $0.rangeInElement.location) } ?? 0
        let last = tlm.textLayoutFragment(for: bottom).map { cm.offset(from: doc.location, to: $0.rangeInElement.endLocation) }
            ?? cm.offset(from: doc.location, to: doc.endLocation)
        guard first <= last else { return [] }

        var out: [Decoration] = []
        func add(from i: Int, to j: Int, code: String?) {
            let start = lines[i].range.location, end = lines[j].range.location + lines[j].range.length
            guard end >= first, start <= last else { return }
            let clipStart = max(start, first), clipEnd = min(end, last)
            guard var r = fragmentRect(for: NSRange(location: clipStart, length: clipEnd - clipStart)) else { return }
            if start < first { r.origin.y -= pitch; r.size.height += pitch }
            if end > last { r.size.height += pitch }
            guard r.intersects(rect) else { return }
            if let code {
                out.append(Decoration(kind: .code(language: start < first ? nil : code), rect: r))
            } else {
                out.append(Decoration(kind: .quote, rect: r))
            }
        }
        // Back up to the start of a block that begins above the measured span.
        var i = styler.blockMap.line(at: first)?.index ?? 0
        backUp: while i > 0 {
            switch lines[i].kind {
            case .fenceInside, .fenceClose: i -= 1
            case .quote where lines[i - 1].kind == .quote: i -= 1
            default: break backUp
            }
        }
        while i < lines.count, lines[i].range.location <= last {
            switch lines[i].kind {
            case .fenceOpen(let language):
                var j = i
                while j + 1 < lines.count, lines[j].kind != .fenceClose { j += 1 }
                add(from: i, to: j, code: language)
                i = j + 1
            case .quote:
                var j = i
                while j + 1 < lines.count, lines[j + 1].kind == .quote { j += 1 }
                add(from: i, to: j, code: nil)
                i = j + 1
            default:
                i += 1
            }
        }
        return out
    }

    private func drawQuoteBars(_ decorations: [Decoration]) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for d in decorations where d.kind == .quote {
            let r = d.rect
            let bar = NSRect(x: textContainerInset.width + 2, y: r.minY + 3, width: 3, height: r.height - 6)
            ctx.setFillColor(palette.accent.withAlphaComponent(0.55).cgColor)
            ctx.addPath(NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).cgPath); ctx.fillPath()
        }
    }

    /// Bottom of the last text line of the paragraph at `range` (excludes paragraph spacing).
    func lineBottom(for range: NSRange) -> CGFloat? {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager,
              let start = cm.location(tlm.documentRange.location, offsetBy: range.location) else { return nil }
        var bottom: CGFloat?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            if let last = fragment.textLineFragments.last {
                bottom = fragment.layoutFragmentFrame.minY + last.typographicBounds.maxY + textContainerInset.height
            }
            return false
        }
        return bottom
    }

    /// Frames (in view coordinates) of the layout fragments covering a character range.
    func fragmentRect(for range: NSRange) -> NSRect? {
        guard let tlm = textLayoutManager, let cm = tlm.textContentManager else { return nil }
        let doc = tlm.documentRange
        guard let start = cm.location(doc.location, offsetBy: range.location) else { return nil }
        let endOffset = range.location + range.length
        var rect: NSRect?
        tlm.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let fStart = cm.offset(from: doc.location, to: fragment.rangeInElement.location)
            if fStart >= endOffset && range.length > 0 { return false }
            var f = fragment.layoutFragmentFrame
            f.origin.x += textContainerInset.width
            f.origin.y += textContainerInset.height
            rect = rect.map { $0.union(f) } ?? f
            let fEnd = cm.offset(from: doc.location, to: fragment.rangeInElement.endLocation)
            return fEnd < endOffset
        }
        return rect
    }

    private func drawCodeBlocks(_ decorations: [Decoration]) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        for d in decorations {
            guard case .code(let language) = d.kind else { continue }
            let r = d.rect
            let block = NSRect(x: textContainerInset.width - 10, y: r.minY - 2,
                               width: bounds.width - textContainerInset.width * 2 + 20, height: r.height + 4)
            let path = NSBezierPath(roundedRect: block, xRadius: 5, yRadius: 5)
            ctx.setFillColor(palette.codeBlockBackground.cgColor)
            ctx.addPath(path.cgPath); ctx.fillPath()
            ctx.setStrokeColor(palette.dimInk.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.5)
            ctx.addPath(path.cgPath); ctx.strokePath()
            if let language, !language.isEmpty {
                let label = NSAttributedString(string: language, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: palette.dimInk.withAlphaComponent(0.6)])
                let size = label.size()
                label.draw(at: NSPoint(x: block.maxX - size.width - 8, y: block.minY + 5))
            }
        }
    }

    private func drawRuling(in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pitch = palette.pitch
        let top = textContainerInset.height
        // Rules sit just under the baseline of each line.
        let ruleOffset = baselineOffset() + 3
        ctx.saveGState()
        ctx.setLineWidth(0.8)
        let rule = palette.ruleColor.cgColor
        let firstLine = max(0, Int((rect.minY - top - ruleOffset) / pitch) - 1)
        let lastLine = Int((rect.maxY - top - ruleOffset) / pitch) + 1
        switch palette.ruling {
        case .blank: break
        case .lined:
            ctx.setStrokeColor(rule)
            for i in firstLine...lastLine {
                let y = top + ruleOffset + CGFloat(i) * pitch + 0.5
                ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            ctx.strokePath()
        case .grid:
            ctx.setStrokeColor(rule); ctx.setLineWidth(0.5)
            for i in firstLine...lastLine {
                let y = top + ruleOffset + CGFloat(i) * pitch + 0.5
                ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
            var x = EditorMetrics.leftInset.truncatingRemainder(dividingBy: pitch) + 0.5
            while x < bounds.maxX {
                if x >= rect.minX - pitch { ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)) }
                x += pitch
            }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(rule)
            for i in firstLine...lastLine {
                let y = top + ruleOffset + CGFloat(i) * pitch
                var x = EditorMetrics.leftInset.truncatingRemainder(dividingBy: pitch)
                while x < bounds.maxX {
                    ctx.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += pitch
                }
            }
        }
        if palette.showMarginRule {
            ctx.setStrokeColor(palette.marginRuleColor.cgColor); ctx.setLineWidth(1)
            let x = EditorMetrics.leftInset - EditorMetrics.marginRuleOffset + 0.5
            ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)); ctx.strokePath()
        }
        ctx.restoreGState()
    }
}
