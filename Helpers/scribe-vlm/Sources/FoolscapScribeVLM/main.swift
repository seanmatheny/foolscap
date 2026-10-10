// scribe-vlm: handwriting recognition for Kindle Scribe pages with a local
// vision-language model (Qwen3-VL on MLX).
//
//   scribe-vlm recognise <pdf | page.png …> --model <hf id> [--pages 1,4,7]
//                        [--max-side 2480] [--prompt-version 1] [--keep-template]
//                        [--models-dir <dir>]
//   scribe-vlm download  --model <hf id> [--models-dir <dir>]
//   scribe-vlm status    --model <hf id> [--models-dir <dir>]
//
// `recognise` prints one JSON document on stdout:
//   {"engine": "qwen3-vl-8b-instruct-4bit/p1",
//    "pages": [{"page": 1, "width": 1860, "height": 2480,
//               "lines": [{"text": "- will set up AI workflows w/ health", "indent": 1}, …]}]}
// one entry per handwritten line in reading order, blank lines kept as "" so the
// caller can see paragraph breaks. `status` and `download` print
// {"model": …, "installed": true|false, "path": …}. Failures print
// {"error": {"code": …, "message": …}} and exit non-zero (64 for usage errors).
// Progress goes to stderr, one line at a time: "loading model", "page 3/25",
// "download 42%".
//
// A separate program, like scribe-ocr, so the model's ~6 GB leaves memory the
// moment a run finishes. Weights live under --models-dir (the app passes
// Application Support/Foolscap/Scribe/Models) in the Hugging Face cache layout.

import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXLMCommon
import MLXVLM
import MLXHuggingFace
import PDFKit
import ScribeRaster
import Tokenizers

// MARK: - Output

func writeJSON(_ object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ code: String, _ message: String, status: Int32 = 1) -> Never {
    writeJSON(["error": ["code": code, "message": message]])
    exit(status)
}

func progress(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

// MARK: - Arguments

let usage = """
usage: scribe-vlm recognise <pdf | page.png …> --model <id> [--pages 1,4,7] [--max-side 2480] \
[--prompt-version 1] [--keep-template] [--models-dir <dir>]
       scribe-vlm download --model <id> [--models-dir <dir>]
       scribe-vlm status --model <id> [--models-dir <dir>]
"""

struct Options {
    var command = ""
    var inputs: [String] = []
    var model = ""
    var pages: [Int]? = nil
    var maxSide = 0
    var promptVersion = 1
    var stripTemplate = true
    var modelsDir: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Foolscap/Scribe/Models", isDirectory: true)
}

func parseOptions() -> Options {
    var options = Options()
    var remaining = Array(CommandLine.arguments.dropFirst())
    guard !remaining.isEmpty else { fail("usage", usage, status: 64) }
    options.command = remaining.removeFirst()
    while !remaining.isEmpty {
        let argument = remaining.removeFirst()
        switch argument {
        case "--keep-template":
            options.stripTemplate = false
        case "--model", "--pages", "--max-side", "--prompt-version", "--models-dir":
            guard !remaining.isEmpty else { fail("usage", "missing value for \(argument)", status: 64) }
            let value = remaining.removeFirst()
            switch argument {
            case "--model": options.model = value
            case "--pages":
                let numbers = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard !numbers.isEmpty, numbers.allSatisfy({ $0 > 0 }) else { fail("usage", "invalid --pages: \(value)", status: 64) }
                options.pages = numbers
            case "--max-side":
                guard let n = Int(value), n > 0 else { fail("usage", "invalid --max-side: \(value)", status: 64) }
                options.maxSide = n
            case "--prompt-version":
                guard let n = Int(value), n > 0 else { fail("usage", "invalid --prompt-version: \(value)", status: 64) }
                options.promptVersion = n
            default: options.modelsDir = URL(fileURLWithPath: value, isDirectory: true)
            }
        default:
            guard !argument.hasPrefix("--") else { fail("usage", usage, status: 64) }
            options.inputs.append(argument)
        }
    }
    guard !options.model.isEmpty else { fail("usage", "--model is required", status: 64) }
    return options
}

// MARK: - Model files

/// "mlx-community/Qwen3-VL-8B-Instruct-4bit" → "qwen3-vl-8b-instruct-4bit".
func shortName(_ model: String) -> String {
    (model.split(separator: "/").last.map(String.init) ?? model).lowercased()
}

/// The Hugging Face cache folder for a repository.
func repositoryDirectory(_ model: String, in modelsDir: URL) -> URL {
    modelsDir.appendingPathComponent("models--" + model.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
}

/// Whether a complete snapshot is on disk: a config and every weight shard, each
/// present through its symlink and not empty. A download that dies mid-shard
/// leaves the finished shards behind, so sharded names ("model-00002-of-00002")
/// must all be there. (The repo's weight index is not consulted: mlx-community
/// conversions ship stale ones.)
func installedSnapshot(_ model: String, in modelsDir: URL) -> URL? {
    let fm = FileManager.default
    let snapshots = repositoryDirectory(model, in: modelsDir).appendingPathComponent("snapshots", isDirectory: true)
    guard let names = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return nil }
    for name in names.sorted() {
        let dir = snapshots.appendingPathComponent(name, isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(atPath: dir.path), weightsComplete(files: files, in: dir) else { continue }
        return dir
    }
    return nil
}

/// Shared with the app's `VLMModelStore.isInstalled`; keep the two in step.
func weightsComplete(files: [String], in dir: URL) -> Bool {
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

func statusObject(_ model: String, in modelsDir: URL) -> [String: Any] {
    let snapshot = installedSnapshot(model, in: modelsDir)
    return ["model": model, "installed": snapshot != nil, "path": snapshot?.path ?? repositoryDirectory(model, in: modelsDir).path]
}

/// A client whose session survives CDN stalls: the default 60 s request timeout
/// killed a 5 GB shard at 60%. Downloads are not resumed across attempts, so the
/// caller retries the whole download a few times.
func hubClient(_ modelsDir: URL) -> HubClient {
    try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 15 * 60
    configuration.timeoutIntervalForResource = 24 * 60 * 60
    configuration.waitsForConnectivity = true
    return HubClient(session: URLSession(configuration: configuration), cache: HubCache(cacheDirectory: modelsDir))
}

// MARK: - Prompts

/// Bumped (with the app's engine version) when the wording changes, so cached
/// readings are redone.
func instructions(version: Int) -> String {
    switch version {
    default:
        return """
        You are an OCR engine for handwritten notebook pages. Transcribe the handwriting in \
        the image exactly as written: one output line per handwritten line, in reading order \
        from top to bottom. Keep bullets, dashes, numbering, arrows, checkboxes and punctuation \
        as written. Show indentation with leading spaces, two per level. Do not correct \
        spelling or grammar, do not expand abbreviations, and do not add words, headings, \
        commentary or markdown formatting. Never repeat a word more than twice in a row. If a \
        word is illegible, write your best guess. If the page has no writing, output nothing. \
        Output only the transcription.
        """
    }
}

let userPrompt = "Transcribe this page."

// MARK: - Output parsing

/// The model's text as lines with their indent level. Fences and think blocks
/// are dropped; a blank line is kept as "" so paragraph breaks survive.
func parseLines(_ text: String) -> [[String: Any]] {
    var body = text
    if let open = body.range(of: "<think>"), let close = body.range(of: "</think>", range: open.upperBound..<body.endIndex) {
        body.removeSubrange(open.lowerBound..<close.upperBound)
    }
    var lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    var result: [[String: Any]] = []
    var previousBlank = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if !previousBlank { result.append(["text": "", "indent": 0]) }
            previousBlank = true
            continue
        }
        previousBlank = false
        var spaces = 0
        for character in line {
            if character == " " { spaces += 1 } else if character == "\t" { spaces += 2 } else { break }
        }
        result.append(["text": trimmed, "indent": spaces / 2])
    }
    return result
}

// MARK: - Pages

struct PageImage {
    var number: Int
    var image: CGImage
}

/// The pages to read: from a PDF (optionally a subset) or from image files.
func loadPages(_ options: Options) -> [PageImage] {
    guard let first = options.inputs.first else { fail("usage", usage, status: 64) }
    if options.inputs.count == 1, first.lowercased().hasSuffix(".pdf") {
        guard let document = PDFDocument(url: URL(fileURLWithPath: first)) else { fail("pdf_open_failed", "Could not open PDF: \(first)") }
        let numbers = options.pages ?? Array(1...max(document.pageCount, 1))
        return numbers.compactMap { number -> PageImage? in
            guard number <= document.pageCount, let page = document.page(at: number - 1) else {
                fail("page_missing", "Page \(number) is beyond the \(document.pageCount) pages of \(first)")
            }
            let dpi = options.maxSide > 0 ? PageRaster.dpi(fitting: options.maxSide, page: page) : PageRaster.nativeDPI
            guard let image = PageRaster.render(page, dpi: dpi, stripTemplate: options.stripTemplate) else {
                fail("render_failed", "Could not render page \(number) of \(first)")
            }
            return PageImage(number: number, image: image)
        }
    }
    return options.inputs.enumerated().map { index, path in
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { fail("image_open_failed", "Could not open image: \(path)") }
        if options.maxSide > 0, max(image.width, image.height) > options.maxSide {
            let scale = CGFloat(options.maxSide) / CGFloat(max(image.width, image.height))
            let width = Int((CGFloat(image.width) * scale).rounded()), height = Int((CGFloat(image.height) * scale).rounded())
            if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let scaled = context.makeImage() { image = scaled }
            }
        }
        return PageImage(number: index + 1, image: image)
    }
}

// MARK: - Commands

func loadModel(_ options: Options) async throws -> ModelContainer {
    let hub = hubClient(options.modelsDir)
    progress("loading model")
    return try await VLMModelFactory.shared.loadContainer(
        from: #hubDownloader(hub),
        using: #huggingFaceTokenizerLoader(),
        configuration: ModelConfiguration(id: options.model)
    ) { downloadProgress in
        progress("download \(Int(downloadProgress.fractionCompleted * 100))%")
    }
}

func runRecognise(_ options: Options) async {
    let pages = loadPages(options)
    let container: ModelContainer
    do {
        container = try await loadModel(options)
    } catch {
        fail("model_load_failed", "Could not load \(options.model): \(error)")
    }
    var output: [[String: Any]] = []
    for (index, page) in pages.enumerated() {
        progress("page \(index + 1)/\(pages.count)")
        let session = ChatSession(
            container,
            instructions: instructions(version: options.promptVersion),
            generateParameters: GenerateParameters(maxTokens: 1536, temperature: 0, repetitionPenalty: 1.05, repetitionContextSize: 64),
            processing: UserInput.Processing(resize: nil)
        )
        do {
            let text = try await session.respond(to: userPrompt, image: .ciImage(CIImage(cgImage: page.image)))
            output.append(["page": page.number, "width": page.image.width, "height": page.image.height, "lines": parseLines(text)])
        } catch {
            fail("recognition_failed", "Recognition failed on page \(page.number): \(error)")
        }
    }
    writeJSON(["engine": "\(shortName(options.model))/p\(options.promptVersion)", "model": options.model, "pages": output])
}

func runDownload(_ options: Options) async {
    let hub = hubClient(options.modelsDir)
    let downloader = #hubDownloader(hub)
    var lastError: Error?
    for attempt in 1...4 where installedSnapshot(options.model, in: options.modelsDir) == nil {
        if attempt > 1 { progress("download retry \(attempt)"); try? await Task.sleep(for: .seconds(10)) }
        do {
            _ = try await downloader.download(
                id: options.model, revision: nil,
                matching: ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model", "*.tiktoken"],
                useLatest: false
            ) { downloadProgress in
                progress("download \(Int(downloadProgress.fractionCompleted * 100))%")
            }
            lastError = nil
        } catch {
            lastError = error
        }
    }
    if installedSnapshot(options.model, in: options.modelsDir) == nil {
        fail("download_failed", "Could not download \(options.model): \(lastError.map { "\($0)" } ?? "weights incomplete")")
    }
    writeJSON(statusObject(options.model, in: options.modelsDir))
}

/// Foolscap launched this helper and waits for it; if Foolscap is quit or dies
/// mid-run the helper is reparented to launchd, and must not go on holding the
/// models (gigabytes, for the VLM) to finish pages nobody will read.
func exitWhenParentDies() {
    let parent = getppid()
    Thread.detachNewThread {
        while getppid() == parent { Thread.sleep(forTimeInterval: 1) }
        exit(0)
    }
}
exitWhenParentDies()

let options = parseOptions()
switch options.command {
case "recognise", "recognize":
    await runRecognise(options)
case "download":
    await runDownload(options)
case "status":
    writeJSON(statusObject(options.model, in: options.modelsDir))
default:
    fail("usage", usage, status: 64)
}
