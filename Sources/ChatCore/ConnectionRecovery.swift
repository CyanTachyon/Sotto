import Foundation

/// One initial attempt and three bounded retries. UI polling only checks the deadline;
/// a successful connection stays idle until its account is explicitly changed.
public struct ConnectionRecovery {
    public private(set) var attemptCount = 0
    public private(set) var nextAttemptAt: Date?
    public private(set) var isRunning = false
    public private(set) var isConnected = false
    private var lastAttemptAt: Date?
    private var isSuspended = false
    private let delays: [TimeInterval] = [2, 8, 30]

    public init(now: Date = Date()) { nextAttemptAt = now }

    public mutating func begin(now: Date = Date(), userInitiated: Bool = false) -> Bool {
        guard !isRunning else { return false }
        if userInitiated { attemptCount = 0; isConnected = false; isSuspended = false; nextAttemptAt = now }
        guard !isSuspended, !isConnected, let deadline = nextAttemptAt, now >= deadline else { return false }
        attemptCount += 1; lastAttemptAt = now; nextAttemptAt = nil; isRunning = true
        return true
    }

    public mutating func succeeded() {
        isRunning = false; isConnected = true; nextAttemptAt = nil
    }

    public mutating func failed(now: Date = Date()) {
        guard isRunning else { return }
        isRunning = false; isConnected = false
        nextAttemptAt = attemptCount <= delays.count ? now.addingTimeInterval(delays[attemptCount - 1]) : nil
    }

    /// Foreground/wake events can recover an exhausted cycle, but cannot turn the
    /// periodic timer or repeated window clicks into unlimited database reads.
    public mutating func resume(now: Date = Date()) {
        guard !isSuspended, !isRunning, !isConnected else { return }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < 60 { return }
        attemptCount = 0; nextAttemptAt = now
    }

    public mutating func suspend() { nextAttemptAt = nil; isRunning = false; isConnected = false; isSuspended = true }
}
