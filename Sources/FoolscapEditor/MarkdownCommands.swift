import AppKit
import FoolscapCore

/// What markdown puts in front of a paragraph's text: a list bullet, a numbered
/// marker, a task mark or a quote mark, after any indent. Pure string work,
/// shared by Return (which continues an item), Tab (which indents one) and the
/// Format menu (which toggles them).
public enum LinePrefix {
    public enum Kind: Equatable, Sendable {
        case bullet(String)
        /// The number and its delimiter, `.` or `)`.
        case numbered(Int, String)
        case task(bullet: String, status: TaskStatus)
        case quote
    }

    public struct Parsed: Equatable, Sendable {
        public var indent: String
        public var kind: Kind
        /// UTF-16 length of the whole prefix: indent, marker and the spaces after it.
        public var length: Int
    }

    // ^(indent)(bullet | number delimiter)(spaces)([mark] spaces)?
    private static let listRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])|(\d+)([.)]))([ \t]+)(?:\[([ xX/])\](?:[ \t]+|$))?"#)
    private static let quoteRegex = try! NSRegularExpression(pattern: #"^>[ ]?"#)
    private static let headingRegex = try! NSRegularExpression(pattern: #"^#{1,6}[ \t]+"#)

    /// One level of list nesting, as CommonMark reads it under a `- ` bullet.
    public static let indentUnit = "  "

    public static func parse(_ line: String) -> Parsed? {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = listRegex.firstMatch(in: line, range: full) {
            let indent = ns.substring(with: m.range(at: 1))
            let markRange = m.range(at: 6)
            if markRange.location != NSNotFound, let status = TaskStatus(mark: Character(ns.substring(with: markRange))) {
                let bullet = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : "-"
                return Parsed(indent: indent, kind: .task(bullet: bullet, status: status), length: m.range.length)
            }
            if m.range(at: 2).location != NSNotFound {
                return Parsed(indent: indent, kind: .bullet(ns.substring(with: m.range(at: 2))), length: m.range.length)
            }
            let number = Int(ns.substring(with: m.range(at: 3))) ?? 1
            return Parsed(indent: indent, kind: .numbered(number, ns.substring(with: m.range(at: 4))), length: m.range.length)
        }
        if let m = quoteRegex.firstMatch(in: line, range: full) {
            return Parsed(indent: "", kind: .quote, length: m.range.length)
        }
        return nil
    }

    /// The marker text for a kind (no indent).
    public static func marker(_ kind: Kind) -> String {
        switch kind {
        case .bullet(let b): return b + " "
        case .numbered(let n, let d): return "\(n)\(d) "
        case .task(let b, let status): return "\(b) [\(status.mark)] "
        case .quote: return "> "
        }
    }

    /// The prefix a new item written after this one starts with: numbers advance,
    /// a new task starts unticked.
    public static func continuation(of p: Parsed) -> String {
        switch p.kind {
        case .numbered(let n, let d): return p.indent + marker(.numbered(n + 1, d))
        case .task(let b, _): return p.indent + marker(.task(bullet: b, status: .notStarted))
        default: return p.indent + marker(p.kind)
        }
    }

    /// One level less indent: a leading tab or up to two spaces go.
    public static func outdented(_ indent: String) -> String {
        if indent.hasPrefix("\t") { return String(indent.dropFirst()) }
        var s = Substring(indent)
        for _ in 0..<indentUnit.count where s.first == " " { s = s.dropFirst() }
        return String(s)
    }

    /// UTF-16 length of a heading marker (`## `) at the start of the line, or 0.
    public static func headingMarkerLength(_ line: String) -> Int {
        headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))?.range.length ?? 0
    }
}

/// The Format menu's commands, sent down the key window's responder chain to the
/// note being edited (`MarkdownTextView` implements them).
public enum EditorCommand: CaseIterable, Sendable {
    case bold, italic, strikethrough, code, link
    case heading1, heading2, heading3, heading4, heading5, heading6
    case bulletList, numberedList, task, toggleTaskDone, quote, codeBlock, horizontalRule
    case foldSection, unfoldSection, foldAll, unfoldAll

    var selector: Selector {
        switch self {
        case .bold: return #selector(MarkdownTextView.toggleBold(_:))
        case .italic: return #selector(MarkdownTextView.toggleItalic(_:))
        case .strikethrough: return #selector(MarkdownTextView.toggleStrikethrough(_:))
        case .code: return #selector(MarkdownTextView.toggleInlineCode(_:))
        case .link: return #selector(MarkdownTextView.insertLink(_:))
        case .heading1: return #selector(MarkdownTextView.heading1(_:))
        case .heading2: return #selector(MarkdownTextView.heading2(_:))
        case .heading3: return #selector(MarkdownTextView.heading3(_:))
        case .heading4: return #selector(MarkdownTextView.heading4(_:))
        case .heading5: return #selector(MarkdownTextView.heading5(_:))
        case .heading6: return #selector(MarkdownTextView.heading6(_:))
        case .bulletList: return #selector(MarkdownTextView.toggleBulletList(_:))
        case .numberedList: return #selector(MarkdownTextView.toggleNumberedList(_:))
        case .task: return #selector(MarkdownTextView.toggleTask(_:))
        case .toggleTaskDone: return #selector(MarkdownTextView.toggleTaskDone(_:))
        case .quote: return #selector(MarkdownTextView.toggleQuote(_:))
        case .codeBlock: return #selector(MarkdownTextView.toggleCodeBlock(_:))
        case .horizontalRule: return #selector(MarkdownTextView.insertHorizontalRule(_:))
        case .foldSection: return #selector(MarkdownTextView.foldSection(_:))
        case .unfoldSection: return #selector(MarkdownTextView.unfoldSection(_:))
        case .foldAll: return #selector(MarkdownTextView.foldAllSections(_:))
        case .unfoldAll: return #selector(MarkdownTextView.unfoldAllSections(_:))
        }
    }

    /// Menu title.
    public var title: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strikethrough: return "Strikethrough"
        case .code: return "Inline Code"
        case .link: return "Link"
        case .heading1: return "Heading 1"
        case .heading2: return "Heading 2"
        case .heading3: return "Heading 3"
        case .heading4: return "Heading 4"
        case .heading5: return "Heading 5"
        case .heading6: return "Heading 6"
        case .bulletList: return "Bulleted List"
        case .numberedList: return "Numbered List"
        case .task: return "Task"
        case .toggleTaskDone: return "Mark Task Done"
        case .quote: return "Block Quote"
        case .codeBlock: return "Code Block"
        case .horizontalRule: return "Horizontal Rule"
        case .foldSection: return "Fold Section"
        case .unfoldSection: return "Unfold Section"
        case .foldAll: return "Fold All Sections"
        case .unfoldAll: return "Unfold All Sections"
        }
    }

    /// Send the command to the note being edited; beeps when no note has the focus.
    @MainActor public func perform() {
        if !NSApp.sendAction(selector, to: nil, from: nil) { NSSound.beep() }
    }
}

// MARK: - Return, Tab and the Format menu

extension MarkdownTextView {
    /// One undoable replacement through the text view's own change hooks.
    @discardableResult
    func replace(_ range: NSRange, with text: String) -> Bool {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text) else { return false }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        return true
    }

    /// Several replacements that undo as one.
    private func grouped(_ edits: () -> Void) {
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        edits()
        undoManager?.endUndoGrouping()
    }

    /// The lines the selection touches (a caret's own line when nothing is selected).
    private var selectedLines: [ScannedLine] {
        let r = selectedRange()
        let map = styler.blockMap
        guard let first = map.line(at: r.location), let last = map.line(at: r.location + r.length) else { return [] }
        // A selection ending at the very start of a line does not take that line in.
        let end = r.length > 0 && last.range.location == r.location + r.length && last.index > first.index ? last.index - 1 : last.index
        return Array(map.lines[first.index...end])
    }

    private func isCode(_ line: ScannedLine) -> Bool {
        switch line.kind { case .fenceOpen, .fenceInside, .fenceClose: return true; default: return false }
    }

    // MARK: Return

    /// Return inside a list item, task or quote starts the next one with the same
    /// marker (numbers count on); on an empty item it ends the list instead, or
    /// steps a nested item out a level. ⇧↩ and ⌥↩ give a plain newline.
    public override func insertNewline(_ sender: Any?) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let caret = selectedRange()
        guard !flags.contains(.shift), !flags.contains(.option), caret.length == 0,
              let line = styler.blockMap.line(at: caret.location) else { super.insertNewline(sender); return }
        // Return on a folded heading opens a line below the folded section, not inside it.
        if case .heading = line.kind, styler.isFolded(heading: line.index) {
            let lastHidden = styler.blockMap.lines[styler.sectionEnd(afterHeading: line.index) - 1]
            let target = lastHidden.range.location + lastHidden.range.length
            replace(NSRange(location: target, length: 0), with: "\n")
            setSelectedRange(NSRange(location: target + 1, length: 0))
            return
        }
        if case .rule = line.kind { super.insertNewline(sender); return }
        guard !isCode(line), let prefix = LinePrefix.parse(line.text),
              caret.location >= line.range.location + prefix.length else { super.insertNewline(sender); return }
        if prefix.length >= line.range.length {
            // An empty item: step out a level, or end the list.
            if prefix.indent.isEmpty {
                replace(line.range, with: "")
                setSelectedRange(NSRange(location: line.range.location, length: 0))
            } else {
                let indentLength = (prefix.indent as NSString).length
                let outdented = LinePrefix.outdented(prefix.indent)
                replace(NSRange(location: line.range.location, length: indentLength), with: outdented)
                setSelectedRange(NSRange(location: line.range.location + line.range.length - indentLength + (outdented as NSString).length, length: 0))
            }
            return
        }
        let insert = "\n" + LinePrefix.continuation(of: prefix)
        replace(caret, with: insert)
        setSelectedRange(NSRange(location: caret.location + (insert as NSString).length, length: 0))
    }

    // MARK: Tab

    /// Tab and ⇧Tab move list items and tasks in and out a level; elsewhere they
    /// insert a tab as usual.
    public override func insertTab(_ sender: Any?) {
        if !indentListLines(by: 1) { super.insertTab(sender) }
    }

    public override func insertBacktab(_ sender: Any?) {
        if !indentListLines(by: -1) { super.insertBacktab(sender) }
    }

    /// Indent (+1) or outdent (-1) every list or task line the selection touches.
    /// False when none of them is one.
    @discardableResult
    func indentListLines(by delta: Int) -> Bool {
        let lines = selectedLines.filter { line in
            if case .rule = line.kind { return false }
            guard !isCode(line), let p = LinePrefix.parse(line.text) else { return false }
            if case .quote = p.kind { return false }
            return true
        }
        guard !lines.isEmpty else { return false }
        let selection = selectedRange()
        var caret = selection.location
        var coveredStart = lines[0].range.location, coveredEnd = lines[lines.count - 1].range.location + lines[lines.count - 1].range.length
        grouped {
            for line in lines.reversed() {
                guard let p = LinePrefix.parse(line.text) else { continue }
                let indentRange = NSRange(location: line.range.location, length: (p.indent as NSString).length)
                let newIndent = delta > 0 ? p.indent + LinePrefix.indentUnit : LinePrefix.outdented(p.indent)
                let change = (newIndent as NSString).length - indentRange.length
                guard change != 0, replace(indentRange, with: newIndent) else { continue }
                coveredEnd += change
                if caret >= line.range.location { caret = max(line.range.location, caret + change) }
            }
        }
        if selection.length == 0 {
            setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            setSelectedRange(NSRange(location: coveredStart, length: coveredEnd - coveredStart))
        }
        return true
    }

    // MARK: Inline styles

    @objc func toggleBold(_ sender: Any?) { toggleInline("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleInline("*") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleInline("~~") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleInline("`") }

    /// The word under a caret, or an empty range at the caret when it is not on one.
    private func wordRange(at location: Int) -> NSRange {
        let ns = string as NSString
        guard ns.length > 0 else { return NSRange(location: location, length: 0) }
        let proposed = selectionRange(forProposedRange: NSRange(location: location, length: 0), granularity: .selectByWord)
        guard proposed.length > 0, proposed.location + proposed.length <= ns.length else { return NSRange(location: location, length: 0) }
        let word = ns.substring(with: proposed)
        let letters = word.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        guard letters, word.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return NSRange(location: location, length: 0) }
        return proposed
    }

    /// Wrap the selection (or the word at the caret) in `marker`, or unwrap it
    /// when the markers are already there.
    func toggleInline(_ marker: String) {
        let ns = string as NSString
        var range = selectedRange()
        if range.length == 0 { range = wordRange(at: range.location) }
        let m = (marker as NSString).length
        // Markers just outside the selection.
        if range.location >= m, range.location + range.length + m <= ns.length,
           ns.substring(with: NSRange(location: range.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: range.location + range.length, length: m)) == marker {
            let inner = ns.substring(with: range)
            replace(NSRange(location: range.location - m, length: range.length + 2 * m), with: inner)
            setSelectedRange(NSRange(location: range.location - m, length: range.length))
            return
        }
        // Markers inside the selection.
        let text = ns.substring(with: range)
        if range.length >= 2 * m, text.hasPrefix(marker), text.hasSuffix(marker) {
            let inner = (text as NSString).substring(with: NSRange(location: m, length: range.length - 2 * m))
            replace(range, with: inner)
            setSelectedRange(NSRange(location: range.location, length: range.length - 2 * m))
            return
        }
        replace(range, with: marker + text + marker)
        setSelectedRange(NSRange(location: range.location + m, length: range.length))
    }

    /// `[text](url)`: the selection (or word) becomes the text, a URL on the
    /// clipboard the address; otherwise the caret lands where the address goes.
    @objc func insertLink(_ sender: Any?) {
        let ns = string as NSString
        var range = selectedRange()
        if range.length == 0 { range = wordRange(at: range.location) }
        let text = ns.substring(with: range)
        let clipboard = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clipboardURL = Self.isWebAddress(clipboard) ? clipboard : nil
        if Self.isWebAddress(text) {
            // The selection is the address: name it.
            replace(range, with: "[](\(text))")
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return
        }
        let url = clipboardURL ?? ""
        replace(range, with: "[\(text)](\(url))")
        if clipboardURL != nil {
            setSelectedRange(NSRange(location: range.location + 1 + range.length + 2 + (url as NSString).length + 1, length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location + 1 + range.length + 2, length: 0))
        }
    }

    private static func isWebAddress(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(" "), let url = URL(string: s), let scheme = url.scheme else { return false }
        return ["http", "https"].contains(scheme)
    }

    // MARK: Headings

    @objc func heading1(_ sender: Any?) { setHeading(level: 1) }
    @objc func heading2(_ sender: Any?) { setHeading(level: 2) }
    @objc func heading3(_ sender: Any?) { setHeading(level: 3) }
    @objc func heading4(_ sender: Any?) { setHeading(level: 4) }
    @objc func heading5(_ sender: Any?) { setHeading(level: 5) }
    @objc func heading6(_ sender: Any?) { setHeading(level: 6) }

    /// Make the selected lines headings of `level`; lines already at that level go back to plain text.
    func setHeading(level: Int) {
        let lines = selectedLines.filter { !isCode($0) }
        guard !lines.isEmpty else { return }
        let marker = String(repeating: "#", count: level) + " "
        let allAtLevel = lines.allSatisfy { if case .heading(let l) = $0.kind { return l == level }; return false }
        rewriteLines(lines) { line in
            let stripped = Self.strippingBlockPrefix(line.text)
            return allAtLevel ? stripped : marker + stripped
        }
    }

    /// A line without its heading marker or list/task/quote prefix (indent kept for lists).
    private static func strippingBlockPrefix(_ text: String) -> String {
        let ns = text as NSString
        let heading = LinePrefix.headingMarkerLength(text)
        if heading > 0 { return ns.substring(from: heading) }
        if let p = LinePrefix.parse(text) { return ns.substring(from: p.length) }
        return text
    }

    /// Replace each line's text, then select the rewritten lines (or keep a lone caret on its line).
    private func rewriteLines(_ lines: [ScannedLine], _ transform: (ScannedLine) -> String) {
        let selection = selectedRange()
        var caret = selection.location
        var start = lines[0].range.location
        var end = lines[lines.count - 1].range.location + lines[lines.count - 1].range.length
        grouped {
            for line in lines.reversed() {
                let text = transform(line)
                guard text != line.text, replace(line.range, with: text) else { continue }
                let change = (text as NSString).length - line.range.length
                end += change
                if caret > line.range.location + line.range.length { caret += change }
                else if caret > line.range.location { caret = min(max(line.range.location, caret + change), line.range.location + (text as NSString).length) }
                else if caret == line.range.location, lines.count == 1 { caret = line.range.location + (text as NSString).length - (Self.strippingBlockPrefix(text) as NSString).length }
            }
        }
        start = min(start, end)
        if selection.length == 0 {
            setSelectedRange(NSRange(location: min(caret, (string as NSString).length), length: 0))
        } else {
            setSelectedRange(NSRange(location: start, length: end - start))
        }
    }

    // MARK: Lists, tasks and quotes

    @objc func toggleBulletList(_ sender: Any?) { setPrefix(.bullet("-")) }
    @objc func toggleNumberedList(_ sender: Any?) { setPrefix(.numbered(1, ".")) }
    @objc func toggleTask(_ sender: Any?) { setPrefix(.task(bullet: "-", status: .notStarted)) }
    @objc func toggleQuote(_ sender: Any?) { setPrefix(.quote) }

    private static func sameKind(_ a: LinePrefix.Kind, _ b: LinePrefix.Kind) -> Bool {
        switch (a, b) {
        case (.bullet, .bullet), (.numbered, .numbered), (.task, .task), (.quote, .quote): return true
        default: return false
        }
    }

    /// Give the selected lines this prefix; when every one already has it, take it off.
    /// Blank lines inside a multi-line selection are left alone.
    func setPrefix(_ kind: LinePrefix.Kind) {
        var lines = selectedLines.filter { !isCode($0) }
        if lines.count > 1 { lines = lines.filter { if case .blank = $0.kind { return false }; return true } }
        guard !lines.isEmpty else { return }
        let allHave = lines.allSatisfy { line in
            guard let p = LinePrefix.parse(line.text) else { return false }
            return Self.sameKind(p.kind, kind)
        }
        // Lines are rewritten bottom-up, so numbers come from position, not visit order.
        let position = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1.index, $0 + 1) })
        rewriteLines(lines) { line in
            let existing = LinePrefix.parse(line.text)
            let rest = Self.strippingBlockPrefix(line.text)
            if allHave { return (existing?.indent ?? "") + rest }
            let indent: String = { if case .quote = kind { return "" }; return existing?.indent ?? "" }()
            var marker = kind
            switch kind {
            case .numbered(_, let d): marker = .numbered(position[line.index] ?? 1, d)
            case .bullet, .task:
                // Keep the bullet character a line already used.
                if let existing, case .bullet(let b) = existing.kind, case .task(_, let s) = kind { marker = .task(bullet: b, status: s) }
                if let existing, case .task(let b, _) = existing.kind, case .bullet = kind { marker = .bullet(b) }
            default: break
            }
            return indent + LinePrefix.marker(marker) + rest
        }
    }

    /// Tick the selected tasks (done ↔ not started); a line that is not a task becomes one.
    @objc func toggleTaskDone(_ sender: Any?) {
        let lines = selectedLines.filter { !isCode($0) }
        guard !lines.isEmpty else { return }
        let tasks = lines.filter { if case .task = $0.kind { return true }; return false }
        if tasks.isEmpty { setPrefix(.task(bullet: "-", status: .notStarted)); return }
        rewriteLines(tasks) { line in
            guard let parsed = TaskLineParser.parse(line.text),
                  let replaced = TaskLineParser.replacingStatus(in: line.text, with: parsed.status.toggled) else { return line.text }
            return replaced
        }
    }

    // MARK: Blocks

    /// Fence the selected lines as a code block; inside a fenced block, the fences go.
    @objc func toggleCodeBlock(_ sender: Any?) {
        let lines = selectedLines
        guard let first = lines.first, let last = lines.last else { return }
        let map = styler.blockMap
        // Inside a block already: remove its fences.
        if isCode(first) {
            var open = first.index, close = first.index
            while open > 0, !isFenceOpen(map.lines[open]) { open -= 1 }
            while close < map.lines.count - 1, map.lines[close].kind != .fenceClose { close += 1 }
            guard isFenceOpen(map.lines[open]), map.lines[close].kind == .fenceClose else { return }
            let openRange = NSRange(location: map.lines[open].range.location, length: map.lines[open].range.length + 1)
            let closeLine = map.lines[close]
            let closeRange = NSRange(location: max(0, closeLine.range.location - 1), length: min((string as NSString).length - max(0, closeLine.range.location - 1), closeLine.range.length + 1))
            grouped {
                replace(closeRange, with: "")
                replace(openRange, with: "")
            }
            setSelectedRange(NSRange(location: openRange.location, length: 0))
            return
        }
        let ns = string as NSString
        let start = first.range.location
        let end = last.range.location + last.range.length
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing selected: an empty block, caret inside it.
            let before = start > 0 && ns.substring(with: NSRange(location: start - 1, length: 1)) != "\n" ? "\n" : ""
            let insert = before + "```\n\n```"
            let after = end < ns.length && ns.substring(with: NSRange(location: end, length: 1)) != "\n" ? "\n" : ""
            replace(NSRange(location: start, length: end - start), with: insert + after)
            setSelectedRange(NSRange(location: start + (before as NSString).length + 4, length: 0))
            return
        }
        replace(NSRange(location: start, length: end - start), with: "```\n" + body + "\n```")
        setSelectedRange(NSRange(location: start, length: (body as NSString).length + 8))
    }

    private func isFenceOpen(_ line: ScannedLine) -> Bool {
        if case .fenceOpen = line.kind { return true }
        return false
    }

    @objc func insertHorizontalRule(_ sender: Any?) {
        insertMarkdown("---", ownLine: true)
    }
}
