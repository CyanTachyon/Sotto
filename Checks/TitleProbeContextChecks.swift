#if TITLE_PROBE_CONTEXT_CHECKS
import Foundation
import CoreGraphics

@main struct TitleProbeContextChecks {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static let window = ProbeWindow(id: 17, pid: 42, bounds: CGRect(x: 50, y: 80, width: 900, height: 700))
    private static func require(_ condition: Bool, _ description: String) throws {
        if !condition { throw Failure(description: description) }
    }
    private static func ready() throws -> ProbeContextGate {
        var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
        try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 100) == .paused, "first observation must wait")
        try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 100.8) == .visibleReady, "stable target should become ready")
        return gate
    }
    static func main() {
        let checks: [(String, () throws -> Void)] = [
            ("requires full 0.8 second stability interval", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 100) == .paused, "first observation")
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 100.799) == .paused, "deadline not reached")
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 100.8) == .visibleReady, "exact deadline")
            }),
            ("continuous observations do not restart stability", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                for t in [100.0, 100.1, 100.3, 100.6] { _ = gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: t) }
                try require(gate.update(window: window, foreground: .probe, spaceEpoch: 1, now: 100.8) == .visibleReady, "safe foreground handoff should retain stability")
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 101) == .visibleReady, "ready should remain ready")
            }),
            ("unrelated foreground pauses immediately", {
                var gate = try ready()
                try require(gate.update(window: window, foreground: .unrelated, spaceEpoch: 1, now: 101) == .paused, "unrelated foreground")
                try require(!gate.captureAllowed(window: window, foreground: .unrelated, spaceEpoch: 1, ownPanelIsKey: true), "own-key flag must not override unrelated app")
            }),
            ("return from another app must stabilize again", {
                var gate = try ready()
                _ = gate.update(window: window, foreground: .unrelated, spaceEpoch: 1, now: 101)
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 102) == .paused, "return starts a new interval")
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 102.79) == .paused, "return deadline")
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 102.8) == .visibleReady, "return stabilized")
            }),
            ("missing window cancels readiness", {
                var gate = try ready()
                try require(gate.update(window: nil, foreground: .selectedApp, spaceEpoch: 1, now: 101) == .paused, "missing window")
                try require(!gate.captureAllowed(window: window, foreground: .selectedApp, spaceEpoch: 1), "old snapshot is not authorization")
            }),
            ("different window ID is never adopted", {
                var gate = try ready()
                let other = ProbeWindow(id: 18, pid: window.pid, bounds: window.bounds)
                try require(gate.update(window: other, foreground: .selectedApp, spaceEpoch: 1, now: 101) == .paused, "wrong ID")
                try require(gate.update(window: other, foreground: .selectedApp, spaceEpoch: 1, now: 200) == .paused, "wrong ID cannot stabilize")
            }),
            ("same window ID in another process is rejected", {
                var gate = try ready()
                let other = ProbeWindow(id: window.id, pid: 43, bounds: window.bounds)
                try require(gate.update(window: other, foreground: .selectedApp, spaceEpoch: 1, now: 101) == .paused, "wrong PID")
                try require(!gate.captureAllowed(window: other, foreground: .probe, spaceEpoch: 1), "wrong PID capture")
            }),
            ("Space epoch changes pause without geometry changes", {
                var gate = try ready()
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 2, now: 101) == .paused, "Space change")
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 2, now: 101.8) == .visibleReady, "new Space stable")
                try require(!gate.captureAllowed(window: window, foreground: .selectedApp, spaceEpoch: 1), "old Space capture")
            }),
            ("window movement pauses and updates the stable snapshot", {
                var gate = try ready()
                let moved = ProbeWindow(id: window.id, pid: window.pid, bounds: window.bounds.offsetBy(dx: 2, dy: 0))
                try require(gate.update(window: moved, foreground: .probe, spaceEpoch: 1, now: 101) == .paused, "movement")
                try require(gate.update(window: moved, foreground: .probe, spaceEpoch: 1, now: 101.8) == .visibleReady, "moved window stable")
                try require(!gate.captureAllowed(window: window, foreground: .probe, spaceEpoch: 1), "old bounds capture")
            }),
            ("window resize pauses immediately", {
                var gate = try ready()
                let resized = ProbeWindow(id: window.id, pid: window.pid, bounds: CGRect(x: 50, y: 80, width: 901, height: 700))
                try require(gate.update(window: resized, foreground: .selectedApp, spaceEpoch: 1, now: 101) == .paused, "resize")
                try require(!gate.captureAllowed(window: resized, foreground: .selectedApp, spaceEpoch: 1), "resize deadline not yet satisfied")
            }),
            ("initial picker handoff can stay visible without authorizing capture", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100)
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100.8) == .visibleReady, "initial handoff visibility")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 101) == .visibleReady, "showing must not consume handoff")
                try require(!gate.captureAllowed(window: window, foreground: .picker, spaceEpoch: 1), "visibility alone cannot authorize capture")
                try require(gate.captureAllowed(window: window, foreground: .picker, spaceEpoch: 1, ownPanelIsKey: true), "real keyed own panel can authorize capture")
            }),
            ("initial picker y80 to y33 transition can settle before first display", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                let settled = ProbeWindow(id: window.id, pid: window.pid, bounds: CGRect(x: 50, y: 33, width: 900, height: 700))
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100) == .paused, "first y80 observation")
                try require(gate.update(window: settled, foreground: .picker, spaceEpoch: 1, now: 100.2) == .paused, "y33 resets stability")
                try require(gate.update(window: settled, foreground: .picker, spaceEpoch: 1, now: 100.8) == .paused, "old y80 deadline cannot authorize new geometry")
                try require(gate.update(window: settled, foreground: .picker, spaceEpoch: 1, now: 101) == .visibleReady, "settled y33 handoff becomes visible")
                try require(!gate.captureAllowed(window: settled, foreground: .picker, spaceEpoch: 1), "settling does not authorize capture")
            }),
            ("first picker tick can lack the selected window", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                try require(gate.update(window: nil, foreground: .picker, spaceEpoch: 1, now: 100) == .paused, "transient missing first window")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100.2) == .paused, "first actual window starts stability")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 101) == .visibleReady, "same selected window can settle")
                try require(!gate.captureAllowed(window: window, foreground: .picker, spaceEpoch: 1), "nil recovery cannot grant capture")
            }),
            ("missing window during initial settling restarts the full deadline", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100)
                _ = gate.update(window: nil, foreground: .picker, spaceEpoch: 1, now: 100.3)
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 101) == .paused, "reappearance must not reuse pre-gap stability")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 101.8) == .visibleReady, "fresh stability restores initial display")
            }),
            ("wrong ID or PID revokes handoff before first display", {
                for wrong in [ProbeWindow(id: 18, pid: window.pid, bounds: window.bounds), ProbeWindow(id: window.id, pid: 43, bounds: window.bounds)] {
                    var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                    _ = gate.update(window: nil, foreground: .picker, spaceEpoch: 1, now: 100)
                    try require(gate.update(window: wrong, foreground: .picker, spaceEpoch: 1, now: 100.2) == .paused, "identity mismatch")
                    try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 101) == .paused, "correct identity cannot reuse revoked handoff")
                    try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 102) == .paused, "revocation persists")
                }
            }),
            ("known Space epoch change revokes even an undisplayed handoff", {
                let initialWindows: [ProbeWindow?] = [nil, window]
                for initialWindow in initialWindows {
                    var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                    _ = gate.update(window: initialWindow, foreground: .picker, spaceEpoch: 1, now: 100)
                    try require(gate.update(window: window, foreground: .picker, spaceEpoch: 2, now: 100.2) == .paused, "Space changed before display")
                    try require(gate.update(window: window, foreground: .picker, spaceEpoch: 2, now: 102) == .paused, "new Space cannot reuse initial handoff")
                }
            }),
            ("missing window after first display ends picker handoff", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100.8)
                _ = gate.update(window: nil, foreground: .picker, spaceEpoch: 1, now: 101)
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 102) == .paused, "displayed handoff must use strict missing-window rule")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 103) == .paused, "picker cannot recover after prior display")
            }),
            ("picker handoff ends after own panel becomes key", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100.8, ownPanelIsKey: true)
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 101) == .paused, "losing key after interaction must pause")
            }),
            ("picker cannot reacquire after unrelated app interruption", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100)
                _ = gate.update(window: window, foreground: .unrelated, spaceEpoch: 1, now: 100.2)
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 200) == .paused, "expired handoff")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 201, ownPanelIsKey: true) == .paused, "keyed panel starts stability")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 201.8, ownPanelIsKey: true) == .visibleReady, "keyed panel can restore")
            }),
            ("picker handoff does not survive Space changes", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100.8)
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 2, now: 101) == .paused, "handoff Space change")
                try require(gate.update(window: window, foreground: .picker, spaceEpoch: 2, now: 200) == .paused, "picker alone cannot restore")
            }),
            ("picker handoff does not survive geometry changes", {
                var gate = ProbeContextGate(expectedID: window.id, pid: window.pid)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100)
                _ = gate.update(window: window, foreground: .picker, spaceEpoch: 1, now: 100.8)
                let moved = ProbeWindow(id: window.id, pid: window.pid, bounds: window.bounds.offsetBy(dx: 1, dy: 0))
                try require(gate.update(window: moved, foreground: .picker, spaceEpoch: 1, now: 101) == .paused, "handoff moved")
                try require(gate.update(window: moved, foreground: .picker, spaceEpoch: 1, now: 200) == .paused, "picker cannot restore moved handoff")
            }),
            ("capture checks fresh context without advancing state", {
                let gate = try ready()
                try require(gate.captureAllowed(window: window, foreground: .selectedApp, spaceEpoch: 1), "selected app allowed")
                try require(gate.captureAllowed(window: window, foreground: .probe, spaceEpoch: 1), "probe allowed")
                try require(!gate.captureAllowed(window: nil, foreground: .probe, spaceEpoch: 1), "missing capture target")
                try require(!gate.captureAllowed(window: window, foreground: .unrelated, spaceEpoch: 1, ownPanelIsKey: true), "unrelated must never capture")
                try require(!gate.captureAllowed(window: window, foreground: .picker, spaceEpoch: 1), "picker without key")
                try require(gate.state == .visibleReady, "pure capture predicate cannot mutate state")
            }),
            ("invalid geometry and nonmonotonic time fail closed", {
                var gate = try ready()
                let empty = ProbeWindow(id: window.id, pid: window.pid, bounds: .zero)
                try require(gate.update(window: empty, foreground: .selectedApp, spaceEpoch: 1, now: 101) == .paused, "empty bounds")
                _ = gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 102)
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: 101) == .paused, "clock moved backward")
                try require(gate.update(window: window, foreground: .selectedApp, spaceEpoch: 1, now: .nan) == .paused, "invalid timestamp")
            })
        ]
        var failures = 0
        for (name, run) in checks {
            do { try run(); print("PASS " + name) }
            catch { failures += 1; print("FAIL " + name + ": " + String(describing: error)) }
        }
        print("Title probe context checks: \(checks.count); failures: \(failures). Synthetic data only.")
        exit(failures == 0 ? 0 : 1)
    }
}
#endif
