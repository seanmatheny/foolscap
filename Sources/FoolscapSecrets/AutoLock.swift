import AppKit
import Foundation

/// When an unlocked vault locks itself: after `lockAfter` without a key or mouse
/// event in Foolscap. Pure, so the clock can be faked in tests.
public struct IdleLockPolicy: Sendable, Equatable {
    public var lockAfter: TimeInterval
    public var lastActivity: Date

    public init(lockAfter: TimeInterval, lastActivity: Date) { self.lockAfter = lockAfter; self.lastActivity = lastActivity }

    public func shouldLock(at now: Date) -> Bool { now.timeIntervalSince(lastActivity) >= lockAfter }
    public func remaining(at now: Date) -> TimeInterval { max(0, lockAfter - now.timeIntervalSince(lastActivity)) }
    public var locksAt: Date { lastActivity.addingTimeInterval(lockAfter) }
}

/// Watches for idleness, sleep and the screen locking while the vault is open,
/// and calls `onLock` once. `start` after unlocking, `stop` on lock.
@MainActor
public final class AutoLock {
    public var lockAfter: TimeInterval {
        didSet { policy.lockAfter = lockAfter }
    }
    public var onLock: (() -> Void)?
    private let clock: () -> Date
    private(set) var policy: IdleLockPolicy
    private var monitor: Any?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    public private(set) var isRunning = false

    public init(lockAfter: TimeInterval, clock: @escaping () -> Date = Date.init) {
        self.lockAfter = lockAfter
        self.clock = clock
        policy = IdleLockPolicy(lockAfter: lockAfter, lastActivity: clock())
    }

    /// When the vault will lock if nothing happens; nil while stopped.
    public var locksAt: Date? { isRunning ? policy.locksAt : nil }

    public func noteActivity() { policy.lastActivity = clock() }

    /// The pure decision, for tests and for the timer.
    public func shouldLock(at now: Date) -> Bool { policy.shouldLock(at: now) }

    public func start() {
        stop()
        isRunning = true
        policy.lastActivity = clock()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .magnify]) { [weak self] event in
            self?.noteActivity()
            return event
        }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fire() }
            })
        }
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        })
    }

    public func stop() {
        isRunning = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observers = []
        for o in distributedObservers { DistributedNotificationCenter.default().removeObserver(o) }
        distributedObservers = []
    }

    func tick() {
        guard isRunning, shouldLock(at: clock()) else { return }
        fire()
    }

    private func fire() {
        guard isRunning else { return }
        stop()
        onLock?()
    }
}
