import AppKit

/// The Kindle app itself. It only fetches new highlights from Amazon while it
/// runs, so an import can open it hidden, wait for it to sync, and quit it.
@MainActor
enum KindleApp {
    static let bundleID = "com.amazon.Lassen"

    static var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isInstalled: Bool { url != nil }
    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    /// Launch without activating or showing a window. Returns the process to quit afterwards.
    static func launchHidden() async throws -> NSRunningApplication {
        guard let url else { throw ExtractionFailure.unreadable("the Kindle app is not installed") }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// The files a fresh Kindle writes as it syncs: its library and Whispersync
    /// state on every launch (within ~15 s), the annotation database only when
    /// highlights changed. Watching all three ends the wait as soon as the sync
    /// has gone quiet, whether or not anything was new.
    static func syncFiles(dataDirectory: URL) -> [URL] {
        var files = [dataDirectory.appendingPathComponent("Library/Protected/BookData.sqlite-wal"),
                     dataDirectory.appendingPathComponent("Library/Application Support/Whispersync/WSyncDefault.sqlite-wal")]
        if let annotations = KindleAnnotations.databaseURL(dataDirectory: dataDirectory) { files.append(annotations) }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Wait for any of the files to be written, then for a quiet spell (the
    /// app writes in bursts while syncing). False when nothing was written
    /// before the timeout.
    static func waitForSync(of files: [URL], timeout: TimeInterval, quiet: TimeInterval = 8) async -> Bool {
        let box = WriteBox()
        var sources: [DispatchSourceFileSystemObject] = []
        for file in files {
            let fd = open(file.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: .main)
            source.setEventHandler { box.lastWrite = Date() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        defer { sources.forEach { $0.cancel() } }
        guard !sources.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return false }
            if let last = box.lastWrite, Date().timeIntervalSince(last) >= quiet { return true }
        }
        return box.lastWrite != nil
    }

    private final class WriteBox: @unchecked Sendable {
        var lastWrite: Date?
    }
}
