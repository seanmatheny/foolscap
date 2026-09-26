import Foundation

/// Keeps machine-written text literal inside a note: a stray "#word" would
/// otherwise become a tag, a leading "- [ ]" a task. Shared by the Scribe
/// transcripts and the Kindle highlight files.
public enum MarkdownEscaping {
    /// The full escape for text that must not carry any markdown at all
    /// (OCR noise is full of stray symbols).
    public static func escape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"([\\`*_\[\]<#])"#, with: #"\\$1"#, options: .regularExpression)
        out = out.replacingOccurrences(of: "~~", with: #"\~\~"#).replacingOccurrences(of: "==", with: #"\=\="#)
        if out.range(of: #"^\s*(>|[-=_]{3,}\s*$)"#, options: .regularExpression) != nil { out = "\\" + out }
        return out
    }

    /// The inverse of `escape` (and of the lighter escapes built on it): every
    /// escape is a backslash before one character.
    public static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
    }
}

public enum FileNames {
    /// Sanitize a title for use as a file or folder name.
    public static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: #"[\\/:*?"<>|]"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}
