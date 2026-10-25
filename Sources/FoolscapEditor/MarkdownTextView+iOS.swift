#if canImport(UIKit) && !canImport(AppKit)
import UIKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// The phone's editor: a TextKit 2 `UITextView` over the document's storage, the
/// twin of the Mac's `MarkdownTextView`. The styler, the page drawing
/// (`EditorDecorations`) and the editing commands (`MarkdownEditing`) are the
/// shared ones; here is UIKit's share: the view, the two drawing layers under and
/// over the text, the header and footer, touches, and the bar above the keyboard.
public final class MarkdownTextView: UITextView {
    var palette: EditorPalette
    let styler: MarkdownStyler
    let document: NoteDocument
    let features: EditorFeatures
    /// The pictures and link cards laid under their lines (shared with the Mac).
    private(set) lazy var overlays = OverlayController(textView: self)
    /// Room kept clear at the top and bottom of the content (the status bar and the home
    /// indicator in page mode, the view running under both), set by the editor wrapper.
    var outerInsets = UIEdgeInsets.zero {
        didSet { if outerInsets != oldValue { updateTopInset(); setNeedsLayout() } }
    }
    /// Known tags for `#` completion, most used first (set by the editor wrapper).
    var knownTags: () -> [String] = { [] }
    /// Folding: the "n lines" pills drawn after folded headings (for taps). A phone
    /// has no pointer, so nothing is ever hovered.
    var foldPills: [Int: CGRect] = [:]
    var hoverHeading: Int?
    var hoverTaskMark: Int?
    /// The tag list and the Format buttons shown above the keyboard.
    let accessory = EditorAccessoryModel()
    private var accessoryHost: UIHostingController<EditorAccessoryBar>?
    private var completionScheduled = false
    /// The last word accepted (or dismissed) from the tag list, so the list does
    /// not pop straight back up over it.
    private var lastCompletion: (location: Int, word: String)?
    /// The `#tag` the open list would replace.
    private var popupPartial: TagCompletion.Partial?
    private var syncingOverlays = false
    /// Set while the selection is being corrected or a replacement made, so the
    /// selection hook does not run on its own doing.
    private var settingSelection = false
    private var lastCaret = 0
    /// The page's own drawing: ruling, backdrops, quote bars and fold controls go
    /// under the text (TextKit 2 draws it in subviews of its own, so a layer of
    /// ours below them is the only way under); the bullets go over it.
    private let underlay = DecorationView()
    private let overlay = DecorationView()

    public init(document: NoteDocument, palette: EditorPalette, features: EditorFeatures = .all) {
        self.palette = palette
        self.document = document
        self.features = features
        self.styler = MarkdownStyler(palette: palette)
        let contentStorage = NSTextContentStorage()
        contentStorage.textStorage = document.textStorage
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        // A container owned by an NSTextLayoutManager makes this a TextKit 2 view;
        // `layoutManager` must never be read, or it falls back to TextKit 1.
        super.init(frame: .zero, textContainer: container)
        configure()
        styler.onStyled = { [weak self] in self?.overlaysChanged() }
        styler.host = self
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
            self.setNeedsDisplayDecorations()
        }
        styler.attach(to: document.textStorage)
        underlay.draws = { [weak self] ctx, rect in
            guard let self else { return }
            EditorDecorations(geometry: self).drawUnderText(in: ctx, rect: rect)
        }
        overlay.draws = { [weak self] ctx, rect in
            guard let self else { return }
            EditorDecorations(geometry: self).drawOverText(in: ctx, rect: rect)
        }
        insertSubview(underlay, at: 0)
        addSubview(overlay)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
        installAccessoryBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        backgroundColor = .clear
        isScrollEnabled = true
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        keyboardDismissMode = .interactive
        allowsEditingTextAttributes = false
        autocorrectionType = .no
        autocapitalizationType = .sentences
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = features.contains(.textChecking) ? .yes : .no
        // The system find bar (⌘F on a hardware keyboard, the bar's magnifier otherwise).
        isFindInteractionEnabled = true
        applyPalette()
    }

    func applyPalette() {
        textColor = palette.ink
        font = palette.body
        tintColor = palette.ink
        linkTextAttributes = [.foregroundColor: palette.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                              .underlineColor: palette.accent.withAlphaComponent(0.5)]
        typingAttributes = palette.baseAttributes
        accessory.theme = palette.theme
        updateTopInset()
        setNeedsDisplayDecorations()
    }

    /// Re-apply all display attributes (after a palette change).
    func restyleAll() {
        styler.palette = palette
        styler.restyleAll()
    }

    // MARK: Hooks from the delegate

    /// Called after every edit, as the Mac's `didChangeText`.
    func textDidChange() {
        overlays.select(nil)
        scheduleTagListUpdate(open: true)
    }

    /// A caret can't rest on a collapsed image/URL line or inside a folded section:
    /// step over the whole run in the direction of travel, so taps and arrow keys
    /// never expand the markdown or land in hidden text.
    func selectionDidChange() {
        guard !settingSelection else { return }
        var selection = selectedRange
        if selection.length == 0 {
            let caret = selection.location
            let lines = styler.blockMap.lines
            if let line = styler.blockMap.line(at: caret), styler.skipsCaret(line: line.index) {
                let length = markdownText.length
                let forward = caret >= lastCaret
                var first = line.index, last = line.index
                while first > 0, styler.skipsCaret(line: first - 1) { first -= 1 }
                while last + 1 < lines.count, styler.skipsCaret(line: last + 1) { last += 1 }
                let runEnd = lines[last].range.location + lines[last].range.length
                let target: Int
                if forward, last + 1 < lines.count {
                    target = runEnd + 1
                } else if forward, styler.isCollapsed(line: last) {
                    target = length
                    DispatchQueue.main.async { [weak self] in self?.addLineAfterLastOverlay() }
                } else if first > 0 {
                    target = lines[first].range.location - 1
                } else {
                    target = min(length, runEnd + 1)
                }
                selection = NSRange(location: target, length: 0)
                settingSelection = true
                selectedRange = selection
                settingSelection = false
            }
            lastCaret = selection.location
        }
        invalidate(lines: styler.selectionChanged())
        scheduleTagListUpdate(open: false)
    }

    private func addLineAfterLastOverlay() {
        let length = markdownText.length
        guard let line = styler.blockMap.line(at: length), styler.isCollapsed(line: line.index),
              line.range.location + line.range.length >= length else { return }
        replace(NSRange(location: length, length: 0), with: "\n")
        markdownSelection = NSRange(location: length + 1, length: 0)
    }

    /// Return and Tab from the keyboard, before the text view inserts them: a Return
    /// accepts the highlighted tag, else continues a list; a Tab indents one.
    func shouldChange(in range: NSRange, replacement text: String) -> Bool {
        if text == "\n" {
            if !accessory.tags.tags.isEmpty, let tag = accessory.tags.selectedTag {
                acceptTag(tag)
                return false
            }
            if range.length == 0, range == selectedRange, returnPressed() { return false }
        }
        if text == "\t", range.length == 0, range == selectedRange, indentListLines(by: 1) { return false }
        return true
    }

    public override func resignFirstResponder() -> Bool {
        hideTagList()
        return super.resignFirstResponder()
    }

    // MARK: Tag completion

    /// Re-check after the edit or selection change has settled (the styler and
    /// UIKit are still mid-update when these hooks run).
    private func scheduleTagListUpdate(open: Bool) {
        guard !completionScheduled, open || !accessory.tags.tags.isEmpty else { return }
        completionScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.completionScheduled = false
            self?.updateTagList(open: open)
        }
    }

    /// Offer, refresh or clear the list for the tag at the caret; `open` is false
    /// for caret moves, which only keep an open list up to date.
    private func updateTagList(open: Bool) {
        guard isFirstResponder, selectedRange.length == 0, markedTextRange == nil,
              open || !accessory.tags.tags.isEmpty,
              let partial = TagCompletion.partial(in: text, caret: selectedRange.location) else { hideTagList(); return }
        let ns = markdownText
        if partial.text.isEmpty {
            let lineStart = ns.lineRange(for: NSRange(location: partial.range.location, length: 0)).location
            if partial.range.location == lineStart { hideTagList(); return }
        }
        let word = ns.substring(with: partial.range)
        if let last = lastCompletion, last.location == partial.range.location, last.word == word { hideTagList(); return }
        let matches = TagCompletion.matches(for: partial.text, in: knownTags())
        guard !matches.isEmpty else { hideTagList(); return }
        popupPartial = partial
        accessory.tags.offer(matches, theme: palette.theme) { [weak self] tag in self?.acceptTag(tag) }
    }

    private func hideTagList() {
        popupPartial = nil
        if !accessory.tags.tags.isEmpty { accessory.tags.tags = [] }
    }

    private func acceptTag(_ tag: String) {
        guard let partial = popupPartial else { return }
        let word = "#" + tag
        lastCompletion = (partial.range.location, word)
        hideTagList()
        replace(partial.range, with: word)
        markdownSelection = NSRange(location: partial.range.location + (word as NSString).length, length: 0)
    }

    // MARK: The bar above the keyboard

    private func installAccessoryBar() {
        accessory.theme = palette.theme
        accessory.onCommand = { [weak self] command in self?.perform(command) }
        if features.contains(.attachments) { accessory.onPickPhoto = { [weak self] in self?.pickPhoto() } }
        accessory.onFind = { [weak self] in self?.findInteraction?.presentFindNavigator(showingReplace: false) }
        let host = UIHostingController(rootView: EditorAccessoryBar(model: accessory))
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: EditorAccessoryBar.height)
        host.view.autoresizingMask = [.flexibleWidth]
        accessoryHost = host
        inputAccessoryView = host.view
    }

    /// A Format command from the bar, to the same methods the Mac's menu reaches.
    func perform(_ command: EditorCommand) {
        _ = perform(command.selector, with: nil)
    }

    // MARK: Header

    /// A view laid under the note's opening heading (today's Today-status tasks), in
    /// space the styler reserves below that line, so it sits on the ruling and
    /// scrolls with the note. The text storage is untouched.
    var headerView: UIView? {
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

    /// Without a heading to sit under, the header takes whole lines above the text;
    /// the footer's room is a line under the text, the footer, and a line more.
    private func updateTopInset() {
        let top = palette.pitch * EditorMetrics.topLines + (headerAnchor == nil ? headerReservation : 0) + outerInsets.top
        let bottom = (footerReservation > 0 ? palette.pitch * 2 + footerReservation : palette.pitch) + outerInsets.bottom
        let insets = UIEdgeInsets(top: top, left: EditorMetrics.leftInset, bottom: bottom, right: EditorMetrics.rightInset)
        if textContainerInset != insets { textContainerInset = insets }
        let bars = UIEdgeInsets(top: outerInsets.top, left: 0, bottom: outerInsets.bottom, right: 0)
        if verticalScrollIndicatorInsets != bars { verticalScrollIndicatorInsets = bars }
    }

    /// Under its line, moved down as the Tasks tab's rows are so each row sits on a rule.
    private func positionHeader() {
        guard let headerView else { return }
        var top = palette.pitch * EditorMetrics.topLines
        if let anchor = headerAnchor, let bottom = lineBottom(for: styler.blockMap.lines[anchor].range) { top = bottom }
        let width = max(120, bounds.width - EditorMetrics.leftInset - EditorMetrics.headerRightInset)
        headerView.frame = CGRect(x: EditorMetrics.leftInset, y: top + PageRuling.rowShift(palette),
                                  width: width, height: max(1, headerHeight))
    }

    // MARK: Footer

    /// A view laid after the note's last line (the day's handwritten Scribe pages).
    var footerView: UIView? {
        didSet {
            guard footerView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let footerView { addSubview(footerView) }
            updateTopInset()
            setNeedsLayout()
        }
    }

    var footerHeight: CGFloat = 0 {
        didSet { if footerHeight != oldValue { updateTopInset(); setNeedsLayout() } }
    }

    var footerReservation: CGFloat {
        guard footerView != nil, footerHeight > 0 else { return 0 }
        return ceil(footerHeight / palette.pitch - 0.01) * palette.pitch
    }

    /// Where the text ends, including the empty last line.
    var textBottom: CGFloat {
        (textLayoutManager?.usageBoundsForTextContainer.maxY ?? 0) + textContainerInset.top
    }

    private func positionFooter() {
        guard let footerView else { return }
        let width = max(120, bounds.width - EditorMetrics.leftInset - EditorMetrics.headerRightInset)
        footerView.frame = CGRect(x: EditorMetrics.leftInset, y: textBottom + palette.pitch + PageRuling.rowShift(palette),
                                  width: width, height: max(1, footerHeight))
    }

    // MARK: Pictures from the photo library

    /// The bar's photo button: the system picker, presented over the page; the picked
    /// image's own bytes go to `Attachments/` and its line is inserted at the caret.
    private func pickPhoto() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        var presenter = window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(picker, animated: true)
    }

    /// Image data from the pasteboard, under the first image type each item carries.
    private func pastedImageData(_ pb: UIPasteboard) -> [Data] {
        var out: [Data] = []
        for (i, item) in pb.items.enumerated() {
            guard let type = item.keys.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .image) }),
                  let data = pb.data(forPasteboardType: type.identifier, inItemSet: IndexSet(integer: i))?.first else { continue }
            out.append(data)
        }
        return out
    }

    // MARK: Paste

    /// Paste offers itself for a copied picture too (the text view alone only asks for text).
    public override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), features.contains(.attachments), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// As the Mac's: a picture goes to `Attachments/` and its line is inserted; a bare web
    /// address links the selection or takes a line of its own (for a card); text wins
    /// over a picture when both are on the pasteboard.
    public override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if features.contains(.attachments), !pb.hasStrings, pb.hasImages {
            let lines = pastedImageData(pb).compactMap { AttachmentImporter.importImageData($0, document: document) }
            if lines.isEmpty, let image = pb.image, let md = AttachmentImporter.importImage(image, document: document) {
                insertMarkdown(md, ownLine: true)
            }
            for md in lines { insertMarkdown(md, ownLine: true) }
            return
        }
        if features.contains(.linkPreviews), let s = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: s), let scheme = url.scheme, ["http", "https"].contains(scheme), !s.contains(" ") {
            if selectedRange.length > 0 {
                insertMarkdown("[\(markdownText.substring(with: selectedRange))](\(s))", ownLine: false)
            } else {
                insertMarkdown(s, ownLine: true)
            }
            return
        }
        super.paste(sender)
    }

    // MARK: Overlays

    /// An overlay's size changed or it went away.
    func refreshOverlays() { overlaysChanged() }

    /// The pictures and cards, and the header's room under the opening heading, are
    /// reserved as paragraph spacing by the styler; the controller places the views.
    private func overlaysChanged() {
        guard !syncingOverlays else { return }
        syncingOverlays = true
        defer { syncingOverlays = false }
        updateTopInset()
        let before = styler.overlayHeights
        if overlays.sync(map: styler.blockMap) {
            let heights = styler.overlayHeights
            let changed = Set(before.keys).union(heights.keys).filter { before[$0] != heights[$0] }
            if !changed.isEmpty {
                styler.restyle(lines: Array(changed))
                if let first = changed.min() {
                    // Not from inside the storage's edit processing (a pasted picture): TextKit 2's
                    // content storage hears of the characters only after the styler's callback
                    // returns, and a viewport laid out before that throws on the next layout pass
                    // (the Mac's paste crash of 2026-10-26). Lay out once the edit is through.
                    if styler.isProcessingEdit {
                        DispatchQueue.main.async { [weak self] in self?.relayout(fromLine: first) }
                    } else {
                        relayout(fromLine: first)
                    }
                }
            }
        }
        setNeedsLayout()
        setNeedsDisplayDecorations()
    }

    /// A paragraph that grew moves every line after it; TextKit 2 relays the edited paragraph
    /// alone, so lay out again from there to the end. Never from inside the storage's edit
    /// processing: see `overlaysChanged`.
    private func relayout(fromLine first: Int) {
        guard let lm = textLayoutManager, first < styler.blockMap.lines.count,
              let from = lm.location(lm.documentRange.location, offsetBy: styler.blockMap.lines[first].range.location),
              let range = NSTextRange(location: from, end: lm.documentRange.endLocation) else { return }
        lm.invalidateLayout(for: range)
        lm.textViewportLayoutController.layoutViewport()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // The drawing layers cover the visible part of the note and a screen above and
        // below it, moved along as the note scrolls, so no bitmap the length of the
        // note is ever held; they stay under and over TextKit's own views.
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        let wanted = visible.insetBy(dx: 0, dy: -bounds.height)
        for layer in [underlay, overlay] where !layer.frame.contains(visible) || layer.frame.width != visible.width {
            layer.frame = wanted
            layer.setNeedsDisplay()
        }
        if subviews.first !== underlay { sendSubviewToBack(underlay) }
        if subviews.last !== overlay { bringSubviewToFront(overlay) }
        positionHeader()
        positionFooter()
        if overlays.reposition() {
            // Width changed: reserve new heights on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in self?.overlaysChanged() }
        }
    }

    // MARK: Taps

    /// A tap on a task's checkbox cycles its status; one on a fold chevron or pill
    /// toggles the fold. The text view's own tap still runs (it places the caret), so
    /// the selection is put back and a keyboard the tap would have raised is not.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        // A picture or card takes its own taps; one on the text lets a selected picture go.
        if overlays.overlayView(at: point) != nil { return }
        overlays.select(nil)
        let wasEditing = isFirstResponder
        let selection = selectedRange
        if let heading = foldControl(at: point) {
            toggleFold(heading: heading)
            setNeedsDisplayDecorations()
            restore(selection: selection, editing: wasEditing)
            return
        }
        if let hit = taskMarkRange(at: point) {
            let line = styler.blockMap.lines[hit.line]
            if let parsed = TaskLineParser.parse(line.text),
               let replaced = TaskLineParser.replacingStatus(in: line.text, with: parsed.status.next) {
                replace(line.range, with: replaced)
                restore(selection: selection, editing: wasEditing)
            }
        }
    }

    private func restore(selection: NSRange, editing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if selection.location + selection.length <= self.markdownText.length { self.selectedRange = selection }
            if !editing { _ = self.resignFirstResponder() }
        }
    }

    /// The character offset nearest `point` (in the view's coordinates).
    func characterIndex(at point: CGPoint) -> Int {
        guard let position = closestPosition(to: point) else { return markdownText.length }
        return offset(from: beginningOfDocument, to: position)
    }

    /// The `[ ]` of a task line, as a character range, when the point is on it.
    func taskMarkRange(at point: CGPoint) -> (line: Int, range: NSRange)? {
        let index = characterIndex(at: point)
        guard let line = styler.blockMap.line(at: index), case .task = line.kind, !styler.isHidden(line: line.index),
              let parsed = TaskLineParser.parse(line.text) else { return nil }
        let range = NSRange(location: line.range.location + parsed.markOffset - 1, length: 3)
        guard let rect = characterRect(for: range), rect.insetBy(dx: -8, dy: -4).contains(point) else { return nil }
        return (line.index, range)
    }

    // MARK: Folding

    /// The heading whose chevron or "n lines" pill is under `point`, if any.
    func foldControl(at point: CGPoint) -> Int? {
        for (index, rect) in foldPills where rect.insetBy(dx: -6, dy: -6).contains(point) { return index }
        let zone = (EditorMetrics.leftInset - EditorMetrics.marginRuleOffset - 6)...(EditorMetrics.leftInset - 2)
        guard zone.contains(point.x) else { return nil }
        let index = characterIndex(at: CGPoint(x: EditorMetrics.leftInset + 2, y: point.y))
        guard let line = styler.blockMap.line(at: index), case .heading = line.kind,
              styler.sectionEnd(afterHeading: line.index) > line.index + 1,
              let rect = fragmentRect(for: line.range), rect.minY <= point.y, point.y < rect.minY + palette.pitch else { return nil }
        return line.index
    }

    /// Fold or unfold the section under a heading; a caret left inside goes to the heading's end.
    func setFold(_ folded: Bool, heading index: Int) {
        guard styler.isFolded(heading: index) != folded else { return }
        styler.setFolded(folded, heading: index)
        caretOutOfHiddenText(preferring: index)
    }

    func toggleFold(heading index: Int) { setFold(!styler.isFolded(heading: index), heading: index) }

    /// After a fold, a caret that was in the section moves to the end of its heading.
    private func caretOutOfHiddenText(preferring heading: Int?) {
        let caret = selectedRange
        guard caret.length == 0, let line = styler.blockMap.line(at: caret.location), styler.isHidden(line: line.index) else { return }
        var index = heading ?? line.index
        while index > 0, styler.isHidden(line: index) { index -= 1 }
        let h = styler.blockMap.lines[index].range
        markdownSelection = NSRange(location: h.location + h.length, length: 0)
    }

    /// The heading the caret's line belongs to: the line itself when it is one, else the nearest above.
    private func headingForCaret() -> Int? {
        guard let line = styler.blockMap.line(at: selectedRange.location) else { return nil }
        var i = line.index
        while i >= 0 {
            if case .heading = styler.blockMap.lines[i].kind { return i }
            i -= 1
        }
        return nil
    }

    @objc func foldSection(_ sender: Any?) {
        guard let h = headingForCaret(), styler.sectionEnd(afterHeading: h) > h + 1 else { return }
        setFold(true, heading: h)
        setNeedsDisplayDecorations()
    }

    @objc func unfoldSection(_ sender: Any?) {
        guard var i = headingForCaret() else { return }
        // The caret's own heading, or the nearest folded one above it.
        while i >= 0 {
            if styler.isFolded(heading: i) { setFold(false, heading: i); setNeedsDisplayDecorations(); return }
            i -= 1
        }
    }

    @objc func foldAllSections(_ sender: Any?) {
        styler.setAllFolded(true)
        caretOutOfHiddenText(preferring: nil)
        setNeedsDisplayDecorations()
    }

    @objc func unfoldAllSections(_ sender: Any?) {
        styler.setAllFolded(false)
        setNeedsDisplayDecorations()
    }

    // MARK: The Format commands

    @objc func toggleBold(_ sender: Any?) { toggleInline("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleInline("*") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleInline("~~") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleInline("`") }
    @objc func insertLink(_ sender: Any?) { insertLinkMarkdown() }
    @objc func heading1(_ sender: Any?) { setHeading(level: 1) }
    @objc func heading2(_ sender: Any?) { setHeading(level: 2) }
    @objc func heading3(_ sender: Any?) { setHeading(level: 3) }
    @objc func heading4(_ sender: Any?) { setHeading(level: 4) }
    @objc func heading5(_ sender: Any?) { setHeading(level: 5) }
    @objc func heading6(_ sender: Any?) { setHeading(level: 6) }
    @objc func toggleBulletList(_ sender: Any?) { setPrefix(.bullet("-")) }
    @objc func toggleNumberedList(_ sender: Any?) { setPrefix(.numbered(1, ".")) }
    @objc func toggleTask(_ sender: Any?) { setPrefix(.task(bullet: "-", status: .notStarted)) }
    @objc func toggleQuote(_ sender: Any?) { setPrefix(.quote) }
    @objc func toggleTaskDone(_ sender: Any?) { toggleTaskDoneLines() }
    @objc func toggleCodeBlock(_ sender: Any?) { toggleCodeBlockLines() }
    @objc func insertHorizontalRule(_ sender: Any?) { insertMarkdown("---", ownLine: true) }

    // MARK: Drawing

    /// Redraw whole line bands (margin included) for lines whose look changed
    /// with the selection: bullets and chevrons are ours, not TextKit's.
    func invalidate(lines: Set<Int>) {
        let map = styler.blockMap
        for i in lines where i < map.lines.count {
            guard let r = fragmentRect(for: map.lines[i].range) else { continue }
            setNeedsDisplayDecorations(CGRect(x: 0, y: r.minY - 2, width: bounds.width, height: r.height + 4))
        }
    }

    /// Redraw the page's own drawing, everywhere or within `rect` (view coordinates).
    func setNeedsDisplayDecorations(_ rect: CGRect? = nil) {
        for layer in [underlay, overlay] {
            if let rect { layer.setNeedsDisplay(rect.offsetBy(dx: -layer.frame.origin.x, dy: -layer.frame.origin.y)) }
            else { layer.setNeedsDisplay() }
        }
    }
}

/// One layer of the page's own drawing, drawn in text-view coordinates whatever
/// its own frame is.
final class DecorationView: UIView {
    var draws: ((CGContext, CGRect) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.translateBy(x: -frame.origin.x, y: -frame.origin.y)
        draws?(ctx, rect.offsetBy(dx: frame.origin.x, dy: frame.origin.y))
    }
}

/// The page's drawing lives in `EditorDecorations`; it reads the layout through this.
extension MarkdownTextView: DecorationGeometry {
    var textOrigin: CGPoint { CGPoint(x: textContainerInset.left, y: textContainerInset.top) }
    var viewWidth: CGFloat { bounds.width }
}

extension MarkdownTextView: StylerHost {
    var selectedCharacterRanges: [NSRange] { [selectedRange] }
}

extension MarkdownTextView: MarkdownEditing {
    var markdownStorage: NSTextStorage? { textStorage }

    var markdownSelection: NSRange {
        get { selectedRange }
        set { selectedRange = newValue }
    }

    /// One undoable replacement, made the way typing is (select, then insert) so
    /// the undo manager and the delegate hear of it as they do of a keystroke.
    @discardableResult
    func replace(_ range: NSRange, with text: String) -> Bool {
        guard range.location + range.length <= markdownText.length else { return false }
        settingSelection = true
        selectedRange = range
        settingSelection = false
        if text.isEmpty {
            if range.length > 0 { deleteBackward() }
        } else {
            insertText(text)
        }
        return true
    }

    func proposedWordRange(at location: Int) -> NSRange? {
        guard let position = position(from: beginningOfDocument, offset: location),
              let range = tokenizer.rangeEnclosingPosition(position, with: .word, inDirection: .storage(.forward)) else { return nil }
        return NSRange(location: offset(from: beginningOfDocument, to: range.start), length: offset(from: range.start, to: range.end))
    }

    func beginUndoGroup() { undoManager?.beginUndoGrouping() }

    func endUndoGroup() { undoManager?.endUndoGrouping() }

    func clipboardString() -> String? { Platform.pasteboardString() }
}

extension MarkdownTextView: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                guard let self, let md = AttachmentImporter.importImageData(data, document: self.document) else { return }
                self.insertMarkdown(md, ownLine: true)
            }
        }
    }
}

extension MarkdownTextView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
