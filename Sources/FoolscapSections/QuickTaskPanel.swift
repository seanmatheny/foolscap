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

    public func dismiss() { panel?.orderOut(nil) }

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
        if selector == #selector(NSResponder.cancelOperation(_:)) { dismiss(); return true }
        return false
    }

    // MARK: Tag completion

    /// After a typed character (not an arrow or a click in the completion list),
    /// open the system completion list when a `#tag` is being typed.
    public func controlTextDidChange(_ obj: Notification) {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let scalar = event.characters?.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), !(0xF700...0xF8FF).contains(scalar.value),
              let editor = field.currentEditor() as? NSTextView,
              let partial = TagCompletion.partial(in: editor.string, caret: editor.selectedRange().location),
              !partial.text.isEmpty, !TagCompletion.matches(for: partial.text, in: knownTags).isEmpty else { return }
        editor.complete(nil)
    }

    /// The field editor decides which word it replaces (it may or may not take
    /// the `#`), so each candidate is trimmed to what that range covers.
    public func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                        forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        guard let partial = TagCompletion.partial(in: textView.string, caret: charRange.location + charRange.length),
              charRange.location >= partial.range.location else { return [] }
        let skip = charRange.location - partial.range.location
        index.pointee = 0
        return TagCompletion.matches(for: partial.text, in: knownTags).map { String(("#" + $0).dropFirst(skip)) }
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
