import Foundation

/// Runs one of the bundled recognition helpers (`scribe-ocr`, `scribe-vlm`) to
/// completion on a background thread: both pipes drained off-thread (the helper
/// blocks once a pipe buffer fills), a watchdog that terminates it after
/// `timeout`, and cancellation that terminates it through `HelperHandle`.
enum HelperProcess {
    struct Output {
        var stdout: Data
        var stderr: String
        var status: Int32
    }

    /// Launches the helper and waits. `stderrLine` is called on a background
    /// queue with each complete line the helper writes to stderr (progress).
    static func run(executable: URL, arguments: [String], timeout: TimeInterval,
                    stderrLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let handle = HelperHandle()
        // The helper runs on a detached thread, which cancellation does not reach:
        // cancelling the task terminates the process instead.
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try runBlocking(executable: executable, arguments: arguments, timeout: timeout, handle: handle, stderrLine: stderrLine)
            }.value
        } onCancel: {
            handle.cancel()
        }
    }

    private static func runBlocking(executable: URL, arguments: [String], timeout: TimeInterval, handle: HelperHandle,
                                    stderrLine: (@Sendable (String) -> Void)?) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try handle.launch(process)
        let group = DispatchGroup()
        nonisolated(unsafe) var out = Data()
        nonisolated(unsafe) var err = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let reader = stderr.fileHandleForReading
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                err.append(chunk)
                guard let stderrLine else { continue }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty { stderrLine(line) }
                }
            }
            group.leave()
        }
        nonisolated(unsafe) var killed = false
        nonisolated(unsafe) let running = process
        let watchdog = DispatchWorkItem { if running.isRunning { killed = true; running.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()
        if handle.isCancelled { throw CancellationError() }
        if killed { throw OCRError.timedOut }
        return Output(stdout: out, stderr: String(decoding: err, as: UTF8.self), status: process.terminationStatus)
    }

    /// The helper's `{"error": {"code", "message"}}` document, if that is what it printed.
    static func errorMessage(in data: Data) -> String? {
        struct HelperError: Decodable {
            struct Detail: Decodable { var code: String; var message: String }
            var error: Detail?
        }
        return (try? JSONDecoder().decode(HelperError.self, from: data))?.error?.message
    }

    /// The helper process, shared with the cancellation handler. A cancel that
    /// arrives before launch stops the launch; one after terminates the helper.
    final class HelperHandle: @unchecked Sendable {
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
