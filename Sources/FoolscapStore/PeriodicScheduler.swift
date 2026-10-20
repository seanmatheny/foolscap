import Foundation

/// Periodic work. On the Mac through `NSBackgroundActivityScheduler`, so macOS can
/// coalesce it with other background activity and defer it on battery; on the
/// phone a plain sleeping task, which only runs while the app is in front.
/// Nothing runs while the app is closed; a manual run bypasses the schedule.
@MainActor
public final class PeriodicScheduler {
    private let identifier: String
    private let work: @MainActor () async -> Void
    #if canImport(AppKit)
    private var scheduler: NSBackgroundActivityScheduler?
    #else
    private var task: Task<Void, Never>?
    #endif

    public init(identifier: String, work: @escaping @MainActor () async -> Void) {
        self.identifier = identifier
        self.work = work
    }

    public func start(minutes: Int) {
        stop()
        let interval = TimeInterval(max(1, minutes) * 60)
        let work = self.work
        #if canImport(AppKit)
        let s = NSBackgroundActivityScheduler(identifier: identifier)
        s.repeats = true
        s.interval = interval
        s.tolerance = s.interval / 4
        s.qualityOfService = .utility
        s.schedule { completion in
            Task { @MainActor in
                await work()
                completion(.finished)
            }
        }
        scheduler = s
        #else
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await work()
            }
        }
        #endif
    }

    public func stop() {
        #if canImport(AppKit)
        scheduler?.invalidate()
        scheduler = nil
        #else
        task?.cancel()
        task = nil
        #endif
    }
}
