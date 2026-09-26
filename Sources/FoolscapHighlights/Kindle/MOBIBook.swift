import Foundation

/// A MOBI/AZW book as the Kindle app stores sideloaded documents: PalmDOC
/// records holding the book's HTML. A highlight's positions are byte offsets
/// into that decompressed HTML, end inclusive. Unencrypted PalmDOC (or
/// uncompressed) only; HUFF/CDIC and DRM are refused.
public struct MOBIBook: Sendable {
    enum Encoding { case utf8, cp1252 }

    /// The declared length of the text stream (the app's max position).
    public let textLength: Int
    let raw: [UInt8]
    let encoding: Encoding
    private let file: [UInt8]
    private let offsets: [Int]
    private let firstImageRecord: Int?
    private let coverOffset: Int?

    static let compressionNone = 1, compressionPalmDOC = 2, compressionHUFF = 17480

    public init(contentsOf url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ExtractionFailure.unreadable(error.localizedDescription) }
        try self.init(bytes: [UInt8](data))
    }

    public init(bytes file: [UInt8]) throws {
        guard file.count >= 78, Array(file[60..<68]) == Array("BOOKMOBI".utf8) else { throw ExtractionFailure.unreadable("not a MOBI file") }
        let numRecords = Int(be16(file, 76))
        guard file.count >= 78 + 8 * numRecords else { throw ExtractionFailure.unreadable("truncated MOBI record list") }
        var offsets = (0..<numRecords).map { Int(be32(file, 78 + 8 * $0)) }
        offsets.append(file.count)
        guard numRecords >= 1, offsets[0] <= offsets[1], offsets[1] <= file.count else { throw ExtractionFailure.unreadable("bad MOBI record 0") }
        let rec0 = Array(file[offsets[0]..<offsets[1]])
        guard rec0.count >= 16 else { throw ExtractionFailure.unreadable("short MOBI record 0") }
        let compression = Int(be16(rec0, 0))
        let textLength = Int(be32(rec0, 4))
        let recordCount = Int(be16(rec0, 8))
        let encryption = Int(be16(rec0, 12))
        if encryption != 0 { throw ExtractionFailure.encrypted }
        if compression == Self.compressionHUFF { throw ExtractionFailure.huffCompression }
        guard compression == Self.compressionNone || compression == Self.compressionPalmDOC else {
            throw ExtractionFailure.unreadable("unknown MOBI compression \(compression)")
        }
        guard rec0.count >= 32, Array(rec0[16..<20]) == Array("MOBI".utf8) else { throw ExtractionFailure.unreadable("missing MOBI header") }
        let headerLength = Int(be32(rec0, 20))
        let encodingCode = be32(rec0, 28)
        switch encodingCode {
        case 65001: encoding = .utf8
        case 1252: encoding = .cp1252
        default: throw ExtractionFailure.unreadable("unknown MOBI text encoding \(encodingCode)")
        }
        let extraFlags = headerLength >= 0xE4 && rec0.count >= 0xF4 ? Int(be16(rec0, 0xF2)) : 0

        var raw: [UInt8] = []
        raw.reserveCapacity(textLength)
        let last = min(recordCount, numRecords - 1)
        if last >= 1 {
            for i in 1...last {
                guard offsets[i] <= offsets[i + 1], offsets[i + 1] <= file.count else { throw ExtractionFailure.unreadable("bad MOBI record \(i)") }
                let record = Self.trimTrailing(Array(file[offsets[i]..<offsets[i + 1]]), extraFlags: extraFlags)
                raw += compression == Self.compressionPalmDOC ? Self.palmDocDecompress(record) : record
            }
        }
        guard raw.count >= textLength else { throw ExtractionFailure.unreadable("decompressed \(raw.count) bytes, expected \(textLength)") }
        raw.removeSubrange(textLength...)
        self.raw = raw
        self.textLength = textLength
        self.file = file
        self.offsets = offsets

        firstImageRecord = rec0.count >= 0x70 ? Int(be32(rec0, 0x6C)) : nil
        var coverOffset: Int?
        let exthFlags = rec0.count >= 0x84 ? be32(rec0, 0x80) : 0
        if exthFlags & 0x40 != 0 {
            let exth = 16 + headerLength
            if exth + 12 <= rec0.count, Array(rec0[exth..<exth + 4]) == Array("EXTH".utf8) {
                let count = Int(be32(rec0, exth + 8))
                var p = exth + 12
                for _ in 0..<count {
                    guard p + 8 <= rec0.count else { break }
                    let type = Int(be32(rec0, p)), length = Int(be32(rec0, p + 4))
                    guard length >= 8, p + length <= rec0.count else { break }
                    if type == 201, length >= 12 { coverOffset = Int(be32(rec0, p + 8)) }
                    p += length
                }
            }
        }
        self.coverOffset = coverOffset
    }

    /// The text of an inclusive byte range, split into paragraphs.
    public func paragraphs(from start: Int, to end: Int) -> [String] {
        guard start <= end, start < raw.count, start >= 0 else { return [] }
        let stop = min(end + 1, raw.count)
        return Self.paragraphs(fromHTML: raw[start..<stop], encoding: encoding)
    }

    /// The cover image record (usually a JPEG), from EXTH 201.
    public func coverImage() -> Data? {
        guard let first = firstImageRecord, let cover = coverOffset else { return nil }
        let index = first + cover
        guard index >= 1, index + 1 < offsets.count, offsets[index] < offsets[index + 1] else { return nil }
        let bytes = file[offsets[index]..<offsets[index + 1]]
        guard bytes.count > 64 else { return nil }
        return Data(bytes)
    }

    // MARK: Records

    static func palmDocDecompress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 2)
        var i = 0
        let n = data.count
        while i < n {
            let c = Int(data[i]); i += 1
            if c == 0 {
                out.append(0)
            } else if c <= 8 {
                let stop = min(i + c, n)
                out += data[i..<stop]; i = stop
            } else if c <= 0x7F {
                out.append(UInt8(c))
            } else if c <= 0xBF {
                guard i < n else { break }
                let pair = (c << 8) | Int(data[i]); i += 1
                let distance = (pair >> 3) & 0x7FF
                let length = (pair & 7) + 3
                guard distance >= 1, distance <= out.count else { continue }
                for _ in 0..<length { out.append(out[out.count - distance]) }
            } else {
                out.append(32)
                out.append(UInt8(c ^ 0x80))
            }
        }
        return out
    }

    /// A backward varint at the end of `data[..<size]`; the value counts its own bytes.
    static func trailingEntrySize(_ data: [UInt8], size: Int) -> Int {
        var bitpos = 0, result = 0, size = size
        while size > 0 {
            let v = Int(data[size - 1])
            result |= (v & 0x7F) << bitpos
            bitpos += 7
            size -= 1
            if v & 0x80 != 0 || bitpos >= 28 { break }
        }
        return result
    }

    static func trimTrailing(_ data: [UInt8], extraFlags: Int) -> [UInt8] {
        var num = 0
        var flags = extraFlags >> 1
        while flags != 0 {
            if flags & 1 != 0 { num += trailingEntrySize(data, size: data.count - num) }
            flags >>= 1
        }
        if extraFlags & 1 != 0, data.count - num - 1 >= 0 {
            num += Int(data[data.count - num - 1] & 0x3) + 1
        }
        return num >= data.count ? [] : Array(data[0..<(data.count - num)])
    }

    // MARK: HTML

    /// Tags that end a paragraph; other block tags just separate words.
    static let paragraphTags: Set<String> = ["p", "div", "br", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "blockquote", "hr", "dd", "dt", "pre"]
    static let spacingTags: Set<String> = ["ul", "ol", "td", "th", "table", "dl", "mbp:pagebreak", "body", "html", "head"]

    /// Strip tags and entities; block tags break words or paragraphs.
    static func paragraphs(fromHTML html: ArraySlice<UInt8>, encoding: Encoding) -> [String] {
        var scalars = String.UnicodeScalarView()
        var i = html.startIndex
        let n = html.endIndex
        while i < n {
            let b = html[i]
            if b == 0x3C {   // <
                var tagEnd = n
                var name = ""
                if html[i..<min(i + 4, n)].elementsEqual("<!--".utf8) {
                    if let close = findSequence("-->", in: html, from: i + 4) { tagEnd = close + 3 }
                } else {
                    if let close = html[i..<n].firstIndex(of: 0x3E) { tagEnd = close + 1 }
                    var inner = html[(i + 1)..<max(i + 1, tagEnd - 1)]
                    while let f = inner.first, f == 0x2F { inner = inner.dropFirst() }
                    let nameBytes = inner.prefix { !isSpace($0) }
                    name = String(decoding: nameBytes, as: UTF8.self).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }
                if paragraphTags.contains(name) { scalars.append("\n") } else if spacingTags.contains(name) { scalars.append(" ") }
                i = tagEnd
            } else if b == 0x26 {   // &
                if let (scalar, length) = decodeEntity(html[i..<min(i + 12, n)]) {
                    appendText(scalar, to: &scalars)
                    i += length
                } else {
                    scalars.append("&"); i += 1
                }
            } else {
                switch encoding {
                case .utf8:
                    let length = utf8Length(b)
                    let stop = min(i + length, n)
                    let s = String(decoding: html[i..<stop], as: UTF8.self)
                    if s.unicodeScalars.count == 1, let scalar = s.unicodeScalars.first { appendText(scalar, to: &scalars) } else { scalars.append("\u{FFFD}") }
                    i = stop
                case .cp1252:
                    if let s = String(bytes: [b], encoding: .windowsCP1252), let scalar = s.unicodeScalars.first { appendText(scalar, to: &scalars) }
                    i += 1
                }
            }
        }
        return String(scalars).components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }

    private static func appendText(_ scalar: Unicode.Scalar, to scalars: inout String.UnicodeScalarView) {
        switch scalar {
        case "\u{00A0}": scalars.append(" ")
        case "\u{00AD}": break   // soft hyphen
        default: scalars.append(scalar)
        }
    }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C }

    private static func findSequence(_ needle: String, in html: ArraySlice<UInt8>, from start: Int) -> Int? {
        let bytes = Array(needle.utf8)
        var i = start
        while i + bytes.count <= html.endIndex {
            if html[i..<i + bytes.count].elementsEqual(bytes) { return i }
            i += 1
        }
        return nil
    }

    private static func utf8Length(_ lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead >= 0xF0 { return 4 }
        if lead >= 0xE0 { return 3 }
        if lead >= 0xC0 { return 2 }
        return 1
    }

    /// An entity at the start of `segment`: the scalar and the bytes it took.
    static func decodeEntity(_ segment: ArraySlice<UInt8>) -> (Unicode.Scalar, Int)? {
        guard segment.count >= 3, let semicolon = segment.dropFirst().firstIndex(of: 0x3B) else { return nil }
        let body = String(decoding: segment[(segment.startIndex + 1)..<semicolon], as: UTF8.self)
        let length = semicolon - segment.startIndex + 1
        let value: UInt32?
        if body.hasPrefix("#x") || body.hasPrefix("#X") { value = UInt32(body.dropFirst(2), radix: 16) }
        else if body.hasPrefix("#") { value = UInt32(body.dropFirst()) }
        else { value = namedEntities[body] }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, length)
    }

    static let namedEntities: [String: UInt32] = [
        "amp": 0x26, "lt": 0x3C, "gt": 0x3E, "quot": 0x22, "apos": 0x27, "nbsp": 0xA0, "shy": 0xAD,
        "iexcl": 0xA1, "cent": 0xA2, "pound": 0xA3, "curren": 0xA4, "yen": 0xA5, "brvbar": 0xA6, "sect": 0xA7, "uml": 0xA8,
        "copy": 0xA9, "ordf": 0xAA, "laquo": 0xAB, "not": 0xAC, "reg": 0xAE, "macr": 0xAF, "deg": 0xB0, "plusmn": 0xB1,
        "sup2": 0xB2, "sup3": 0xB3, "acute": 0xB4, "micro": 0xB5, "para": 0xB6, "middot": 0xB7, "cedil": 0xB8, "sup1": 0xB9,
        "ordm": 0xBA, "raquo": 0xBB, "frac14": 0xBC, "frac12": 0xBD, "frac34": 0xBE, "iquest": 0xBF,
        "Agrave": 0xC0, "Aacute": 0xC1, "Acirc": 0xC2, "Atilde": 0xC3, "Auml": 0xC4, "Aring": 0xC5, "AElig": 0xC6, "Ccedil": 0xC7,
        "Egrave": 0xC8, "Eacute": 0xC9, "Ecirc": 0xCA, "Euml": 0xCB, "Igrave": 0xCC, "Iacute": 0xCD, "Icirc": 0xCE, "Iuml": 0xCF,
        "ETH": 0xD0, "Ntilde": 0xD1, "Ograve": 0xD2, "Oacute": 0xD3, "Ocirc": 0xD4, "Otilde": 0xD5, "Ouml": 0xD6, "times": 0xD7,
        "Oslash": 0xD8, "Ugrave": 0xD9, "Uacute": 0xDA, "Ucirc": 0xDB, "Uuml": 0xDC, "Yacute": 0xDD, "THORN": 0xDE, "szlig": 0xDF,
        "agrave": 0xE0, "aacute": 0xE1, "acirc": 0xE2, "atilde": 0xE3, "auml": 0xE4, "aring": 0xE5, "aelig": 0xE6, "ccedil": 0xE7,
        "egrave": 0xE8, "eacute": 0xE9, "ecirc": 0xEA, "euml": 0xEB, "igrave": 0xEC, "iacute": 0xED, "icirc": 0xEE, "iuml": 0xEF,
        "eth": 0xF0, "ntilde": 0xF1, "ograve": 0xF2, "oacute": 0xF3, "ocirc": 0xF4, "otilde": 0xF5, "ouml": 0xF6, "divide": 0xF7,
        "oslash": 0xF8, "ugrave": 0xF9, "uacute": 0xFA, "ucirc": 0xFB, "uuml": 0xFC, "yacute": 0xFD, "thorn": 0xFE, "yuml": 0xFF,
        "OElig": 0x152, "oelig": 0x153, "Scaron": 0x160, "scaron": 0x161, "Yuml": 0x178, "fnof": 0x192, "circ": 0x2C6, "tilde": 0x2DC,
        "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009, "zwnj": 0x200C, "zwj": 0x200D, "lrm": 0x200E, "rlm": 0x200F,
        "ndash": 0x2013, "mdash": 0x2014, "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D,
        "bdquo": 0x201E, "dagger": 0x2020, "Dagger": 0x2021, "bull": 0x2022, "hellip": 0x2026, "permil": 0x2030, "prime": 0x2032,
        "Prime": 0x2033, "lsaquo": 0x2039, "rsaquo": 0x203A, "oline": 0x203E, "euro": 0x20AC, "trade": 0x2122, "larr": 0x2190,
        "uarr": 0x2191, "rarr": 0x2192, "darr": 0x2193, "harr": 0x2194, "minus": 0x2212, "infin": 0x221E, "ne": 0x2260, "le": 0x2264, "ge": 0x2265,
    ]
}

@inline(__always) func be16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    guard offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

@inline(__always) func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    guard offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}
