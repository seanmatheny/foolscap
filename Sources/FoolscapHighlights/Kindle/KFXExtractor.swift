import Foundation
import CryptoKit

/// KFX books are Amazon Ion containers; the only maintained parser is
/// kfxlib, shipped as Calibre's "KFX Input" plugin. It runs out of process
/// under `calibre-debug` once per book and its (pid, text) chunks are cached,
/// so the Kindle's positions can be turned into text natively afterwards.
public struct KFXExtractor: Sendable {
    public var calibreDebug = URL(fileURLWithPath: "/Applications/calibre.app/Contents/MacOS/calibre-debug")
    public var pluginZip = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/calibre/plugins/KFX Input.zip")
    public var cacheDirectory: URL
    /// clippyconvert's cache uses the same keys: books it already decoded need no Calibre pass.
    public var legacyChunksDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/clippyconvert/chunks", isDirectory: true)
    public var helperScript: URL? = HighlightsResources.bundle.url(forResource: "kfx_extract", withExtension: "py")
    /// A first pass over dozens of books takes minutes.
    public var timeout: TimeInterval = 900

    public init(cacheDirectory: URL = HighlightsPaths.kfxCacheDirectory) {
        self.cacheDirectory = cacheDirectory
    }

    public enum Availability: Equatable, Sendable {
        case ready, calibreMissing, pluginMissing, helperMissing

        public var message: String {
            switch self {
            case .ready: return "Calibre with the KFX Input plugin found"
            case .calibreMissing: return "Install Calibre (calibre-ebook.com) with its KFX Input plugin to read KFX books"
            case .pluginMissing: return "Install Calibre's KFX Input plugin (Preferences ▸ Plugins ▸ Get new plugins) to read KFX books"
            case .helperMissing: return "The KFX helper script is missing from the app bundle"
            }
        }
    }

    public var availability: Availability {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: calibreDebug.path) { return .calibreMissing }
        if !fm.fileExists(atPath: pluginZip.path) { return .pluginMissing }
        if helperScript.map({ fm.fileExists(atPath: $0.path) }) != true { return .helperMissing }
        return .ready
    }

    // MARK: Cache

    /// The largest file in the book's directory starting with the `CONT` magic.
    public static func container(in bookDirectory: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: bookDirectory.path) else { return nil }
        var best: (URL, Int)?
        for name in names {
            let url = bookDirectory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: url), let magic = try? handle.read(upToCount: 4) else { continue }
            try? handle.close()
            guard magic == Data("CONT".utf8),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue else { continue }
            if best == nil || size > best!.1 { best = (url, size) }
        }
        return best?.0
    }

    /// sha1("path|size|mtime") as clippyconvert computes it, so a re-downloaded book re-extracts.
    public static func cacheKey(for container: URL) -> String? {
        // FileManager, not URL resource values: NSURL caches those per instance.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: container.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, let mtime = attributes[.modificationDate] as? Date else { return nil }
        let key = "\(container.path)|\(size)|\(Int(mtime.timeIntervalSince1970))"
        return Insecure.SHA1.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func chunksURL(key: String) -> URL { cacheDirectory.appendingPathComponent("chunks/\(key).json") }
    func coverURL(key: String) -> URL { cacheDirectory.appendingPathComponent("covers/\(key).jpg") }

    /// Where a book's chunks are, if any pass has decoded it.
    func cachedChunks(for container: URL) -> URL? {
        guard let key = Self.cacheKey(for: container) else { return nil }
        let own = chunksURL(key: key)
        if FileManager.default.fileExists(atPath: own.path) { return own }
        if let legacy = legacyChunksDirectory?.appendingPathComponent(key + ".json"), FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        return nil
    }

    public func isDecoded(_ bookDirectory: URL) -> Bool {
        Self.container(in: bookDirectory).flatMap(cachedChunks(for:)) != nil
    }

    // MARK: Decoding

    /// Decode every book not yet in the cache in one Calibre run (its start-up
    /// costs seconds, so the batch amortises it). Books that fail come back
    /// with the helper's reason; the rest are then loadable.
    public func prewarm(_ bookDirectories: [URL], wantsCovers: Bool = true, progress: @Sendable @escaping (String) -> Void) async throws -> [URL: ExtractionFailure] {
        var failures: [URL: ExtractionFailure] = [:]
        var jobs: [[String]] = []
        var byDirectory: [String: URL] = [:]
        for dir in bookDirectories {
            guard let container = Self.container(in: dir), let key = Self.cacheKey(for: container) else {
                failures[dir] = .kfxFailed("no KFX container in \(dir.lastPathComponent)"); continue
            }
            let needsChunks = cachedChunks(for: container) == nil
            let needsCover = wantsCovers && !FileManager.default.fileExists(atPath: coverURL(key: key).path)
            guard needsChunks || needsCover else { continue }
            jobs.append([dir.path, chunksURL(key: key).path, coverURL(key: key).path])
            byDirectory[dir.path] = dir
        }
        guard !jobs.isEmpty else { return failures }
        let availability = self.availability
        guard availability == .ready, let helper = helperScript else { throw ExtractionFailure.kfxUnavailable(availability.message) }
        progress("Decoding \(jobs.count) KFX book\(jobs.count == 1 ? "" : "s") with Calibre…")
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory.appendingPathComponent("chunks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDirectory.appendingPathComponent("covers"), withIntermediateDirectories: true)
        let plugin = try ensurePlugin()
        let jobsFile = cacheDirectory.appendingPathComponent("jobs.json")
        try JSONSerialization.data(withJSONObject: jobs).write(to: jobsFile, options: .atomic)
        let output = try await run(helper: helper, plugin: plugin, jobsFile: jobsFile)
        var reported = Set<String>()
        for line in output.split(separator: "\n") {
            if line.hasPrefix("OK ") {
                reported.insert(String(line.dropFirst(3)))
            } else if line.hasPrefix("ERR ") {
                let rest = line.dropFirst(4)
                let reason = rest.prefix { $0 != " " }
                let dir = String(rest.dropFirst(reason.count + 1))
                reported.insert(dir)
                if let url = byDirectory[dir] { failures[url] = .kfxFailed(String(reason)) }
            }
        }
        for job in jobs where !reported.contains(job[0]) {
            if let url = byDirectory[job[0]], !fm.fileExists(atPath: job[1]) { failures[url] = .kfxFailed("Calibre produced no output") }
        }
        return failures
    }

    public func load(_ bookDirectory: URL) throws -> KFXText {
        guard let container = Self.container(in: bookDirectory) else { throw ExtractionFailure.kfxFailed("no KFX container in \(bookDirectory.lastPathComponent)") }
        guard let url = cachedChunks(for: container) else {
            let availability = self.availability
            throw availability == .ready ? ExtractionFailure.kfxFailed("not decoded (DRM or unsupported)") : ExtractionFailure.kfxUnavailable(availability.message)
        }
        do {
            return try KFXText(chunksJSON: Data(contentsOf: url))
        } catch {
            throw ExtractionFailure.kfxFailed("bad chunk cache: \(error.localizedDescription)")
        }
    }

    public func cover(for bookDirectory: URL) -> Data? {
        guard let container = Self.container(in: bookDirectory), let key = Self.cacheKey(for: container) else { return nil }
        return try? Data(contentsOf: coverURL(key: key))
    }

    // MARK: Calibre

    /// The plugin zip unpacked into the cache, once per plugin version.
    func ensurePlugin() throws -> URL {
        let fm = FileManager.default
        let dir = cacheDirectory.appendingPathComponent("kfx-input", isDirectory: true)
        let stamp = dir.appendingPathComponent(".zip-mtime")
        let mtime = (try? pluginZip.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        if let existing = try? String(contentsOf: stamp, encoding: .utf8), existing == mtime,
           fm.fileExists(atPath: dir.appendingPathComponent("kfxlib").path) {
            return dir
        }
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", pluginZip.path, dir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0, fm.fileExists(atPath: dir.appendingPathComponent("kfxlib").path) else {
            throw ExtractionFailure.kfxFailed("could not unpack the KFX Input plugin")
        }
        try mtime.write(to: stamp, atomically: true, encoding: .utf8)
        return dir
    }

    private func run(helper: URL, plugin: URL, jobsFile: URL) async throws -> String {
        let calibre = calibreDebug, timeout = self.timeout
        let handle = ProcessHandle()
        // The helper runs on a detached thread, which cancellation does not reach:
        // cancelling the import terminates the process instead.
        let (output, errorText, status, killed) = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Self.runProcess(calibre: calibre, helper: helper, plugin: plugin, jobsFile: jobsFile, timeout: timeout, handle: handle)
            }.value
        } onCancel: {
            handle.cancel()
        }
        if killed { throw ExtractionFailure.kfxFailed("Calibre took longer than \(Int(timeout / 60)) minutes") }
        if status != 0, !output.contains("OK ") {
            let tail = errorText.split(separator: "\n").suffix(3).joined(separator: " ")
            throw ExtractionFailure.kfxFailed("calibre-debug exited with \(status): \(tail)")
        }
        return output
    }

    /// Synchronous: runs on a background thread, blocking until Calibre exits.
    private static func runProcess(calibre: URL, helper: URL, plugin: URL, jobsFile: URL, timeout: TimeInterval,
                                   handle: ProcessHandle) throws -> (String, String, Int32, Bool) {
        let process = Process()
        process.executableURL = calibre
        process.arguments = ["-e", helper.path]
        var environment = ProcessInfo.processInfo.environment
        environment["KFX_PLUGIN"] = plugin.path
        environment["KFX_JOBS"] = jobsFile.path
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try handle.launch(process)
        // Drain both pipes on other threads: the helper blocks once a pipe buffer fills.
        let group = DispatchGroup()
        nonisolated(unsafe) var out = Data()
        nonisolated(unsafe) var err = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        nonisolated(unsafe) var killed = false
        nonisolated(unsafe) let running = process
        let watchdog = DispatchWorkItem { if running.isRunning { killed = true; running.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()
        if handle.isCancelled { throw CancellationError() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), process.terminationStatus, killed)
    }

    /// The helper process, shared with the cancellation handler.
    private final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        func launch(_ process: Process) throws {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                try process.run()
                self.process = process
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if let process, process.isRunning { process.terminate() }
            }
        }
    }
}

/// A decoded KFX book: every text scalar with its pid, in reading order.
/// Each chunk kfxlib reports is one paragraph, so chunk ends are paragraph ends.
public struct KFXText: Sendable {
    public let maxPosition: Int
    let pids: [Int32]
    let scalars: [Unicode.Scalar]
    /// Indices of the last scalar of each chunk.
    let chunkEnds: Set<Int>

    public init(maxPosition: Int, chunks: [(pid: Int, text: String)]) {
        self.maxPosition = maxPosition
        var pids: [Int32] = [], scalars: [Unicode.Scalar] = []
        var ends = Set<Int>()
        for chunk in chunks.sorted(by: { $0.pid < $1.pid }) {
            var pid = Int32(clamping: chunk.pid)
            // Python counts code points, so one pid per Unicode scalar.
            for scalar in chunk.text.unicodeScalars {
                pids.append(pid); scalars.append(scalar); pid += 1
            }
            if !scalars.isEmpty { ends.insert(scalars.count - 1) }
        }
        self.pids = pids
        self.scalars = scalars
        self.chunkEnds = ends
    }

    public init(chunksJSON data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let max = object["max_position"] as? NSNumber, let raw = object["chunks"] as? [[Any]] else {
            throw ExtractionFailure.kfxFailed("unexpected chunk file")
        }
        let chunks = raw.compactMap { pair -> (pid: Int, text: String)? in
            guard pair.count == 2, let pid = pair[0] as? NSNumber, let text = pair[1] as? String else { return nil }
            return (pid.intValue, text)
        }
        self.init(maxPosition: max.intValue, chunks: chunks)
    }

    /// The text of an inclusive pid range, split into paragraphs.
    public func paragraphs(from start: Int, to end: Int) -> [String] {
        let lo = pids.lowerBound(of: Int32(clamping: start))
        let hi = pids.upperBound(of: Int32(clamping: end))
        guard lo < hi else { return [] }
        var view = String.UnicodeScalarView()
        for i in lo..<hi {
            view.append(scalars[i])
            if chunkEnds.contains(i) { view.append("\n") }
        }
        return String(view).components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
    }
}

extension Array where Element: Comparable {
    /// First index whose element is not less than `value` (sorted arrays).
    func lowerBound(of value: Element) -> Int {
        var lo = 0, hi = count
        while lo < hi { let mid = (lo + hi) / 2; if self[mid] < value { lo = mid + 1 } else { hi = mid } }
        return lo
    }

    /// First index whose element is greater than `value` (sorted arrays).
    func upperBound(of value: Element) -> Int {
        var lo = 0, hi = count
        while lo < hi { let mid = (lo + hi) / 2; if self[mid] <= value { lo = mid + 1 } else { hi = mid } }
        return lo
    }
}

/// Finds this package's resource bundle both under `swift run` and inside the
/// hand-assembled Foolscap.app (where bundles live in Contents/Resources).
public enum HighlightsResources {
    public static let bundle: Bundle = {
        let name = "foolscap_FoolscapHighlights.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), let b = Bundle(url: url) { return b }
        return Bundle.module
    }()
}
