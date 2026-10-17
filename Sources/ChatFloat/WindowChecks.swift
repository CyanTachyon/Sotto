import AppKit
import CoreGraphics
import ChatCore

/// Pure focus/WindowServer matching checks; no applications or screen contents are queried.
func focusedWindowTargetChecks() -> [String: Bool] {
    typealias Resolver = WeChatWindowTargetResolver
    let process = Resolver.Process(pid: 101, launchDate: Date(timeIntervalSince1970: 100))
    let main = WeChatWindow(id: 1, pid: 101, bounds: CGRect(x: 100, y: 50, width: 900, height: 700))
    let chat = WeChatWindow(id: 2, pid: 101, bounds: CGRect(x: 340, y: 160, width: 650, height: 520))
    var checks: [String: Bool] = [:]
    var resolver = Resolver()
    checks["focused_main_ignores_cg_order"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: main.bounds, windows: [chat, main]) == main
    checks["focused_detached_chat_switches_target"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [main, chat]) == chat
    checks["helper_retains_verified_ax_window_despite_cg_order"] = resolver.resolve(process: process, foreground: .companion, focusedBounds: chat.bounds, focusContinuityVerified: true, windows: [main, chat]) == chat
    checks["helper_never_adopts_different_focused_window"] = resolver.resolve(process: process, foreground: .companion, focusedBounds: main.bounds, focusContinuityVerified: false, windows: [main, chat]) == nil
    checks["helper_cannot_start_from_cg_order"] = resolver.resolve(process: process, foreground: .companion, focusedBounds: chat.bounds, focusContinuityVerified: true, windows: [chat]) == nil
    _ = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [main, chat])
    checks["reused_cg_id_requires_same_ax_object"] = resolver.resolve(process: process, foreground: .companion, focusedBounds: chat.bounds, focusContinuityVerified: false, windows: [chat]) == nil
    let overlap = WeChatWindow(id: 3, pid: 101, bounds: chat.bounds)
    checks["same_geometry_is_ambiguous"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [chat, overlap]) == nil
    let almostOverlap = WeChatWindow(id: 3, pid: 101, bounds: chat.bounds.offsetBy(dx: 1, dy: 1))
    checks["tolerance_never_selects_closest_of_two"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [chat, almostOverlap]) == nil
    checks["missing_ax_focus_never_falls_back_to_single_cg_window"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: nil, windows: [chat]) == nil
    let otherPID = WeChatWindow(id: chat.id, pid: 102, bounds: chat.bounds)
    checks["cg_owner_must_match_focused_process"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [otherPID]) == nil
    _ = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [chat])
    checks["closed_retained_window_pauses"] = resolver.resolve(process: process, foreground: .companion, focusedBounds: chat.bounds, focusContinuityVerified: true, windows: [main]) == nil
    _ = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [chat])
    let relaunched = Resolver.Process(pid: process.pid, launchDate: process.launchDate.addingTimeInterval(1))
    checks["process_relaunch_cannot_reuse_retained_target"] = resolver.resolve(process: relaunched, foreground: .companion, focusedBounds: chat.bounds, focusContinuityVerified: true, windows: [chat]) == nil
    _ = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [chat])
    let moved = WeChatWindow(id: chat.id, pid: chat.pid, bounds: chat.bounds.offsetBy(dx: 10, dy: 20))
    checks["same_ax_object_can_update_live_geometry"] = resolver.resolve(process: process, foreground: .companion, focusedBounds: moved.bounds, focusContinuityVerified: true, windows: [main, moved]) == moved
    _ = resolver.resolve(process: process, foreground: .unrelated, focusedBounds: moved.bounds, windows: [moved])
    checks["unrelated_foreground_revokes_retention"] = resolver.resolve(process: process, foreground: .companion, focusedBounds: moved.bounds, focusContinuityVerified: true, windows: [moved]) == nil
    checks["small_ax_rounding_error_is_allowed"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds.offsetBy(dx: 1.5, dy: -1.5), windows: [chat]) == chat
    checks["larger_geometry_disagreement_pauses"] = resolver.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds.offsetBy(dx: 3, dy: 0), windows: [chat]) == nil
    // The companion rejects auxiliary windows before target retention. Another
    // provider used by settings/status must not seed its cleared conversation target.
    var companion = Resolver(), generic = Resolver()
    _ = companion.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [chat])
    checks["auxiliary_focus_revokes_companion_target"] = companion.resolve(process: process, foreground: .weChat,
        focusedBounds: main.bounds, targetIsEligible: false, windows: [main, chat]) == nil && companion.confirmed == nil
    _ = generic.resolve(process: process, foreground: .weChat, focusedBounds: main.bounds, windows: [main, chat])
    checks["general_positioning_does_not_restore_chat_retention"] = companion.resolve(process: process, foreground: .companion,
        focusedBounds: chat.bounds, focusContinuityVerified: true, windows: [main, chat]) == nil && generic.confirmed == main
    checks["return_to_known_chat_reestablishes_target"] = companion.resolve(process: process, foreground: .weChat,
        focusedBounds: chat.bounds, targetIsEligible: true, windows: [main, chat]) == chat
    checks["companion_foreground_also_rejects_new_auxiliary_metadata"] = companion.resolve(process: process, foreground: .companion,
        focusedBounds: chat.bounds, focusContinuityVerified: true, targetIsEligible: false, windows: [chat]) == nil && companion.confirmed == nil
    _ = companion.resolve(process: process, foreground: .weChat, focusedBounds: chat.bounds, windows: [chat])
    checks["off_space_chat_cannot_use_retained_target"] = companion.resolve(process: process, foreground: .weChat,
        focusedBounds: chat.bounds, windows: []) == nil
    checks["return_from_other_space_requires_fresh_wechat_focus"] = companion.resolve(process: process, foreground: .companion,
        focusedBounds: chat.bounds, focusContinuityVerified: true, windows: [chat]) == nil
    checks["visible_chat_recovers_after_space_switch"] = companion.resolve(process: process, foreground: .weChat,
        focusedBounds: chat.bounds, windows: [chat]) == chat
    return checks
}

#if FOCUSED_WINDOW_TARGET_CHECKS
@main private struct FocusedWindowTargetChecksMain {
    static func main() {
        let checks = focusedWindowTargetChecks()
        let passed = checks.values.allSatisfy { $0 }
        let output: [String: Any] = ["checks": checks, "passed": passed, "syntheticOnly": true, "weChatInputEvents": 0]
        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            FileHandle.standardOutput.write(data)
        }
        exit(passed ? 0 : 2)
    }
}
#else
/// Exercise the same resolver with two real windows belonging only to this test
/// process. AppKit's key window supplies fixture focus; no WeChat AX query is made.
@MainActor private func ownWindowTargetChecks(output: URL) async -> [String: Bool] {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let origin = screen.visibleFrame.origin
    let first = NSWindow(contentRect: CGRect(x: origin.x + 30, y: origin.y + 40, width: 540, height: 440),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let second = NSWindow(contentRect: CGRect(x: origin.x + 130, y: origin.y + 100, width: 600, height: 480),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    first.title = "合成主窗口"; second.title = "合成独立会话窗口"
    first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
    for window in [first, second] {
        window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
    }
    defer { first.close(); second.close() }
    first.orderFront(nil); second.orderFront(nil); NSApp.activate()
    let process = WeChatWindowTargetResolver.Process(pid: getpid(), launchDate: NSRunningApplication.current.launchDate ?? Date())
    var resolver = WeChatWindowTargetResolver()
    var observations: [[String: Any]] = []
    func rectangle(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
    func windows() -> [WeChatWindow] {
        let ids = [first.windowNumber, second.windowNumber]
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard (row[kCGWindowOwnerPID as String] as? Int32) == getpid(),
                  let id = row[kCGWindowNumber as String] as? Int, ids.contains(id),
                  let box = row[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: box as CFDictionary) else { return nil }
            return WeChatWindow(id: UInt32(id), pid: getpid(), bounds: bounds)
        }
    }
    func windowBounds(_ window: NSWindow) -> CGRect {
        let top = NSScreen.screens[0].frame.maxY
        return CGRect(x: window.frame.minX, y: top - window.frame.maxY, width: window.frame.width, height: window.frame.height)
    }
    func focusedBounds() -> CGRect? {
        guard let key = NSApp.keyWindow, key === first || key === second else { return nil }
        return windowBounds(key)
    }
    typealias Observation = (settled: Bool, focus: CGRect?, windows: [WeChatWindow])
    func settledObservation(expected: NSWindow) async -> Observation {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var previous: [WeChatWindow] = []
        var stableCount = 0
        while true {
            let current = windows().sorted { $0.id < $1.id }
            let focus = focusedBounds()
            // Check actual fixture readiness independently of the resolver. A key
            // NSWindow can still have transitional/scaled CG bounds during a Space
            // animation; that mismatch should not be hidden by a larger tolerance.
            let geometryReady = [first, second].allSatisfy { window in
                guard window.isOnActiveSpace, let cg = current.first(where: { $0.id == UInt32(window.windowNumber) }) else { return false }
                let expected = windowBounds(window)
                return abs(cg.bounds.minX - expected.minX) <= 0.5 && abs(cg.bounds.minY - expected.minY) <= 0.5 &&
                    abs(cg.bounds.width - expected.width) <= 0.5 && abs(cg.bounds.height - expected.height) <= 0.5
            }
            let ready = NSApp.isActive && NSApp.keyWindow === expected && focus != nil && current.count == 2 && geometryReady
            stableCount = ready && current == previous ? stableCount + 1 : 0
            if stableCount >= 2 { return (true, focus, current) }
            if ProcessInfo.processInfo.systemUptime >= deadline { return (false, focus, current) }
            previous = current
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    func record(_ stage: String, expected: NSWindow, observation: Observation, selected: WeChatWindow?) {
        observations.append(["stage": stage, "uptime": ProcessInfo.processInfo.systemUptime,
            "fixtureSettled": observation.settled,
            "appActive": NSApp.isActive, "activationPolicy": NSApp.activationPolicy().rawValue,
            "keyWindowID": NSApp.keyWindow?.windowNumber ?? -1, "expectedWindowID": expected.windowNumber,
            "expectedIsKey": expected.isKeyWindow, "expectedCanBecomeKey": expected.canBecomeKey,
            "expectedOnActiveSpace": expected.isOnActiveSpace, "expectedAppKitFrame": rectangle(expected.frame),
            "focusedBounds": observation.focus.map(rectangle) ?? [:], "selectedWindowID": selected.map { Int($0.id) } ?? -1,
            "cgWindows": observation.windows.map { ["id": Int($0.id), "pid": Int($0.pid), "bounds": rectangle($0.bounds)] }])
    }
    first.makeKeyAndOrderFront(nil)
    let firstObservation = await settledObservation(expected: first)
    let selectedFirst = resolver.resolve(process: process, foreground: .weChat, focusedBounds: firstObservation.focus, windows: firstObservation.windows)
    record("first", expected: first, observation: firstObservation, selected: selectedFirst)
    second.makeKeyAndOrderFront(nil)
    let secondObservation = await settledObservation(expected: second)
    let selectedSecond = resolver.resolve(process: process, foreground: .weChat, focusedBounds: secondObservation.focus, windows: secondObservation.windows)
    record("second", expected: second, observation: secondObservation, selected: selectedSecond)
    second.setFrame(first.frame, display: true)
    let overlapObservation = await settledObservation(expected: second)
    let ambiguous = resolver.resolve(process: process, foreground: .weChat, focusedBounds: overlapObservation.focus, windows: overlapObservation.windows)
    record("overlapping", expected: second, observation: overlapObservation, selected: ambiguous)
    if let data = try? JSONSerialization.data(withJSONObject: ["syntheticOnly": true, "focusSource": "AppKit.keyWindow", "observations": observations], options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("own-window-target-observations.json"))
    }
    return ["own_fixture_current_space_and_geometry_settle": firstObservation.settled && secondObservation.settled && overlapObservation.settled,
            "own_key_window_maps_to_matching_cg_window": firstObservation.settled && selectedFirst?.id == UInt32(first.windowNumber),
            "own_key_window_switch_updates_cg_target": secondObservation.settled && selectedSecond?.id == UInt32(second.windowNumber),
            "own_overlapping_same_geometry_windows_are_rejected": overlapObservation.settled && overlapObservation.focus != nil && overlapObservation.windows.count == 2 && ambiguous == nil]
}

/// Drive the actual companion NSPanel with two real windows owned by this test.
/// Fixture focus and geometry come from AppKit/WindowServer; gaps and Space
/// notifications are injected explicitly without operating another application.
@MainActor private func ownWindowExpansionChecks(output: URL) async -> [String: Bool] {
    let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let first = NSWindow(contentRect: .init(x: area.minX + 25, y: area.minY + 25, width: 560, height: 500),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let second = NSWindow(contentRect: .init(x: area.minX + 160, y: area.minY + 85, width: 600, height: 520),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let standalone = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    for (window, title) in [(first, "合成聊天 A"), (second, "合成聊天 B")] {
        window.title = title; window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        window.orderFront(nil)
    }
    standalone.isReleasedWhenClosed = false
    NSApp.activate()
    defer { first.close(); second.close(); standalone.close() }
    let model = AppModel(testMode: true)
    model.autoFollow = false; model.companionEnabled = true
    model.question = "合成窗口切换草稿"; model.streamingText = "合成部分回答"; model.busy = true
    do {
        let snapshot = try SyntheticScenario.snapshot()
        let answer = try GroundedAnswer.validate(SyntheticScenario.narrative(snapshot), snapshot: snapshot)
        model.turns = [AnswerTurn(question: "合成历史问题", answer: answer, snapshot: snapshot)]
    } catch { return ["own_expansion_fixture_setup": false] }
    let preservedTurns = model.turns.map(\.id)
    var instant: TimeInterval = 500
    var relevant = true
    var target: WeChatWindow?
    let controller = CompanionController(model: model, fixtureWindow: standalone, targetProvider: { target },
        relevantForeground: { relevant }, now: { instant }, observeWorkspace: false, observeFocus: false, reducedMotion: { true })
    defer { controller.hide() }
    var checks: [String: Bool] = [:], observations: [[String: Any]] = []
    var allFocusSamplesReady = true
    func rectangle(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
    func record(_ stage: String) {
        observations.append(["stage": stage, "keyWindowID": NSApp.keyWindow?.windowNumber ?? -1,
            "targetID": target.map { Int($0.id) } ?? -1, "targetPID": target.map { Int($0.pid) } ?? -1,
            "expanded": model.companionExpanded, "panelVisible": controller.panel.isVisible,
            "bubbleVisible": controller.bubble.isVisible, "panelFrame": rectangle(controller.panel.frame)])
    }
    func focus(_ window: NSWindow) async {
        window.makeKeyAndOrderFront(nil)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        let primaryTop = NSScreen.screens[0].frame.maxY
        while true {
            let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let row = rows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() &&
                ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
            if NSApp.keyWindow === window, window.isOnActiveSpace,
               let box = row?[kCGWindowBounds as String] as? [String: Any],
               let bounds = CGRect(dictionaryRepresentation: box as CFDictionary),
               abs(bounds.minX - window.frame.minX) <= 0.5,
               abs(bounds.minY - (primaryTop - window.frame.maxY)) <= 0.5,
               abs(bounds.width - window.frame.width) <= 0.5,
               abs(bounds.height - window.frame.height) <= 0.5 {
                target = WeChatWindow(id: UInt32(window.windowNumber), pid: getpid(), bounds: bounds)
                return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { allFocusSamplesReady = false; target = nil; return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    func settle() { instant += 0.25; controller.update() }
    await focus(first); controller.update(); settle()
    checks["own_explicit_open_binds_native_window_a"] = controller.present() && controller.panel.isVisible && model.companionExpanded
    let frameA = controller.panel.frame
    await focus(second); controller.update(); record("a_to_b_immediate")
    checks["own_a_to_b_hides_before_moving_old_panel"] = !controller.panel.isVisible && !model.companionExpanded && controller.panel.frame == frameA
    settle(); record("b_stable")
    checks["own_b_only_shows_bubble_after_a_expansion"] = controller.bubble.isVisible && !controller.panel.isVisible && !model.companionExpanded
    await focus(first); controller.update(); settle(); record("return_a")
    checks["own_return_to_a_requires_another_click"] = controller.bubble.isVisible && !controller.panel.isVisible && !model.companionExpanded
    _ = controller.present()
    target = nil; controller.update(); record("a_to_nil")
    checks["own_focus_gap_hides_but_keeps_a_anchor"] = !controller.panel.isVisible && model.companionExpanded
    await focus(second); controller.update(); settle(); record("a_nil_b")
    checks["own_a_nil_b_cannot_carry_expansion"] = controller.bubble.isVisible && !controller.panel.isVisible && !model.companionExpanded
    checks["own_explicit_b_open_rebinds_native_window"] = controller.present() && controller.panel.isVisible
    second.setFrame(second.frame.offsetBy(dx: 20, dy: 15), display: true)
    await focus(second); controller.update(); record("same_b_move")
    checks["own_same_window_move_preserves_expansion"] = controller.panel.isVisible && model.companionExpanded
    var resized = second.frame; resized.size.width += 20; resized.size.height -= 15
    second.setFrame(resized, display: true)
    await focus(second); controller.update(); record("same_b_resize")
    checks["own_same_window_resize_preserves_expansion"] = controller.panel.isVisible && model.companionExpanded
    relevant = false; target = nil; controller.update()
    relevant = true; await focus(second); controller.update(); settle(); record("same_b_after_foreground_gap")
    checks["own_same_window_after_foreground_gap_restores_expansion"] = controller.panel.isVisible && model.companionExpanded
    controller.activeSpaceDidChange(); target = nil; controller.update()
    await focus(second); controller.update(); instant += 0.5; controller.update(); record("same_b_after_space_event")
    checks["own_same_window_after_space_event_restores_expansion"] = controller.panel.isVisible && model.companionExpanded
    // Calibration can temporarily write false and later restore true. That Boolean
    // is insufficient to rebind the previous panel to another native window.
    model.companionExpanded = false; controller.update()
    await focus(first); model.companionExpanded = true; controller.update(); settle(); record("restored_boolean_on_other_window")
    checks["own_restored_expansion_boolean_cannot_rebind_window"] = controller.bubble.isVisible && !controller.panel.isVisible && !model.companionExpanded
    _ = controller.present()
    await focus(second)
    checks["own_explicit_present_uses_latest_target_without_prior_update"] = controller.present() && controller.panel.isVisible && model.companionExpanded
    controller.update(); record("explicit_present_latest_target")
    checks["own_latest_explicit_anchor_survives_next_update"] = controller.panel.isVisible && model.companionExpanded
    if let boundTarget = target {
        target = .init(id: boundTarget.id, pid: boundTarget.pid + 1, bounds: boundTarget.bounds)
        controller.update()
        checks["window_identity_includes_pid"] = !controller.panel.isVisible && !model.companionExpanded
    } else { checks["window_identity_includes_pid"] = false }
    checks["window_collapse_does_not_directly_clear_draft_answer_or_busy_state"] = model.question == "合成窗口切换草稿" &&
        model.streamingText == "合成部分回答" && model.turns.map(\.id) == preservedTurns && model.busy
    checks["own_expansion_focus_samples_ready"] = allFocusSamplesReady
    if let data = try? JSONSerialization.data(withJSONObject: ["syntheticOnly": true, "weChatInputEvents": 0,
        "focusSource": "own AppKit.keyWindow + WindowServer metadata", "spaceAndForegroundGapsInjected": true,
        "observations": observations], options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("own-window-expansion-observations.json"))
    }
    return checks
}

extension AppDelegate {
    func checkWindowOrdering(output: URL) {
        Task { @MainActor in
            var lines: [String] = []
            func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            // Window-order checks must never activate or otherwise operate WeChat.
            guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { exit(2) }
            @MainActor func aboveOther() -> Bool? {
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String: Any]] ?? []
                let relevant = windows.filter { row in
                    guard let bounds = row[kCGWindowBounds as String] as? [String:Any] else { return false }
                    return (bounds["Width"] as? Double ?? 0)>100 && (bounds["Height"] as? Double ?? 0)>100
                }
                guard let own = relevant.firstIndex(where:{ ($0[kCGWindowNumber as String] as? Int)==panel.windowNumber }),
                      let theirs = relevant.firstIndex(where:{ ($0[kCGWindowOwnerPID as String] as? Int32)==other.processIdentifier }) else { return nil }
                return own < theirs
            }
            model.pinned = true; showPanel(); await pause(1)
            other.activate(); await pause(2)
            let pinnedAbove = aboveOther() == true && NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier
            lines.append("\(pinnedAbove ? "PASS" : "FAIL") pinned stays above while other app foreground")
            model.pinned = false; showPanel(); await pause(1)
            other.activate(); await pause(2)
            let normalBehind = aboveOther() == false && NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier
            lines.append("\(normalBehind ? "PASS" : "FAIL") unpinned is behind other foreground application")
            await pause(4)
            let remainedBehind = aboveOther() == false && NSWorkspace.shared.frontmostApplication?.processIdentifier == other.processIdentifier
            lines.append("\(remainedBehind ? "PASS" : "FAIL") after timers window stays behind, foreground preserved")
            lines.append("\(panel.parent == nil && panel.sheetParent == nil && panel.collectionBehavior.isEmpty && !((panel as NSWindow) is NSPanel) ? "PASS" : "FAIL") ordinary NSWindow, no panel/parent/sheet/all-spaces behavior")
            lines.append("No other app content captured or modified; window order and foreground PID only.")
            try? (lines.joined(separator:"\n")+"\n").write(to:output.appendingPathComponent("window-order-after.txt"),atomically:true,encoding:.utf8)
            if lines.contains(where:{$0.hasPrefix("FAIL")}) { exit(2) }
            quit()
        }
    }
}

@MainActor extension AppDelegate {
    func runCompanionWindowChecks(output: URL) {
        Task {
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var checks = focusedWindowTargetChecks()
            checks.merge(await ownWindowTargetChecks(output: output)) { _, new in new }
            checks.merge(await ownWindowExpansionChecks(output: output)) { _, new in new }
            checks.merge(await ownWindowInteractionChecks(output: output)) { _, new in new }
            var instant: TimeInterval = 100
            var relevant = true
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let area = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            let primaryTop = NSScreen.screens[0].frame.maxY
            var target: WeChatWindow? = .init(id: 123, pid: getpid(), bounds: .init(x: area.minX, y: primaryTop - area.maxY, width: area.width, height: area.height))
            model.autoFollow = false; model.companionEnabled = true; model.companionExpanded = false
            let controller = CompanionController(model: model, fixtureWindow: panel, targetProvider: { target }, relevantForeground: { relevant }, now: { instant }, observeWorkspace: false, observeFocus: false, reducedMotion: { true })
            companion = controller
            checks["waits_for_stable_target"] = !controller.panel.isVisible && !controller.bubble.isVisible
            instant += 0.25; controller.update()
            checks["collapsed_keeps_clickable_bubble"] = controller.bubble.isVisible && !controller.panel.isVisible
            checks["only_current_space"] = [controller.panel, controller.bubble].allSatisfy { $0.collectionBehavior.contains(.moveToActiveSpace) && !$0.collectionBehavior.contains(.canJoinAllSpaces) }
            checks["panel_has_no_extra_native_titlebar"] = !controller.panel.styleMask.contains(.titled) && controller.panel.contentLayoutRect.height == controller.panel.frame.height
            let initialTarget = target!
            let initialBubbleFrame = controller.bubble.frame
            target = WeChatWindow(id: 124, pid: initialTarget.pid, bounds: initialTarget.bounds.insetBy(dx: 30, dy: 30))
            controller.update()
            checks["different_focused_window_waits_before_moving"] = !controller.panel.isVisible && !controller.bubble.isVisible
            instant += 0.25; controller.update()
            checks["stable_focused_window_moves_bubble"] = controller.bubble.isVisible && controller.bubble.frame != initialBubbleFrame
            target = initialTarget; controller.update(); instant += 0.25; controller.update()
            checks["explicit_open_succeeds"] = controller.present()
            checks["expanded_replaces_bubble"] = controller.panel.isVisible && !controller.bubble.isVisible && model.companionExpanded
            controller.panel.contentView?.layoutSubtreeIfNeeded()
            render(controller.panel, output.appendingPathComponent("companion-panel.png"))
            let originalFrame = controller.panel.frame
            for _ in 0..<30 { instant += 0.25; controller.update() }
            checks["stable_polling_keeps_panel_and_position"] = controller.panel.isVisible && !controller.bubble.isVisible && controller.panel.frame == originalFrame
            model.companionExpanded = false; controller.update()
            checks["collapse_replaces_panel_with_bubble"] = controller.bubble.isVisible && !controller.panel.isVisible
            _ = controller.present()
            relevant = false; controller.update()
            checks["other_application_hides_without_losing_expansion"] = !controller.bubble.isVisible && !controller.panel.isVisible && model.companionExpanded
            relevant = true; controller.update(); instant += 0.25; controller.update()
            checks["return_restores_expanded_panel"] = controller.panel.isVisible && model.companionExpanded
            controller.activeSpaceDidChange()
            checks["space_change_hides_transient_surfaces"] = !controller.panel.isVisible && !controller.bubble.isVisible && model.companionExpanded
            controller.update(); instant += 0.25; controller.update()
            checks["space_transition_does_not_reappear_early"] = !controller.panel.isVisible && !controller.bubble.isVisible
            instant += 0.25; controller.update()
            checks["settled_space_restores_previous_state"] = controller.panel.isVisible && model.companionExpanded
            target = nil; controller.update()
            checks["missing_target_never_leaves_orphan_overlay"] = !controller.panel.isVisible && !controller.bubble.isVisible
            model.showConnection = true
            try? await Task.sleep(for: .milliseconds(150))
            checks["connection_gets_keyboard_focus"] = NSApp.isActive && connectionWindow?.window.isKeyWindow == true
            model.showConnection = false; model.showSettings = true
            try? await Task.sleep(for: .milliseconds(150))
            checks["model_settings_get_keyboard_focus"] = NSApp.isActive && settingsWindow?.window.isKeyWindow == true
            checks["auxiliary_windows_follow_invoking_space"] = [connectionWindow, settingsWindow].allSatisfy { $0?.window.collectionBehavior.contains(.moveToActiveSpace) == true }
            model.showSettings = false
            let passed = checks.values.allSatisfy { $0 }
            let report: [String: Any] = ["checks": checks, "passed": passed, "syntheticWindowTarget": true, "realChatRead": false, "weChatInputEvents": 0, "remoteRequests": 0]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("companion-window-checks.json")) }
            exit(passed ? 0 : 2)
        }
    }
}

#endif
