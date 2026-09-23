import Foundation

/// One text fragment Vision found on a page. Boxes are fractions of the page
/// with a top-left origin, as the helper reports them.
public struct OCRObservation: Codable, Equatable, Sendable {
    public var text: String
    public var alternates: [String]
    public var confidence: Double
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(text: String, alternates: [String] = [], confidence: Double = 1, x: Double, y: Double, w: Double, h: Double) {
        self.text = text; self.alternates = alternates; self.confidence = confidence
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        alternates = try c.decodeIfPresent([String].self, forKey: .alternates) ?? []
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w)
        h = try c.decode(Double.self, forKey: .h)
    }
}

public struct OCRPage: Codable, Equatable, Sendable {
    public var page: Int
    public var width: Int
    public var height: Int
    public var observations: [OCRObservation]
    public init(page: Int, width: Int, height: Int, observations: [OCRObservation]) {
        self.page = page; self.width = width; self.height = height; self.observations = observations
    }
}

public struct OCRResult: Codable, Equatable, Sendable {
    public var engine: String
    public var languages: [String]
    public var pages: [OCRPage]
    public init(engine: String, languages: [String], pages: [OCRPage]) {
        self.engine = engine; self.languages = languages; self.pages = pages
    }
}

public enum ScribeOCR {
    /// Bumped when the helper's recognition changes, so cached results are redone.
    public static let engineVersion = "vision-text-accurate/1"
}

public protocol OCRRunning: Sendable {
    func recognise(pdf: URL, languages: [String]) async throws -> OCRResult
}

public enum OCRError: Error, Equatable {
    case helperMissing
    case helperFailed(String)
    case timedOut
}

/// Runs the bundled `scribe-ocr` helper. Vision's models stay resident in
/// whichever process loads them, so the work is kept out of the app.
public struct ProcessOCRRunner: OCRRunning {
    public let helperURL: URL
    /// The first run after a reboot can spend ~30 s loading models.
    public var timeout: TimeInterval = 900

    public init(helperURL: URL) { self.helperURL = helperURL }

    /// The helper next to the app binary, or a development build.
    public static func locateHelper() -> URL? {
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("scribe-ocr"))
        }
        if let env = ProcessInfo.processInfo.environment["FOOLSCAP_SCRIBE_OCR"] { candidates.append(URL(fileURLWithPath: env)) }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for config in ["debug", "release"] {
            candidates.append(package.appendingPathComponent(".build/\(config)/FoolscapScribeOCR"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func recognise(pdf: URL, languages: [String]) async throws -> OCRResult {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw OCRError.helperMissing }
        let helper = helperURL, timeout = self.timeout
        let (output, errorText, status) = try await Task.detached(priority: .utility) {
            try Self.run(helper: helper, pdf: pdf, languages: languages, timeout: timeout)
        }.value
        if let payload = try? JSONDecoder().decode(HelperError.self, from: output), let error = payload.error {
            throw OCRError.helperFailed(error.message)
        }
        do {
            return try JSONDecoder().decode(OCRResult.self, from: output)
        } catch {
            throw OCRError.helperFailed("helper returned no JSON (exit \(status)): \(errorText.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Synchronous: runs on a background thread, blocking until the helper exits.
    private static func run(helper: URL, pdf: URL, languages: [String], timeout: TimeInterval) throws -> (Data, String, Int32) {
        let process = Process()
        process.executableURL = helper
        process.arguments = [pdf.path, "--languages", languages.joined(separator: ",")]
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
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
        if killed { throw OCRError.timedOut }
        return (out, String(decoding: err, as: UTF8.self), process.terminationStatus)
    }

    private struct HelperError: Decodable {
        struct Detail: Decodable { var code: String; var message: String }
        var error: Detail?
    }
}

/// What an OCR result depends on. A notebook is only re-read when one of
/// these changes; a PDF rebuilt from identical page images is not.
public struct OCRCacheKey: Codable, Equatable, Sendable {
    public var contentHash: String
    public var engine: String
    public var languages: [String]
    public init(contentHash: String, engine: String = ScribeOCR.engineVersion, languages: [String]) {
        self.contentHash = contentHash; self.engine = engine; self.languages = languages
    }
}

/// One JSON file per notebook id under Application Support.
public struct OCRCache: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private struct Entry: Codable { var key: OCRCacheKey; var ocr: OCRResult }

    private func url(for id: String) -> URL {
        let safe = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent(safe + ".json")
    }

    public func load(id: String, key: OCRCacheKey) -> OCRResult? {
        guard let data = try? Data(contentsOf: url(for: id)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.key == key else { return nil }
        return entry.ocr
    }

    public func store(_ result: OCRResult, id: String, key: OCRCacheKey) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Entry(key: key, ocr: result))
        try data.write(to: url(for: id), options: .atomic)
    }

    public func remove(id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
