import AppKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// A floating, non-activating panel for jotting a task from anywhere.
/// Enter appends it to today's note; Escape dismisses.
@MainActor
public final class QuickTaskPanel: NSObject, NSTextFieldDelegate {
    public static let shared = QuickTaskPanel()
    private var panel: NSPanel?
    private let field = NSTextField()
    private let hint = NSTextField(labelWithString: "")
    private var library: NotebookLibrary?
    private var theme: NotebookTheme = .classicBlack
    private var confirmTimer: Timer?
    /// Tags for `#` completion, fetched when the panel opens.
    private var knownTags: [String] = []
    private let tagPopup = TagCompletionPopup()
    /// The `#tag` the open list would replace.
    private var popupPartial: TagCompletion.Partial?
    /// A tag just accepted or dismissed, so the list does not reopen over it.
    private var dismissedTag: (location: Int, word: String)?

    public func toggle(library: NotebookLibrary, theme: NotebookTheme) {
        if let panel, panel.isVisible { dismiss(); return }
        show(library: library, theme: theme)
    }

    public func show(library: NotebookLibrary, theme: NotebookTheme) {
        self.library = library
        self.theme = theme
        knownTags = library.knownTags
        let panel = self.panel ?? makePanel()
        style(panel)
        field.stringValue = ""
        dismissedTag = nil
        hint.stringValue = "Return adds to the Tasks tab · #tags welcome · Esc closes"
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 140)
            panel.setFrameOrigin(origin)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.selectText(nil)
    }

    public func dismiss() {
        hideTagList()
        panel?.orderOut(nil)
    }

    /// Borderless panels refuse key status by default; this one must take
    /// keyboard input without activating the app.
    final class KeyablePanel: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
        override func resignKey() { super.resignKey(); onCancel?() }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 88),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let paper = PaperView()
        paper.frame = panel.contentView!.bounds
        paper.autoresizingMask = [.width, .height]
        panel.contentView = paper

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "New task…"
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.frame = NSRect(x: 22, y: 40, width: 476, height: 30)
        field.autoresizingMask = [.width]
        paper.addSubview(field)

        hint.frame = NSRect(x: 24, y: 14, width: 472, height: 16)
        hint.autoresizingMask = [.width]
        paper.addSubview(hint)
        self.panel = panel
        return panel
    }

    private func style(_ panel: NSPanel) {
        guard let paper = panel.contentView as? PaperView else { return }
        paper.paperColor = theme.page.paperColor.nsColor
        paper.texture = FoolscapUIResources.texture(theme.page.textureTile)
        paper.textureOpacity = theme.page.textureOpacity
        paper.textureBlend = theme.page.textureBlend == .screen ? .screen : theme.page.textureBlend == .multiply ? .multiply : .softLight
        paper.accent = theme.accent.nsColor
        paper.needsDisplay = true
        field.font = theme.type.body.nsFont.withSize(19)
        field.textColor = theme.ink.nsColor
        field.placeholderAttributedString = NSAttributedString(string: "New task…", attributes: [
            .font: theme.type.body.nsFont.withSize(19), .foregroundColor: theme.dimInk.nsColor.withAlphaComponent(0.5)])
        hint.font = NSFont(name: theme.type.body.family ?? "Charter", size: 11) ?? .systemFont(ofSize: 11)
        hint.textColor = theme.dimInk.nsColor
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let library else { dismiss(); return }
        Task { await library.addStandaloneTask(text) }
        field.stringValue = ""
        hint.stringValue = "Added “\(text.prefix(40))” to Tasks."
        confirmTimer?.invalidate()
        confirmTimer = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if tagPopup.isVisible {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): tagPopup.move(-1); return true
            case #selector(NSResponder.moveDown(_:)): tagPopup.move(1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let tag = tagPopup.selectedTag { acceptTag(tag); return true }
            case #selector(NSResponder.cancelOperation(_:)):
                if let partial = popupPartial {
                    dismissedTag = (partial.range.location, (textView.string as NSString).substring(with: partial.range))
                }
                hideTagList()
                return true
            default: hideTagList()   // caret moves leave the tag; edits reopen the list
            }
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        return false
    }

    // MARK: Tag completion

    /// The themed tag list (as in the editor) under a `#tag` being typed; ↑/↓
    /// choose, Return or Tab accept, Escape closes the list, then the panel.
    public func controlTextDidChange(_ obj: Notification) { updateTagList() }

    private func updateTagList() {
        guard let panel, panel.isVisible, let editor = field.currentEditor() as? NSTextView,
              editor.selectedRange().length == 0,
              let partial = TagCompletion.partial(in: editor.string, caret: editor.selectedRange().location) else { hideTagList(); return }
        let word = (editor.string as NSString).substring(with: partial.range)
        if let dismissed = dismissedTag, dismissed.location == partial.range.location, dismissed.word == word { hideTagList(); return }
        let matches = TagCompletion.matches(for: partial.text, in: knownTags)
        let anchor = editor.firstRect(forCharacterRange: partial.range, actualRange: nil)
        guard !matches.isEmpty, anchor != .zero else { hideTagList(); return }
        popupPartial = partial
        tagPopup.show(tags: matches, theme: theme, below: anchor, in: panel) { [weak self] tag in self?.acceptTag(tag) }
    }

    private func hideTagList() {
        popupPartial = nil
        tagPopup.hide()
    }

    private func acceptTag(_ tag: String) {
        guard let partial = popupPartial, let editor = field.currentEditor() as? NSTextView else { return }
        hideTagList()
        let word = "#" + tag + " "
        dismissedTag = (partial.range.location, "#" + tag)
        editor.insertText(word, replacementRange: partial.range)
    }

    /// Rounded paper card with the theme's texture and an accent rule.
    final class PaperView: NSView {
        var paperColor: NSColor = .white
        var texture: NSImage?
        var textureOpacity: CGFloat = 0.5
        var textureBlend: NSCompositingOperation = .softLight
        var accent: NSColor = .red
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
            paperColor.setFill(); path.fill()
            if let texture {
                // Tile the greyscale texture with soft light, like the SwiftUI pages do.
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                let tile = texture.size
                var y: CGFloat = 0
                while y < bounds.height {
                    var x: CGFloat = 0
                    while x < bounds.width {
                        texture.draw(in: NSRect(x: x, y: y, width: tile.width, height: tile.height), from: .zero,
                                     operation: textureBlend, fraction: textureOpacity)
                        x += tile.width
                    }
                    y += tile.height
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.black.withAlphaComponent(0.2).setStroke(); path.lineWidth = 0.5; path.stroke()
            accent.withAlphaComponent(0.7).setFill()
            NSRect(x: 22, y: 36, width: bounds.width - 44, height: 1).fill()
        }
    }
}
