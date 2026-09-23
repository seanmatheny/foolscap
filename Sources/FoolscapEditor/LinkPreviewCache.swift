import AppKit
import LinkPresentation
import CryptoKit

/// Fetches and caches LinkPresentation metadata on disk, with a concurrency
/// cap and a backoff for URLs that fail.
@MainActor
public final class LinkPreviewCache {
    public static let shared = LinkPreviewCache()

    private let directory: URL
    private var inFlight: [String: [(LPLinkMetadata?) -> Void]] = [:]
    private var queue: [(URL, (LPLinkMetadata?) -> Void)] = []
    private var active = 0
    private let maxConcurrent = 2
    private var memory: [String: LPLinkMetadata] = [:]

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Foolscap/LinkPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ url: URL) -> URL { directory.appendingPathComponent(key(url) + ".plist") }
    private func failureFile(_ url: URL) -> URL { directory.appendingPathComponent(key(url) + ".failed") }

    /// Cached metadata if present on disk.
    public func cached(_ url: URL) -> LPLinkMetadata? {
        let k = key(url)
        if let m = memory[k] { return m }
        guard let data = try? Data(contentsOf: file(url)),
              let m = try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: data) else { return nil }
        memory[k] = m
        return m
    }

    /// Calls back on the main actor with metadata, or nil if it cannot be fetched.
    public func metadata(for url: URL, completion: @escaping (LPLinkMetadata?) -> Void) {
        if let m = cached(url) { completion(m); return }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: failureFile(url).path),
           let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 6 * 3600 {
            completion(nil); return
        }
        let k = key(url)
        if inFlight[k] != nil { inFlight[k]?.append(completion); return }
        inFlight[k] = [completion]
        queue.append((url, { _ in }))
        pump()
    }

    private func pump() {
        while active < maxConcurrent, !queue.isEmpty {
            let (url, _) = queue.removeFirst()
            active += 1
            let provider = LPMetadataProvider()
            provider.timeout = 10
            provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
                // LPLinkMetadata is not Sendable; it is handed over once and never touched again here.
                nonisolated(unsafe) let handoff = metadata
                Task { @MainActor in self?.finished(url: url, metadata: handoff) }
            }
        }
    }

    private func finished(url: URL, metadata: LPLinkMetadata?) {
        active -= 1
        let k = key(url)
        if let metadata {
            memory[k] = metadata
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: metadata, requiringSecureCoding: true) {
                try? data.write(to: file(url), options: .atomic)
            }
            try? FileManager.default.removeItem(at: failureFile(url))
        } else {
            try? Data().write(to: failureFile(url))
        }
        let waiting = inFlight.removeValue(forKey: k) ?? []
        waiting.forEach { $0(metadata) }
        pump()
    }
}
