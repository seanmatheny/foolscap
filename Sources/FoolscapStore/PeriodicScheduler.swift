import Foundation

/// Periodic work through `NSBackgroundActivityScheduler`, so macOS can
/// coalesce it with other background activity and defer it on battery.
/// Nothing runs while the app is closed; a manual run bypasses the schedule.
@MainActor
public final class PeriodicScheduler {
    private let identifier: String
    private var scheduler: NSBackgroundActivityScheduler?
    private let work: @MainActor () async -> Void

    public init(identifier: String, work: @escaping @MainActor () async -> Void) {
        self.identifier = identifier
        self.work = work
    }

    public var isRunning: Bool { scheduler != nil }

    public func start(minutes: Int) {
        stop()
        let s = NSBackgroundActivityScheduler(identifier: identifier)
        s.repeats = true
        s.interval = TimeInterval(max(1, minutes) * 60)
        s.tolerance = s.interval / 4
        s.qualityOfService = .utility
        let work = self.work
        s.schedule { completion in
            Task { @MainActor in
                await work()
                completion(.finished)
            }
        }
        scheduler = s
    }

    public func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }
}
