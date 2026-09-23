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

    public func toggle(library: NotebookLibrary, theme: NotebookTheme) {
        if let panel, panel.isVisible { dismiss(); return }
        show(library: library, theme: theme)
    }

    public func show(library: NotebookLibrary, theme: NotebookTheme) {
        self.library = library
        self.theme = theme
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
    }

    public func dismiss() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 88),
                            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: false)
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
        paper.accent = theme.accent.nsColor
        paper.needsDisplay = true
        field.font = theme.type.body.nsFont.withSize(19)
        field.textColor = theme.ink.nsColor
        hint.font = NSFont(name: theme.type.body.family ?? "Charter", size: 11) ?? .systemFont(ofSize: 11)
        hint.textColor = theme.dimInk.nsColor
    }

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let library else { dismiss(); return }
        library.addStandaloneTask(text)
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

    /// Rounded paper card with the theme's texture and an accent rule.
    final class PaperView: NSView {
        var paperColor: NSColor = .white
        var texture: NSImage?
        var textureOpacity: CGFloat = 0.5
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
                                     operation: .softLight, fraction: textureOpacity)
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
