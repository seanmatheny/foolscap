import Foundation

/// Just enough of ustar to unpack Amazon's page-image archives.
public enum TarReader {
    public struct Member: Equatable, Sendable {
        public var name: String
        public var data: Data
    }

    public enum ReadError: Error, Equatable { case notATar, truncated, gzipped }

    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Regular-file members in archive order. Other entry types (PAX headers,
    /// GNU long names, directories) are skipped along with their data.
    public static func members(in data: Data) throws -> [Member] {
        if isGzip(data) { throw ReadError.gzipped }
        let bytes = [UInt8](data)
        var offset = 0
        var out: [Member] = []
        var sawHeader = false
        while offset + 512 <= bytes.count {
            let header = bytes[offset..<offset + 512]
            if header.allSatisfy({ $0 == 0 }) { break }
            guard isValidHeader(header) else { throw ReadError.notATar }
            sawHeader = true
            let size = octal(header, at: 124, length: 12)
            let typeflag = header[offset + 156]
            let name = string(header, at: 0, length: 100)
            let prefix = string(header, at: 345, length: 155)
            let fullName = prefix.isEmpty ? name : prefix + "/" + name
            let start = offset + 512
            let end = start + size
            guard end <= bytes.count else { throw ReadError.truncated }
            if typeflag == 0 || typeflag == UInt8(ascii: "0") {
                out.append(Member(name: fullName, data: Data(bytes[start..<end])))
            }
            offset = start + (size + 511) / 512 * 512
        }
        guard sawHeader else { throw ReadError.notATar }
        return out
    }

    private static func isValidHeader(_ header: ArraySlice<UInt8>) -> Bool {
        let base = header.startIndex
        let magic = Array(header[(base + 257)..<(base + 262)])
        guard magic == Array("ustar".utf8) else { return false }
        // The checksum field is summed as if it held spaces.
        var sum = 0
        for (i, b) in header.enumerated() { sum += (148..<156).contains(i) ? 32 : Int(b) }
        return octal(header, at: 148, length: 8) == sum
    }

    private static func octal(_ header: ArraySlice<UInt8>, at field: Int, length: Int) -> Int {
        var value = 0
        for b in header[(header.startIndex + field)..<(header.startIndex + field + length)] {
            if b == 0 || b == 32 { if value > 0 { break } else { continue } }
            guard (48...55).contains(b) else { break }
            value = value * 8 + Int(b - 48)
        }
        return value
    }

    private static func string(_ header: ArraySlice<UInt8>, at field: Int, length: Int) -> String {
        let slice = header[(header.startIndex + field)..<(header.startIndex + field + length)]
        return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
    }
}
