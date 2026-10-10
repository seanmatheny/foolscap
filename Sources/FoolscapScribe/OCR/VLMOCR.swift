import CryptoKit
import Foundation
import PDFKit
import ScribeRaster

/// Which recogniser reads the handwriting. Each has a version string that goes
/// into the OCR cache key and the transcript key, so changing engine (or a
/// helper's recognition) re-reads every notebook once.
public enum OCREngine: Equatable, Sendable {
    /// Apple Vision in the bundled `scribe-ocr` helper: fast, built in, weak on handwriting.
    case vision
    /// A local vision-language model (Hugging Face id) run by `scribe-vlm` on MLX.
    case localVLM(model: String)

    public static let defaultVLMModel = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
    /// Bumped with the helper's instructions so cached readings are redone.
    public static let vlmPromptVersion = 1
    /// Pages are handed to the model with their longer side scaled to this many
    /// pixels: two thirds of the Scribe's 2480 read as well as full size in the
    /// bake-off and a fifth faster. Part of the version, so changing it re-reads.
    public static let vlmMaxSide = 1653

    public var version: String {
        switch self {
        case .vision: return ScribeOCR.engineVersion
        case .localVLM(let model): return "\(OCREngine.shortName(model))/p\(OCREngine.vlmPromptVersion)s\(OCREngine.vlmMaxSide)"
        }
    }

    public var isVLM: Bool { if case .localVLM = self { return true } else { return false } }

    /// "mlx-community/Qwen3-VL-8B-Instruct-4bit" → "qwen3-vl-8b-instruct-4bit", as the helper reports it.
    public static func shortName(_ model: String) -> String {
        (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
    }

    /// The `scribeOCREngine` default: "vision", "vlm" (the default model) or "vlm:<model id>".
    public init(defaultsValue: String?) {
        guard let value = defaultsValue?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value != "vision" else {
            self = .vision; return
        }
        if value == "vlm" { self = .localVLM(model: OCREngine.defaultVLMModel) }
        else if value.hasPrefix("vlm:") { self = .localVLM(model: String(value.dropFirst(4))) }
        else { self = .vision }
    }

    public var defaultsValue: String {
        switch self {
        case .vision: return "vision"
        case .localVLM(let model): return model == OCREngine.defaultVLMModel ? "vlm" : "vlm:\(model)"
        }
    }
}

/// One line of a page as the VLM helper reports it.
public struct VLMLine: Codable, Equatable, Sendable {
    public var text: String
    public var indent: Int
    public init(text: String, indent: Int = 0) { self.text = text; self.indent = indent }
}

public enum VLMLayout {
    /// Lines as OCR fragments with synthetic boxes, so `ScribeLayout.layoutPage`
    /// and the TODO rules run unchanged: line `i` of `n` sits at `y = i/n`; a blank
    /// line is not emitted but keeps its slot, so the pitch across it doubles and
    /// `layoutPage` starts a paragraph; indent moves `x` right; width follows the
    /// line's length so a long line still reaches `wrapMargin`.
    public static func observations(_ lines: [VLMLine]) -> [OCRObservation] {
        let n = max(lines.count, 1)
        let longest = max(lines.map(\.text.count).max() ?? 1, 1)
        var result: [OCRObservation] = []
        for (index, line) in lines.enumerated() where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let width = max(0.9 * Double(line.text.count) / Double(longest), 0.02)
            result.append(OCRObservation(text: line.text, x: 0.05 + 0.04 * Double(line.indent), y: Double(index) / Double(n),
                                         w: width, h: 1 / Double(n)))
        }
        return result
    }
}

/// Readings cached per page image, keyed on the rendered pixels and the engine:
/// an edited page costs one page's recognition, not the notebook's.
public struct OCRPageCache: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    private struct Entry: Codable { var engine: String; var lines: [VLMLine] }

    private func url(hash: String, engine: String) -> URL {
        let safe = engine.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("\(hash)-\(safe).json")
    }

    public func load(hash: String, engine: String) -> [VLMLine]? {
        guard let data = try? Data(contentsOf: url(hash: hash, engine: engine)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.engine == engine else { return nil }
        return entry.lines
    }

    public func store(_ lines: [VLMLine], hash: String, engine: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Entry(engine: engine, lines: lines)).write(to: url(hash: hash, engine: engine), options: .atomic)
    }
}

/// The weights on disk, in the Hugging Face cache layout the helper downloads into.
public enum VLMModelStore {
    public static var defaultDirectory: URL { ScribePaths.supportDirectory.appendingPathComponent("Models", isDirectory: true) }

    public static func repositoryDirectory(model: String, in directory: URL = defaultDirectory) -> URL {
        directory.appendingPathComponent("models--" + model.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    /// Whether a complete snapshot is present: a config and every weight shard, each
    /// present through its symlink and not empty. A download that dies mid-shard
    /// leaves the finished shards behind, so sharded names ("model-00002-of-00002")
    /// must all be there. Mirrors the helper's `weightsComplete`; keep them in step.
    public static func isInstalled(model: String, in directory: URL = defaultDirectory) -> Bool {
        let fm = FileManager.default
        let snapshots = repositoryDirectory(model: model, in: directory).appendingPathComponent("snapshots", isDirectory: true)
        guard let names = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return false }
        return names.contains { name in
            let dir = snapshots.appendingPathComponent(name, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            return weightsComplete(files: files, in: dir)
        }
    }

    static func weightsComplete(files: [String], in dir: URL) -> Bool {
        let fm = FileManager.default
        guard files.contains("config.json"),
              !files.contains(where: { $0.hasSuffix(".incomplete") || $0.hasSuffix(".part") }) else { return false }
        let shards = files.filter { $0.hasSuffix(".safetensors") }
        guard !shards.isEmpty else { return false }
        let pattern = try! NSRegularExpression(pattern: #"^(.*?)(\d+)-of-(\d+)\.safetensors$"#)
        for shard in shards {
            guard let match = pattern.firstMatch(in: shard, range: NSRange(shard.startIndex..., in: shard)),
                  let prefix = Range(match.range(at: 1), in: shard), let digits = Range(match.range(at: 2), in: shard),
                  let totalRange = Range(match.range(at: 3), in: shard), let total = Int(shard[totalRange]) else { continue }
            let width = shard[digits].count
            for index in 1...max(total, 1) {
                let expected = String(shard[prefix]) + String(format: "%0\(width)d", index) + "-of-" + String(shard[totalRange]) + ".safetensors"
                if !shards.contains(expected) { return false }
            }
        }
        return shards.allSatisfy { file in
            let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(file).resolvingSymlinksInPath().path)[.size] as? Int) ?? 0
            return size > 0
        }
    }

    /// Every model with files on disk ("org/name" ids from the cache's `models--org--name`
    /// folders), installed or half downloaded, so the pane can offer to delete them.
    public static func modelsOnDisk(in directory: URL = defaultDirectory) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasPrefix("models--") }
            .map { $0.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/") }
            .sorted()
    }

    /// Remove a model's files. It is downloaded again when next needed.
    public static func remove(model: String, in directory: URL = defaultDirectory) throws {
        let repository = repositoryDirectory(model: model, in: directory)
        if FileManager.default.fileExists(atPath: repository.path) {
            try FileManager.default.removeItem(at: repository)
        }
        // The cache's lock files for the model, if any.
        let locks = directory.appendingPathComponent(".locks/" + repository.lastPathComponent, isDirectory: true)
        try? FileManager.default.removeItem(at: locks)
    }

    /// Bytes on disk for the model, for the settings pane.
    public static func size(model: String, in directory: URL = defaultDirectory) -> Int64 {
        let root = repositoryDirectory(model: model, in: directory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Fetch the weights through the helper. `progress` gets the helper's stderr
    /// lines ("download 42%").
    public static func download(model: String, helper: URL, into directory: URL = defaultDirectory,
                                progress: @escaping @Sendable (String) -> Void) async throws {
        let output = try await HelperProcess.run(executable: helper,
                                                 arguments: ["download", "--model", model, "--models-dir", directory.path],
                                                 timeout: 6 * 60 * 60, stderrLine: progress)
        if let message = HelperProcess.errorMessage(in: output.stdout) { throw OCRError.helperFailed(message) }
        guard output.status == 0 else { throw OCRError.helperFailed("download exited \(output.status): \(output.stderr.suffix(300))") }
    }
}

/// Runs the bundled `scribe-vlm` helper over the pages the page cache does not
/// already hold. The helper loads a ~6 GB model, so it is a separate process (the
/// memory comes back when it exits) and it is only launched when there is at least
/// one page to read.
public struct VLMOCRRunner: OCRRunning {
    public let helperURL: URL
    public let model: String
    public let modelsDirectory: URL
    public let pageCache: OCRPageCache
    public var progress: (@Sendable (String) -> Void)?
    /// Model load plus a generous allowance per page (about a minute each on an M3 Pro).
    public var loadTimeout: TimeInterval = 120
    public var secondsPerPage: TimeInterval = 180

    public init(helperURL: URL, model: String, modelsDirectory: URL = VLMModelStore.defaultDirectory,
                pageCache: OCRPageCache, progress: (@Sendable (String) -> Void)? = nil) {
        self.helperURL = helperURL; self.model = model; self.modelsDirectory = modelsDirectory
        self.pageCache = pageCache; self.progress = progress
    }

    public var engine: OCREngine { .localVLM(model: model) }

    /// The helper next to the app binary, or a development build from `make scribe-vlm`.
    public static func locateHelper() -> URL? {
        var candidates: [URL] = []
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("scribe-vlm"))
        }
        if let env = ProcessInfo.processInfo.environment["FOOLSCAP_SCRIBE_VLM"] { candidates.append(URL(fileURLWithPath: env)) }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for config in ["Release", "Debug"] {
            candidates.append(package.appendingPathComponent(".build/xcode/Build/Products/\(config)/FoolscapScribeVLM"))
        }
        candidates.append(package.appendingPathComponent("Foolscap.app/Contents/MacOS/scribe-vlm"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func recognise(pdf: URL, languages: [String]) async throws -> OCRResult {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw OCRError.helperMissing }
        guard VLMModelStore.isInstalled(model: model, in: modelsDirectory) else { throw OCRError.modelMissing(model) }
        let version = engine.version
        let rendered = try await Task.detached(priority: .utility) { try Self.hashPages(of: pdf) }.value
        var lines: [Int: [VLMLine]] = [:]
        var misses: [Int] = []
        for page in rendered {
            if let cached = pageCache.load(hash: page.hash, engine: version) { lines[page.number] = cached } else { misses.append(page.number) }
        }
        if !misses.isEmpty {
            let name = pdf.deletingPathExtension().lastPathComponent
            progress?("Reading \(name)… loading model")
            let arguments = ["recognise", pdf.path, "--model", model, "--models-dir", modelsDirectory.path,
                             "--pages", misses.map(String.init).joined(separator: ","),
                             "--prompt-version", String(OCREngine.vlmPromptVersion), "--max-side", String(OCREngine.vlmMaxSide)]
            let report = progress
            let missing = misses.count
            let output = try await HelperProcess.run(executable: helperURL, arguments: arguments,
                                                     timeout: loadTimeout + secondsPerPage * Double(missing)) { line in
                if line.hasPrefix("page "), let report {
                    let counter = line.dropFirst(5)
                    report("Reading \(name)… page \(counter) of \(missing) new")
                }
            }
            if let message = HelperProcess.errorMessage(in: output.stdout) { throw OCRError.helperFailed(message) }
            let decoded: HelperResult
            do { decoded = try JSONDecoder().decode(HelperResult.self, from: output.stdout) } catch {
                throw OCRError.helperFailed("scribe-vlm returned no JSON (exit \(output.status)): \(output.stderr.suffix(300).trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            for page in decoded.pages {
                lines[page.page] = page.lines
                try? pageCache.store(page.lines, hash: rendered.first { $0.number == page.page }?.hash ?? "", engine: version)
            }
        }
        let pages = rendered.map { page in
            OCRPage(page: page.number, width: page.width, height: page.height, observations: VLMLayout.observations(lines[page.number] ?? []))
        }
        return OCRResult(engine: version, languages: languages, pages: pages)
    }

    struct HelperResult: Decodable {
        struct Page: Decodable { var page: Int; var lines: [VLMLine] }
        var engine: String
        var pages: [Page]
    }

    struct RenderedPage { var number: Int; var width: Int; var height: Int; var hash: String }

    /// Each page's identity: a hash of its pixels as the helper will render them.
    static func hashPages(of pdf: URL) throws -> [RenderedPage] {
        guard let document = PDFDocument(url: pdf) else { throw OCRError.helperFailed("Could not open \(pdf.lastPathComponent)") }
        var pages: [RenderedPage] = []
        for index in 0..<document.pageCount {
            try autoreleasepool {
                guard let page = document.page(at: index), let image = PageRaster.render(page) else {
                    throw OCRError.helperFailed("Could not render page \(index + 1) of \(pdf.lastPathComponent)")
                }
                pages.append(RenderedPage(number: index + 1, width: image.width, height: image.height, hash: PageRaster.pixelHash(image)))
            }
        }
        return pages
    }
}
