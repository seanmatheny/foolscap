import Foundation
import CryptoKit

/// Coordinated, atomic file access. iCloud Drive replaces files underneath us,
/// so every read and write goes through NSFileCoordinator.
public enum FileIO {
    public static func read(_ url: URL) throws -> Data {
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    public static func write(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var result: Result<Void, Error> = .success(())
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            result = Result {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: u, options: .atomic)
            }
        }
        if let coordError { throw coordError }
        try result.get()
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public struct Stat: Equatable, Sendable {
        public var mtime: Double
        public var size: Int
    }

    public static func stat(_ url: URL) -> Stat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let m = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (attrs[.size] as? NSNumber)?.intValue ?? 0
        return Stat(mtime: m, size: s)
    }
}
