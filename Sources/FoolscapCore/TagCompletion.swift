import Foundation

/// Finds the `#tag` being typed at a caret and matches it against known tags,
/// for the live lookups in the editor, the task popovers and the quick-task panel.
public enum TagCompletion {
    public struct Partial: Equatable, Sendable {
        /// UTF-16 range from the `#` up to the caret.
        public var range: NSRange
        /// The text after the `#`, lowercased; may be empty right after the `#`.
        public var text: String
    }

    private static let tagCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_-/")
        return set
    }()

    /// The `#word` that ends at `caret` (UTF-16 offset; nil means the end of
    /// the text), or nil when the caret is not inside a tag being typed. A `#`
    /// counts only where the tag regex would accept one: at the start or after
    /// whitespace or punctuation, never glued to a word, a slash, another `#`,
    /// a backtick or a backslash.
    public static func partial(in text: String, caret: Int? = nil) -> Partial? {
        let ns = text as NSString
        let end = min(caret ?? ns.length, ns.length)
        var i = end
        while i > 0 {
            let ch = ns.character(at: i - 1)
            if let scalar = Unicode.Scalar(ch), tagCharacters.contains(scalar) { i -= 1; continue }
            break
        }
        guard i > 0, ns.character(at: i - 1) == 0x23 /* # */ else { return nil }
        let hash = i - 1
        if hash > 0 {
            let before = ns.character(at: hash - 1)
            if let scalar = Unicode.Scalar(before) {
                if tagCharacters.contains(scalar) { return nil }
                if "#`\\".unicodeScalars.contains(scalar) { return nil }
            }
        }
        let partial = ns.substring(with: NSRange(location: i, length: end - i)).lowercased()
        // The tag regex needs a letter, digit or underscore first.
        if let first = partial.unicodeScalars.first, !(CharacterSet.alphanumerics.contains(first) || first == "_") { return nil }
        return Partial(range: NSRange(location: hash, length: end - hash), text: partial)
    }

    /// Known tags starting with the partial text, in the order given (most used
    /// first), excluding an exact match that is already complete.
    public static func matches(for partial: String, in tags: [String], limit: Int = 8) -> [String] {
        let p = partial.lowercased()
        var seen = Set<String>()
        return tags.filter { tag in
            guard seen.insert(tag).inserted else { return false }
            return p.isEmpty || (tag.hasPrefix(p) && tag != p)
        }.prefix(limit).map { $0 }
    }

    /// `text` with the partial at `caret` replaced by `#tag` and a space.
    public static func completing(_ text: String, partial: Partial, with tag: String) -> String {
        let ns = text as NSString
        return ns.replacingCharacters(in: partial.range, with: "#" + tag + " ")
    }
}
