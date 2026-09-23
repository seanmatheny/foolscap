import AppKit

/// Tiny regex highlighter for fenced code: comments, strings, numbers, keywords.
/// No external grammar files; good enough for scraps of code in a notebook.
struct CodeHighlighter {
    enum Token { case keyword, string, comment, number, type }

    struct Language {
        let keywords: Set<String>
        let lineComment: String?
        let blockComment: (String, String)?
        let typesCapitalised: Bool
    }

    static let languages: [String: Language] = {
        let c = Language(keywords: ["if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default",
                                    "struct", "enum", "typedef", "const", "static", "void", "int", "char", "float", "double", "long",
                                    "unsigned", "sizeof", "include", "define"], lineComment: "//", blockComment: ("/*", "*/"), typesCapitalised: true)
        let swift = Language(keywords: ["let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "if", "else",
                                        "guard", "return", "for", "in", "while", "switch", "case", "default", "break", "continue", "throw",
                                        "throws", "try", "catch", "async", "await", "actor", "static", "public", "private", "internal",
                                        "fileprivate", "open", "override", "init", "deinit", "self", "Self", "super", "nil", "true", "false",
                                        "some", "any", "where", "typealias", "associatedtype", "defer", "do", "repeat", "inout", "mutating",
                                        "final", "lazy", "weak", "unowned", "is", "as"], lineComment: "//", blockComment: ("/*", "*/"), typesCapitalised: true)
        let python = Language(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "import",
                                         "from", "as", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass", "break",
                                         "continue", "None", "True", "False", "is", "global", "nonlocal", "async", "await", "del", "assert"],
                              lineComment: "#", blockComment: nil, typesCapitalised: true)
        let js = Language(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
                                     "default", "break", "continue", "new", "class", "extends", "import", "export", "from", "async", "await",
                                     "try", "catch", "finally", "throw", "this", "null", "undefined", "true", "false", "typeof", "instanceof",
                                     "of", "in", "interface", "type", "enum", "implements", "readonly", "public", "private", "static"],
                          lineComment: "//", blockComment: ("/*", "*/"), typesCapitalised: true)
        let shell = Language(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function",
                                        "return", "export", "local", "echo", "exit", "set", "sudo", "cd", "ls", "grep", "awk", "sed", "cat",
                                        "make", "git", "ssh", "curl"], lineComment: "#", blockComment: nil, typesCapitalised: false)
        let sql = Language(keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table",
                                      "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "limit",
                                      "and", "or", "not", "null", "as", "distinct", "having", "union", "primary", "key", "index",
                                      "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
                                      "DROP", "ALTER", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY", "ORDER", "LIMIT",
                                      "AND", "OR", "NOT", "NULL", "AS", "DISTINCT", "HAVING", "UNION", "PRIMARY", "KEY", "INDEX"],
                           lineComment: "--", blockComment: ("/*", "*/"), typesCapitalised: false)
        let go = Language(keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go",
                                     "defer", "return", "if", "else", "for", "range", "switch", "case", "default", "break", "continue",
                                     "select", "nil", "true", "false", "make", "new", "len", "error", "string", "int", "bool"],
                          lineComment: "//", blockComment: ("/*", "*/"), typesCapitalised: true)
        let rust = Language(keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "for", "in", "while", "loop", "if",
                                       "else", "match", "return", "use", "mod", "crate", "self", "Self", "super", "as", "ref", "move",
                                       "async", "await", "dyn", "where", "unsafe", "const", "static", "type", "true", "false", "Some",
                                       "None", "Ok", "Err"], lineComment: "//", blockComment: ("/*", "*/"), typesCapitalised: true)
        let yaml = Language(keywords: ["true", "false", "null", "yes", "no"], lineComment: "#", blockComment: nil, typesCapitalised: false)
        let json = Language(keywords: ["true", "false", "null"], lineComment: nil, blockComment: nil, typesCapitalised: false)
        return ["c": c, "cpp": c, "h": c, "swift": swift, "python": python, "py": python, "js": js, "javascript": js, "ts": js,
                "typescript": js, "sh": shell, "bash": shell, "zsh": shell, "shell": shell, "sql": sql, "go": go, "rust": rust,
                "rs": rust, "yaml": yaml, "yml": yaml, "json": json, "ruby": python, "rb": python, "toml": yaml, "ini": yaml]
    }()

    private static let stringRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"(?<![\w.])(0x[0-9A-Fa-f]+|\d+(?:\.\d+)?(?:e[+-]?\d+)?)(?![\w.])"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)

    /// Tokens for one line of code. `inBlockComment` carries state across lines.
    static func tokens(in line: String, language name: String, inBlockComment: inout Bool) -> [(Token, NSRange)] {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let lang = languages[name.lowercased()] else { return [] }
        var out: [(Token, NSRange)] = []
        var claimed: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !claimed.contains { NSIntersectionRange($0, r).length > 0 } }

        var searchFrom = 0
        if inBlockComment, let (_, close) = lang.blockComment {
            let r = ns.range(of: close)
            if r.location == NSNotFound { out.append((.comment, full)); return out }
            let end = r.location + r.length
            out.append((.comment, NSRange(location: 0, length: end))); claimed.append(NSRange(location: 0, length: end))
            inBlockComment = false; searchFrom = end
        }
        if let (open, close) = lang.blockComment {
            var from = searchFrom
            while from < ns.length {
                let r = ns.range(of: open, range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { break }
                let closeR = ns.range(of: close, range: NSRange(location: r.location + r.length, length: ns.length - r.location - r.length))
                if closeR.location == NSNotFound {
                    let cr = NSRange(location: r.location, length: ns.length - r.location)
                    out.append((.comment, cr)); claimed.append(cr); inBlockComment = true; break
                }
                let cr = NSRange(location: r.location, length: closeR.location + closeR.length - r.location)
                out.append((.comment, cr)); claimed.append(cr); from = cr.location + cr.length
            }
        }
        if let lc = lang.lineComment {
            for m in stringRegex.matches(in: line, range: full) where free(m.range) { claimed.append(m.range); out.append((.string, m.range)) }
            let r = ns.range(of: lc)
            if r.location != NSNotFound, free(NSRange(location: r.location, length: 1)) {
                // Only a comment if not inside a string.
                let cr = NSRange(location: r.location, length: ns.length - r.location)
                out.removeAll { $0.1.location > r.location }
                claimed.removeAll { $0.location > r.location }
                out.append((.comment, cr)); claimed.append(cr)
            }
        } else {
            for m in stringRegex.matches(in: line, range: full) where free(m.range) { claimed.append(m.range); out.append((.string, m.range)) }
        }
        for m in numberRegex.matches(in: line, range: full) where free(m.range) { claimed.append(m.range); out.append((.number, m.range)) }
        for m in wordRegex.matches(in: line, range: full) where free(m.range) {
            let w = ns.substring(with: m.range)
            if lang.keywords.contains(w) { out.append((.keyword, m.range)) }
            else if lang.typesCapitalised, w.first!.isUppercase, w.count > 1, w.dropFirst().contains(where: { $0.isLowercase }) { out.append((.type, m.range)) }
        }
        return out
    }
}
