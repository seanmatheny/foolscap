import Foundation

/// Watches the notebook folder for changes made by other processes (iCloud,
/// another editor). Two mechanisms are combined and debounced: an
/// NSFilePresenter on the root, which iCloud notifies directly, and a
/// DispatchSource on the Daily directory as a belt-and-braces fallback.
public final class FolderWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    public let presentedItemURL: URL?
    public let presentedItemOperationQueue = OperationQueue()
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "foolscap.folderwatcher")
    private var pending: DispatchWorkItem?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var started = false

    public init(root: URL, watchedSubdirectories: [URL], onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = root
        self.onChange = onChange
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        for dir in watchedSubdirectories { addSource(for: dir) }
    }

    public func start() {
        guard !started else { return }
        started = true
        NSFileCoordinator.addFilePresenter(self)
        sources.forEach { $0.resume() }
    }

    public func stop() {
        guard started else { return }
        started = false
        NSFileCoordinator.removeFilePresenter(self)
        sources.forEach { $0.cancel() }
        sources.removeAll()
    }

    deinit { stop() }

    private func addSource(for dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: queue)
        src.setEventHandler { [weak self] in self?.schedule() }
        src.setCancelHandler { close(fd) }
        sources.append(src)
    }

    private func schedule() {
        queue.async { [self] in
            pending?.cancel()
            let item = DispatchWorkItem { [onChange] in onChange() }
            pending = item
            queue.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
    }

    // MARK: NSFilePresenter
    public func presentedItemDidChange() { schedule() }
    public func presentedSubitemDidChange(at url: URL) { schedule() }
    public func presentedSubitemDidAppear(at url: URL) { schedule() }
    public func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { schedule() }
    public func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        schedule(); completionHandler(nil)
    }
}
