import Testing
import Foundation
import FoolscapStore
@testable import FoolscapScribe

@Suite struct ScribeVLMEngineTests {
    @Test func engineSettingRoundTrips() {
        #expect(OCREngine(defaultsValue: nil) == .vision)
        #expect(OCREngine(defaultsValue: "vision") == .vision)
        #expect(OCREngine(defaultsValue: "vlm") == .localVLM(model: OCREngine.defaultVLMModel))
        #expect(OCREngine(defaultsValue: "vlm:mlx-community/Qwen3-VL-4B-Instruct-4bit") == .localVLM(model: "mlx-community/Qwen3-VL-4B-Instruct-4bit"))
        #expect(OCREngine(defaultsValue: "nonsense") == .vision)
        #expect(OCREngine.localVLM(model: OCREngine.defaultVLMModel).defaultsValue == "vlm")
        #expect(OCREngine.localVLM(model: "a/B-4bit").defaultsValue == "vlm:a/B-4bit")
    }

    @Test func versionsNameTheEngineAndPrompt() {
        #expect(OCREngine.vision.version == ScribeOCR.engineVersion)
        #expect(OCREngine.localVLM(model: "mlx-community/Qwen3-VL-8B-Instruct-4bit").version == "qwen3-vl-8b-instruct-4bit/p\(OCREngine.vlmPromptVersion)s\(OCREngine.vlmMaxSide)")
        let a = ScribeSyncEngine.transcriptKey(contentHash: "h", languages: ["en-US"], engine: .vision, path: "p", title: "t")
        let b = ScribeSyncEngine.transcriptKey(contentHash: "h", languages: ["en-US"], engine: .localVLM(model: "x/y"), path: "p", title: "t")
        #expect(a != b)
    }

    /// Lines become fragments `layoutPage` reads back as the same lines, a blank line
    /// as a paragraph break, indentation as a step to the right.
    @Test func linesLayOutAsParagraphsWithIndent() {
        let lines = [VLMLine(text: "Monday"), VLMLine(text: "- call Bob", indent: 1), VLMLine(text: "- about the thing that is quite long indeed", indent: 2),
                     VLMLine(text: ""), VLMLine(text: "Later"), VLMLine(text: "- TODO: wash car")]
        let observations = VLMLayout.observations(lines)
        #expect(observations.count == 5)
        #expect(observations[1].x > observations[0].x && observations[2].x > observations[1].x)
        #expect(observations[2].x + observations[2].w >= wrapMargin && observations[0].x + observations[0].w < wrapMargin)
        let paragraphs = ScribeLayout.layoutPage(observations)
        #expect(paragraphs.map { $0.map(\.text) } == [["Monday", "- call Bob", "- about the thing that is quite long indeed"], ["Later", "- TODO: wash car"]])
        #expect(ScribeTodos.extractTodos([paragraphs]).map(\.text) == ["wash car"])
        #expect(VLMLayout.observations([]).isEmpty)
        #expect(VLMLayout.observations([VLMLine(text: "   ")]).isEmpty)
    }

    @Test func pageCacheKeysOnPixelsAndEngine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-page-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OCRPageCache(directory: dir)
        let lines = [VLMLine(text: "hi", indent: 1)]
        #expect(cache.load(hash: "abc", engine: "q/p1") == nil)
        try cache.store(lines, hash: "abc", engine: "q/p1")
        #expect(cache.load(hash: "abc", engine: "q/p1") == lines)
        #expect(cache.load(hash: "abc", engine: "q/p2") == nil)
        #expect(cache.load(hash: "abd", engine: "q/p1") == nil)
    }

    @Test func modelStoreSeesOnlyCompleteSnapshots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = "mlx-community/Qwen3-VL-8B-Instruct-4bit"
        #expect(!VLMModelStore.isInstalled(model: model, in: dir))
        let snapshot = VLMModelStore.repositoryDirectory(model: model, in: dir).appendingPathComponent("snapshots/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        #expect(!VLMModelStore.isInstalled(model: model, in: dir))
        try Data(repeating: 0, count: 10).write(to: snapshot.appendingPathComponent("model.safetensors"))
        #expect(VLMModelStore.isInstalled(model: model, in: dir))
        #expect(VLMModelStore.size(model: model, in: dir) == 12)
        // The second shard of two without the first (a download that died mid-shard).
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("model.safetensors"))
        try Data(repeating: 0, count: 4).write(to: snapshot.appendingPathComponent("model-00002-of-00002.safetensors"))
        #expect(!VLMModelStore.isInstalled(model: model, in: dir))
        try Data(repeating: 0, count: 4).write(to: dir.appendingPathComponent("blob"))
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("model-00001-of-00002.safetensors"), withDestinationURL: dir.appendingPathComponent("blob"))
        #expect(VLMModelStore.isInstalled(model: model, in: dir))
        try Data().write(to: snapshot.appendingPathComponent("model-2.safetensors.incomplete"))
        #expect(!VLMModelStore.isInstalled(model: model, in: dir))
        #expect(VLMModelStore.modelsOnDisk(in: dir) == [model])
        try VLMModelStore.remove(model: model, in: dir)
        #expect(VLMModelStore.modelsOnDisk(in: dir).isEmpty && !VLMModelStore.isInstalled(model: model, in: dir))
        try VLMModelStore.remove(model: model, in: dir)  // already gone: not an error
    }

    /// With the VLM chosen but not installed, a pass reads with Vision under Vision's
    /// keys and says so; once the VLM can run the notebook is read again.
    @Test @MainActor func fallsBackToVisionUntilTheModelIsThere() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-scribe-vlm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = NotesFolder(root: tmp.appendingPathComponent("Notes"))
        try folder.ensureLayout()
        let library = try NotebookLibrary(folder: folder, indexPath: TestIndex.path)
        let client = FakeScribeClient()
        client.listing = [RemoteItem(id: "n1", title: "Diary", type: "notebook")]
        client.opened["n1"] = OpenedNotebook(renderingToken: "t1", metadata: .init(modificationTime: 1_700_000_000, totalPages: 1))
        client.pages["t1"] = [makePNG(width: 40, height: 40)]
        let vlm = OCREngine.localVLM(model: "x/model")
        let cache = OCRCache(directory: tmp.appendingPathComponent("OCR"))
        let engine = ScribeSyncEngine(client: client, ocr: ThrowingOCR(error: .modelMissing("x/model")), engine: vlm,
                                      fallback: (FakeOCR(observations: [[fragment("hello", 0.05, 0.1)]]), .vision),
                                      cache: cache, stateURL: tmp.appendingPathComponent("state.json"),
                                      sink: LibraryTaskSink(library: library), now: { Date(timeIntervalSince1970: 1_700_000_100) }, sleep: { _ in })
        let report = try await engine.syncOnce(notesRoot: folder.root, languages: ["en-US"])
        #expect(report.transcribed == 1)
        #expect(report.errors.count == 1 && report.errors[0].contains("Apple Vision") && report.errors[0].contains("not downloaded"))
        let md = folder.scribeDirectory.appendingPathComponent("Diary.md")
        #expect(try String(contentsOf: md, encoding: .utf8).contains("hello"))
        let hash = try #require(await engine.state.items["n1"]?.contentHash)
        #expect(cache.load(id: "n1", key: OCRCacheKey(contentHash: hash, engine: ScribeOCR.engineVersion, languages: ["en-US"])) != nil)
        #expect(cache.load(id: "n1", key: OCRCacheKey(contentHash: hash, engine: vlm.version, languages: ["en-US"])) == nil)

        // The model arrives: the next pass reads again with the VLM.
        await engine.configure(ocr: FakeOCR(observations: [[fragment("bonjour", 0.05, 0.1)]]), engine: vlm, fallback: nil)
        let again = try await engine.syncOnce(notesRoot: folder.root, languages: ["en-US"])
        #expect(again.transcribed == 1 && again.errors.isEmpty)
        #expect(try String(contentsOf: md, encoding: .utf8).contains("bonjour"))
        #expect(cache.load(id: "n1", key: OCRCacheKey(contentHash: hash, engine: vlm.version, languages: ["en-US"])) != nil)
    }

    /// The helper's JSON, when a build is present (`make scribe-vlm`; needs Xcode and
    /// its Metal Toolchain). Skipped otherwise.
    @Test func helperReportsStatusWhenBuilt() async throws {
        guard let helper = VLMOCRRunner.locateHelper() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("foolscap-vlm-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = try await HelperProcess.run(executable: helper, arguments: ["status", "--model", "x/y", "--models-dir", dir.path], timeout: 60)
        let object = try #require(try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any])
        #expect(object["installed"] as? Bool == false && object["model"] as? String == "x/y")
        let runner = VLMOCRRunner(helperURL: helper, model: "x/y", modelsDirectory: dir, pageCache: OCRPageCache(directory: dir.appendingPathComponent("pages")))
        await #expect(throws: OCRError.modelMissing("x/y")) {
            try await runner.recognise(pdf: dir.appendingPathComponent("none.pdf"), languages: ["en-US"])
        }
    }
}

struct ThrowingOCR: OCRRunning {
    let error: OCRError
    func recognise(pdf: URL, languages: [String]) async throws -> OCRResult { throw error }
}
