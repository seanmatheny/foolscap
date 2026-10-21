import UniformTypeIdentifiers
import FoolscapCore
import FoolscapStore
import FoolscapUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Editor geometry.
enum EditorMetrics {
    static var leftInset: CGFloat { PageRuling.textLeft }
    static var rightInset: CGFloat { PageRuling.textRight }
    static let marginRuleOffset: CGFloat = RulingView.marginRuleOffset   // red line sits this far left of the text
    static var topLines: CGFloat { PageColumn.topLines }   // ruled lines above the first text line
    /// The header (today's tasks) ends where the Tasks tab's rows do.
    static var headerRightInset: CGFloat { PageRuling.textRight + 8 }
}

/// Where the ruled lines fall on a page, shared by the editor and the SwiftUI
/// pages (the Tasks tab) so the ruling does not move between tabs.
public enum PageRuling {
    /// Left edge of the text column; the margin rule sits `RulingView.marginRuleOffset` left of it.
    /// The numbers are `PageColumn`'s (FoolscapUI), shared with the pages that have no editor.
    public static var textLeft: CGFloat {
        get { PageColumn.textLeft }
        set { PageColumn.textLeft = newValue }
    }
    /// Paper left clear on the right of the text.
    public static var textRight: CGFloat {
        get { PageColumn.textRight }
        set { PageColumn.textRight = newValue }
    }

    /// From the top of a line's band to its rule: just under the baseline of a
    /// line set in the top heading (a daily note's date), whose lower baseline
    /// every page's ruling follows.
    @MainActor public static func ruleOffset(_ palette: EditorPalette) -> CGFloat {
        let key = "\(palette.headings[0].fontName)/\(palette.headings[0].pointSize)/\(palette.pitch)"
        if let cached = ruleOffsets[key] { return cached }
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = palette.pitch
        ps.maximumLineHeight = palette.pitch
        let storage = NSTextStorage(string: "# Today\n", attributes: [.font: palette.headings[0], .paragraphStyle: ps])
        let content = NSTextContentStorage()
        content.textStorage = storage
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 1000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        var baseline = palette.pitch * 0.78
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first, line.glyphOrigin.y > 0 { baseline = line.glyphOrigin.y }
            return false
        }
        let offset = baseline + 3.5
        ruleOffsets[key] = offset
        return offset
    }


    /// How far a band of SwiftUI rows `pitch` tall (the Tasks tab's) moves down so each
    /// row's rule falls 4 pt above its bottom, where it sits on the Tasks tab.
    @MainActor public static func rowShift(_ palette: EditorPalette) -> CGFloat { ruleOffset(palette) - (palette.pitch - 4) }

    @MainActor private static var ruleOffsets: [String: CGFloat] = [:]
}

/// A TextKit 2 text view whose storage is the document's markdown. Draws the
/// paper ruling itself so lines scroll with the text and text sits on them.
/// What an editor may do beyond editing text. A scratch editor over text that
/// must never leave memory (the Secrets tab) turns everything off: no attachment
/// files, no link-preview cache, no fold memory in the defaults, no spell checker.
public struct EditorFeatures: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// Pasted and dropped images are written to `Attachments/` and linked.
    public static let attachments = EditorFeatures(rawValue: 1 << 0)
    /// URL lines get a link card, fetched and cached under Application Support.
    public static let linkPreviews = EditorFeatures(rawValue: 1 << 1)
    /// Folded headings are remembered in the defaults by note path and heading text.
    public static let foldMemory = EditorFeatures(rawValue: 1 << 2)
    /// Continuous spell checking.
    public static let textChecking = EditorFeatures(rawValue: 1 << 3)
    public static let all: EditorFeatures = [.attachments, .linkPreviews, .foldMemory, .textChecking]
}

#if canImport(AppKit)

public final class MarkdownTextView: NSTextView {
    var palette: EditorPalette
    let styler: MarkdownStyler
    let document: NoteDocument
    let features: EditorFeatures
    private(set) lazy var overlays = OverlayController(textView: self)
    private var syncingOverlays = false
    /// Known tags for `#` completion, most used first (set by the editor wrapper).
    var knownTags: () -> [String] = { [] }
    private var completionScheduled = false
    /// The last word accepted (or dismissed) from the tag list, so the list does
    /// not pop straight back up over it.
    private var lastCompletion: (location: Int, word: String)?
    private let tagPopup = TagCompletionPopup()
    /// The `#tag` the open list would replace.
    private var popupPartial: TagCompletion.Partial?
    /// Folding: the "n lines" pills drawn after folded headings (for clicks), the
    /// heading under the pointer, and the tracking area that follows it.
    var foldPills: [Int: NSRect] = [:]
    var hoverHeading: Int?
    var foldTracking: NSTrackingArea?
    /// The task line whose `[ ]` mark is under the pointer (tinted, to say it is clickable).
    var hoverTaskMark: Int?

    public init(document: NoteDocument, palette: EditorPalette, features: EditorFeatures = .all) {
        self.palette = palette
        self.document = document
        self.features = features
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
        styler.host = self
        // Sections folded on an earlier visit stay folded; toggles are remembered by
        // the note's path and the heading's text (never written into the file).
        if features.contains(.foldMemory) { styler.foldedHeadings = FoldMemory.folded(for: document.path) }
        styler.onFoldsChanged = { [weak self] in
            guard let self else { return }
            if self.features.contains(.foldMemory) {
                let present = Set(self.styler.blockMap.lines.compactMap { line -> String? in
                    if case .heading = line.kind { return MarkdownStyler.foldKey(line) }
                    return nil
                })
                FoldMemory.save(self.styler.foldedHeadings.intersection(present), for: self.document.path)
            }
            self.needsDisplay = true
        }
        styler.attach(to: document.textStorage)
        if features.contains(.attachments) { registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .png, .tiff]) }
        if !features.contains(.textChecking) { isContinuousSpellCheckingEnabled = false }
    }

    /// True when the characters at `range` are code: a fenced block's lines, or an
    /// inline `span` (the styler gives those the code background). The spell checker
    /// is told to leave them alone.
    public func isCode(_ range: NSRange) -> Bool {
        if let line = styler.blockMap.line(at: range.location) {
            switch line.kind {
            case .fenceOpen, .fenceInside, .fenceClose: return true
            default: break
            }
        }
        guard let storage = textStorage, range.location < storage.length else { return false }
        let bg = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        return bg == palette.codeBackground
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
        // A caret can't rest on a collapsed image/URL line or inside a folded section:
        // step over the whole run in the direction of travel, so clicks and arrow keys
        // never expand the markdown or land in hidden text.
        if ranges.count == 1, ranges[0].rangeValue.length == 0 {
            let caret = ranges[0].rangeValue.location
            let lines = styler.blockMap.lines
            if let line = styler.blockMap.line(at: caret), styler.skipsCaret(line: line.index) {
                let length = (string as NSString).length
                let forward = caret >= lastCaret
                var first = line.index, last = line.index
                while first > 0, styler.skipsCaret(line: first - 1) { first -= 1 }
                while last + 1 < lines.count, styler.skipsCaret(line: last + 1) { last += 1 }
                let runEnd = lines[last].range.location + lines[last].range.length
                let target: Int
                if forward, last + 1 < lines.count {
                    target = runEnd + 1
                } else if forward, styler.isCollapsed(line: last) {
                    // The note ends on the image or link line: there is no line below it to
                    // land on, so make one (after this selection change has finished).
                    target = length
                    DispatchQueue.main.async { [weak self] in self?.addLineAfterLastOverlay() }
                } else if first > 0 {
                    target = lines[first].range.location - 1
                } else {
                    target = min(length, runEnd + 1)
                }
                ranges = [NSValue(range: NSRange(location: target, length: 0))]
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if ranges.count == 1, ranges[0].rangeValue.length == 0 { lastCaret = ranges[0].rangeValue.location }
        invalidate(lines: styler.selectionChanged())
        scheduleTagListUpdate(open: false)
    }

    private func addLineAfterLastOverlay() {
        let length = (string as NSString).length
        guard let line = styler.blockMap.line(at: length), styler.isCollapsed(line: line.index),
              line.range.location + line.range.length >= length else { return }
        let end = NSRange(location: length, length: 0)
        guard shouldChangeText(in: end, replacementString: "\n") else { return }
        textStorage?.replaceCharacters(in: end, with: "\n")
        didChangeText()
        setSelectedRange(NSRange(location: length + 1, length: 0))
    }

    // MARK: Tag completion

    /// A themed list of known tags under a `#tag` being typed. It opens by itself
    /// at the `#` (after the first letter at the start of a line, where `#` is
    /// usually a heading) and narrows as typing goes on; ↑/↓ choose, Return, Tab
    /// or a click accept, Escape closes, and a space or punctuation simply ends
    /// the tag as typed.
    public override func didChangeText() {
        super.didChangeText()
        scheduleTagListUpdate(open: true)
    }

    /// Re-check after the edit or selection change has settled (the styler and
    /// AppKit are still mid-update when these hooks run).
    private func scheduleTagListUpdate(open: Bool) {
        guard !completionScheduled, open || tagPopup.isVisible else { return }
        completionScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.completionScheduled = false
            self?.updateTagList(open: open)
        }
    }

    /// Show, refresh or hide the list for the tag at the caret; `open` is false
    /// for caret moves and scrolling, which only keep an open list up to date.
    private func updateTagList(open: Bool) {
        guard let window, window.isKeyWindow, window.firstResponder === self, selectedRange().length == 0, !hasMarkedText(),
              open || tagPopup.isVisible,
              let partial = TagCompletion.partial(in: string, caret: selectedRange().location) else { hideTagList(); return }
        let ns = string as NSString
        if partial.text.isEmpty {
            let lineStart = ns.lineRange(for: NSRange(location: partial.range.location, length: 0)).location
            if partial.range.location == lineStart { hideTagList(); return }
        }
        let word = ns.substring(with: partial.range)
        if let last = lastCompletion, last.location == partial.range.location, last.word == word { hideTagList(); return }
        let matches = TagCompletion.matches(for: partial.text, in: knownTags())
        guard !matches.isEmpty else { hideTagList(); return }
        let anchor = firstRect(forCharacterRange: partial.range, actualRange: nil)
        guard anchor != .zero else { hideTagList(); return }
        popupPartial = partial
        tagPopup.show(tags: matches, theme: palette.theme, below: anchor, in: window) { [weak self] tag in
            self?.acceptTag(tag)
        }
    }

    private func hideTagList() {
        popupPartial = nil
        tagPopup.hide()
    }

    private func acceptTag(_ tag: String) {
        guard let partial = popupPartial else { return }
        let word = "#" + tag
        lastCompletion = (partial.range.location, word)
        hideTagList()
        insertText(word, replacementRange: partial.range)
    }

    public override func doCommand(by selector: Selector) {
        if tagPopup.isVisible {
            switch selector {
            case #selector(moveUp(_:)): tagPopup.move(-1); return
            case #selector(moveDown(_:)): tagPopup.move(1); return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if let tag = tagPopup.selectedTag { acceptTag(tag); return }
            case #selector(cancelOperation(_:)):
                if let partial = popupPartial {
                    lastCompletion = (partial.range.location, (string as NSString).substring(with: partial.range))
                }
                hideTagList()
                return
            default: break
            }
        }
        super.doCommand(by: selector)
    }

    public override func resignFirstResponder() -> Bool {
        hideTagList()
        return super.resignFirstResponder()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hideTagList() }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let clip = enclosingScrollView?.contentView {
            // Scrolling carries the tag away from the list: follow it (or close when it leaves).
            NotificationCenter.default.addObserver(self, selector: #selector(tagListContextMoved), name: NSView.boundsDidChangeNotification, object: clip)
        }
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(tagListContextLost), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func tagListContextMoved() { if tagPopup.isVisible { updateTagList(open: false) } }
    @objc private func tagListContextLost() { hideTagList() }

    // MARK: Overlays

    /// An overlay's size changed or it went away (e.g. its image finished decoding).
    func refreshOverlays() { overlaysChanged() }

    /// Printing (PDF export) draws synchronously: images still decoding would be blank.
    public override func beginDocument() {
        overlays.finishDecodingNow()
        super.beginDocument()
    }

    // MARK: Header

    /// A view laid under the note's opening heading (today's Today-status tasks), in
    /// space the styler reserves below that line, so it sits on the ruling and
    /// scrolls with the note. The text storage is untouched.
    var headerView: NSView? {
        didSet {
            guard headerView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let headerView { addSubview(headerView) }
            refreshOverlays()
        }
    }

    /// The header's own height; the space reserved for it is rounded up to whole ruled lines.
    var headerHeight: CGFloat = 0 {
        didSet { if headerHeight != oldValue { refreshOverlays() } }
    }

    var headerReservation: CGFloat {
        guard headerView != nil, headerHeight > 0 else { return 0 }
        return ceil(headerHeight / palette.pitch - 0.01) * palette.pitch
    }

    /// The line the header sits under: the opening heading (a daily note's date).
    /// Nil when the note does not open with one; the header then heads the page.
    var headerAnchor: Int? {
        guard let first = styler.blockMap.lines.first, case .heading = first.kind else { return nil }
        return 0
    }

    /// Without a heading to sit under, the header takes whole lines above the text.
    private func updateTopInset() {
        let top = palette.pitch * EditorMetrics.topLines + (headerAnchor == nil ? headerReservation : 0)
        if textContainerInset.height != top {
            textContainerInset = NSSize(width: EditorMetrics.leftInset, height: top)
        }
    }

    /// Under its line, moved down as the Tasks tab's rows are so each row sits on a rule.
    private func positionHeader() {
        guard let headerView else { return }
        var top = palette.pitch * EditorMetrics.topLines
        if let anchor = headerAnchor, let bottom = lineBottom(for: styler.blockMap.lines[anchor].range) { top = bottom }
        let width = max(120, bounds.width - EditorMetrics.leftInset - EditorMetrics.headerRightInset)
        headerView.frame = NSRect(x: EditorMetrics.leftInset, y: top + PageRuling.rowShift(palette),
                                  width: width, height: max(1, headerHeight))
    }

    // MARK: Footer

    /// A view laid after the note's last line (the day's handwritten Scribe pages),
    /// scrolling with the note on the ruling. The last paragraph carries no trailing
    /// spacing to reserve in, so the room comes from the view's minimum height.
    var footerView: NSView? {
        didSet {
            guard footerView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let footerView { addSubview(footerView) }
            updateMinSize()
            needsLayout = true
        }
    }

    var footerHeight: CGFloat = 0 {
        didSet { if footerHeight != oldValue { updateMinSize(); needsLayout = true } }
    }

    var footerReservation: CGFloat {
        guard footerView != nil, footerHeight > 0 else { return 0 }
        return ceil(footerHeight / palette.pitch - 0.01) * palette.pitch
    }

    /// The visible page height: the view is never shorter, so the ruling fills it.
    var visibleHeight: CGFloat = 0 {
        didSet { if visibleHeight != oldValue { updateMinSize(); needsLayout = true } }
    }

    /// Where the text ends, including the empty last line.
    var textBottom: CGFloat {
        (textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0) + textContainerInset.height
    }

    /// Tall enough for the page, and for the footer a line under the text.
    func updateMinSize() {
        var needed = visibleHeight
        if footerReservation > 0 { needed = max(needed, textBottom + palette.pitch + footerReservation + palette.pitch) }
        if minSize.height != needed {
            minSize = NSSize(width: 0, height: needed)
            sizeToFit()
        }
    }

    private func positionFooter() {
        guard let footerView else { return }
        let width = max(120, bounds.width - EditorMetrics.leftInset - EditorMetrics.headerRightInset)
        footerView.frame = NSRect(x: EditorMetrics.leftInset, y: textBottom + palette.pitch + PageRuling.rowShift(palette),
                                  width: width, height: max(1, footerHeight))
    }

    private func overlaysChanged() {
        guard !syncingOverlays else { return }
        syncingOverlays = true
        defer { syncingOverlays = false }
        updateTopInset()
        updateMinSize()
        let before = styler.overlayHeights
        if overlays.sync(map: styler.blockMap) {
            let after = styler.overlayHeights
            let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
            if !changed.isEmpty {
                styler.restyle(lines: Array(changed))
                // A paragraph that grew (the header's room under the heading) moves every line
                // after it; TextKit 2 relays the edited paragraph alone and the viewport keeps
                // drawing the rest at their old places, so lay out again from there to the end.
                if let lm = textLayoutManager, let first = changed.min(), first < styler.blockMap.lines.count,
                   let from = lm.location(lm.documentRange.location, offsetBy: styler.blockMap.lines[first].range.location),
                   let range = NSTextRange(location: from, end: lm.documentRange.endLocation) {
                    lm.invalidateLayout(for: range)
                    lm.textViewportLayoutController.layoutViewport()
                }
            }
            needsDisplay = true
        }
        // layout() redraws the backdrops if the text under them moved.
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        positionHeader()
        positionFooter()
        updateMinSize()
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
        guard features.contains(.attachments) else { return false }
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

    // `insertMarkdown(_:ownLine:)` is the shared one in MarkdownCommands.swift.

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
        if features.contains(.attachments), let image = NSImage(pasteboard: sender.draggingPasteboard) {
            if let md = AttachmentImporter.importImage(image, document: document) { insertMarkdown(md, ownLine: true) }
            return true
        }
        return super.performDragOperation(sender)
    }

    private func droppableImageURLs(_ sender: NSDraggingInfo) -> [URL]? {
        guard features.contains(.attachments) else { return nil }
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
        updateTopInset()
        needsDisplay = true
    }

    /// Re-apply all display attributes (after a palette change).
    func restyleAll() {
        styler.palette = palette
        styler.restyleAll()
    }

    // MARK: Copying a picture

    /// ⌘C with a picture selected (clicked) copies the picture, not the text.
    public override func copy(_ sender: Any?) {
        if overlays.copySelectedImage() { return }
        super.copy(sender)
    }

    public override func keyDown(with event: NSEvent) {
        overlays.select(nil)
        super.keyDown(with: event)
    }

    // MARK: Clicks

    /// Clicking a task's checkbox cycles its status; clicks on links open them.
    public override func mouseDown(with event: NSEvent) {
        overlays.select(nil)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, let heading = foldControl(at: point) {
            toggleFold(heading: heading)
            needsDisplay = true
            return
        }
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

    // MARK: Ruling and the other decorations

    /// Ruling, backdrops, quote bars, the task-mark tint and the fold chevrons go
    /// before the text: TextKit leaves the context clipped to the text container,
    /// and the chevrons sit in the margin outside it. The bullets go after it, over
    /// the `-` they stand for.
    public override func draw(_ dirtyRect: NSRect) {
        let ctx = NSGraphicsContext.current?.cgContext
        let decorator = EditorDecorations(geometry: self)
        if let ctx { decorator.drawUnderText(in: ctx, rect: dirtyRect) }
        super.draw(dirtyRect)
        if let ctx { decorator.drawOverText(in: ctx, rect: dirtyRect) }
    }

    /// Redraw whole line bands (margin included) for lines whose look changed
    /// with the selection: bullets and chevrons are ours, not TextKit's.
    func invalidate(lines: Set<Int>) {
        let map = styler.blockMap
        for i in lines where i < map.lines.count {
            guard let r = fragmentRect(for: map.lines[i].range) else { continue }
            setNeedsDisplay(NSRect(x: 0, y: r.minY - 2, width: bounds.width, height: r.height + 4))
        }
    }

    // MARK: Decorations

    /// The backdrops visible at the last layout pass: layout() redraws only when they change.
    private var laidOutDecorations: [EditorDecorations.Decoration] = []
    private var laidOutSize: NSSize = .zero
}

/// The page's drawing lives in `EditorDecorations`; it reads the layout and the
/// hover state through this.
extension MarkdownTextView: DecorationGeometry {
    var textOrigin: CGPoint { CGPoint(x: textContainerInset.width, y: textContainerInset.height) }
    var viewWidth: CGFloat { bounds.width }
}

extension MarkdownTextView: StylerHost {
    var selectedCharacterRanges: [NSRange] { selectedRanges.map(\.rangeValue) }
}

#endif
