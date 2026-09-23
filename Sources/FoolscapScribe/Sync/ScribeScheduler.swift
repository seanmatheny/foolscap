import Foundation

/// Periodic sync through `NSBackgroundActivityScheduler`, so macOS can
/// coalesce it with other background work and defer it on battery. Nothing
/// runs while the app is closed; Sync Now bypasses the schedule.
@MainActor
final class ScribeScheduler {
    static let identifier = "com.seanmatheny.foolscap.scribe-sync"
    private var scheduler: NSBackgroundActivityScheduler?
    private let work: @MainActor () async -> Void

    init(work: @escaping @MainActor () async -> Void) { self.work = work }

    var isRunning: Bool { scheduler != nil }

    func start(minutes: Int) {
        stop()
        let s = NSBackgroundActivityScheduler(identifier: Self.identifier)
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

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
    }
}
