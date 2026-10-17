import Foundation
import SottoCore

func checkConnectionRecovery() throws {
    func require(_ value: Bool, _ message: String) throws {
        if !value { throw ChatError.invalid(message) }
    }
    let start = Date(timeIntervalSince1970: 1_000)
    var recovery = ConnectionRecovery(now: start)
    try require(recovery.begin(now: start), "startup must connect automatically")
    try require(!recovery.begin(now: start, userInitiated: true), "manual clicks must not overlap an active connection")
    recovery.failed(now: start)
    try require(!recovery.begin(now: start.addingTimeInterval(1)), "timer must respect retry backoff")
    recovery.resume(now: start.addingTimeInterval(1))
    try require(!recovery.begin(now: start.addingTimeInterval(1)), "repeated foreground events must not bypass backoff")
    try require(recovery.begin(now: start.addingTimeInterval(2)), "first silent retry")
    recovery.failed(now: start.addingTimeInterval(2))
    try require(recovery.begin(now: start.addingTimeInterval(10)), "second silent retry")
    recovery.failed(now: start.addingTimeInterval(10))
    try require(recovery.begin(now: start.addingTimeInterval(40)), "last bounded silent retry")
    recovery.failed(now: start.addingTimeInterval(40))
    try require(recovery.attemptCount == 4 && recovery.nextAttemptAt == nil, "failures must stop after four attempts")
    try require(!recovery.begin(now: start.addingTimeInterval(5_000)), "timer alone must never restart an exhausted cycle")
    recovery.resume(now: start.addingTimeInterval(45))
    try require(recovery.nextAttemptAt == nil, "foreground flapping must not restart exhausted retries")
    recovery.resume(now: start.addingTimeInterval(100))
    try require(recovery.begin(now: start.addingTimeInterval(100)), "a later unlock/foreground event can recover")
    recovery.succeeded()
    try require(recovery.attemptCount == 0, "a healthy connection must reset the retry budget")
    recovery.resume(now: start.addingTimeInterval(5_000))
    try require(!recovery.begin(now: start.addingTimeInterval(5_000)), "healthy connections must never re-read databases on polling")
    try require(recovery.begin(now: start.addingTimeInterval(5_000), userInitiated: true), "explicit verification remains available")
    recovery.succeeded(); recovery.suspend()
    recovery.resume(now: start.addingTimeInterval(10_000))
    try require(!recovery.begin(now: start.addingTimeInterval(10_000)), "deleting credentials must suspend background attempts")
    try require(recovery.begin(now: start.addingTimeInterval(10_000), userInitiated: true), "explicit reconnect resumes a suspended connection")
    var suspended = ConnectionRecovery(now: start); _ = suspended.begin(now: start); suspended.failed(now: start); suspended.suspend()
    suspended.resetForReconnect(now: start.addingTimeInterval(100))
    try require(!suspended.begin(now: start.addingTimeInterval(100)), "query-failure reset must preserve an explicit credential suspension")
}
