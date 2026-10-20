#if canImport(UIKit) && !canImport(AppKit)
import SwiftUI
import UIKit
import FoolscapCore
import FoolscapStore
import FoolscapUI

/// SwiftUI wrapper: the phone's MarkdownTextView (its own scroll view) bound to
/// one document. The same `init` as the Mac's, so the pages are written once.
public struct MarkdownEditor: UIViewRepresentable {
    let document: NoteDocument
    let revealLine: Int?
    /// Known tags, most used first, for `#` completion while typing.
    let tags: () -> [String]
    /// Laid under the note's opening heading, on the ruling (today's Today-status tasks).
    let header: AnyView?
    /// Laid after the note's last line (the day's handwritten pages).
    let footer: AnyView?
    let features: EditorFeatures
    let onEdit: () -> Void
    @Environment(\.notebookTheme) private var theme

    public init(document: NoteDocument, revealLine: Int? = nil, tags: @escaping () -> [String] = { [] },
                header: AnyView? = nil, footer: AnyView? = nil, features: EditorFeatures = .all, onEdit: @escaping () -> Void) {
        self.document = document
        self.revealLine = revealLine
        self.tags = tags
        self.header = header
        self.footer = footer
        self.features = features
        self.onEdit = onEdit
    }

    public func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    public func makeUIView(context: Context) -> MarkdownTextView {
        let palette = EditorPalette(theme: theme)
        let textView = MarkdownTextView(document: document, palette: palette, features: features)
        textView.knownTags = tags
        textView.delegate = context.coordinator
        // The caret starts after the last line (a daily note's blank line under its
        // Today list), ready to type; the opening heading keeps its `#` hidden.
        if revealLine == nil { textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0) }
        context.coordinator.textView = textView
        updateHeader(textView, context: context)
        updateFooter(textView, context: context)
        context.coordinator.hostedHeader = header != nil
        context.coordinator.hostedFooter = footer != nil
        return textView
    }

    public func updateUIView(_ textView: MarkdownTextView, context: Context) {
        textView.knownTags = tags
        // The fonts and the hosted views are only rebuilt when the theme changed or a
        // header/footer came or went; the hosted views observe their own models.
        let themeChanged = textView.palette.theme != theme
        if themeChanged || context.coordinator.hostedHeader != (header != nil) {
            updateHeader(textView, context: context)
            context.coordinator.hostedHeader = header != nil
        }
        if themeChanged || context.coordinator.hostedFooter != (footer != nil) {
            updateFooter(textView, context: context)
            context.coordinator.hostedFooter = footer != nil
        }
        if themeChanged {
            let palette = EditorPalette(theme: theme)
            textView.palette.theme = theme
            if palette.body != textView.palette.body || palette.headings != textView.palette.headings
                || palette.mono != textView.palette.mono || palette.ink != textView.palette.ink
                || palette.ruling != textView.palette.ruling || palette.showMarginRule != textView.palette.showMarginRule {
                textView.palette = palette
                textView.applyPalette()
                textView.restyleAll()
                textView.refreshOverlays()
            }
        }
        if let line = revealLine, context.coordinator.revealedLine != line {
            context.coordinator.revealedLine = line
            let map = textView.styler.blockMap
            if line < map.lines.count {
                let range = map.lines[line].range
                textView.styler.unfold(toReveal: line)
                DispatchQueue.main.async {
                    textView.selectedRange = range
                    textView.scrollRangeToVisible(range)
                    textView.becomeFirstResponder()
                }
            }
        }
    }

    /// The header runs in a hosting controller of its own, so it is handed the theme
    /// here; it reports its height, and the text view makes room for it.
    private func updateHeader(_ textView: MarkdownTextView, context: Context) {
        guard let header else { textView.headerView = nil; textView.headerHeight = 0; context.coordinator.headerHost = nil; return }
        let root = AnyView(header
            .environment(\.notebookTheme, theme)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak textView] height in
                // Not during the layout pass that measured it: reserving space restyles the text.
                DispatchQueue.main.async { textView?.headerHeight = height }
            }
            .frame(maxHeight: .infinity, alignment: .top))
        if let host = context.coordinator.headerHost {
            host.rootView = root
        } else {
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            context.coordinator.headerHost = host
            textView.headerView = host.view
        }
    }

    /// The footer: the same arrangement, placed after the last line.
    private func updateFooter(_ textView: MarkdownTextView, context: Context) {
        guard let footer else { textView.footerView = nil; textView.footerHeight = 0; context.coordinator.footerHost = nil; return }
        let root = AnyView(footer
            .environment(\.notebookTheme, theme)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak textView] height in
                DispatchQueue.main.async { textView?.footerHeight = height }
            }
            .frame(maxHeight: .infinity, alignment: .top))
        if let host = context.coordinator.footerHost {
            host.rootView = root
        } else {
            let host = UIHostingController(rootView: root)
            host.view.backgroundColor = .clear
            context.coordinator.footerHost = host
            textView.footerView = host.view
        }
    }

    @MainActor
    public final class Coordinator: NSObject, UITextViewDelegate {
        var textView: MarkdownTextView?
        var headerHost: UIHostingController<AnyView>?
        var footerHost: UIHostingController<AnyView>?
        var revealedLine: Int?
        /// Whether a header/footer is hosted, so a re-render without one coming or going
        /// leaves the hosted views alone.
        var hostedHeader = false, hostedFooter = false
        let onEdit: () -> Void
        init(onEdit: @escaping () -> Void) { self.onEdit = onEdit }

        public func textViewDidChange(_ textView: UITextView) {
            (textView as? MarkdownTextView)?.textDidChange()
            onEdit()
        }

        public func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? MarkdownTextView)?.selectionDidChange()
        }

        public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            (textView as? MarkdownTextView)?.shouldChange(in: range, replacement: text) ?? true
        }

        public func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content {
                return UIAction { _ in Platform.openURL(url) }
            }
            return defaultAction
        }
    }
}
#endif
