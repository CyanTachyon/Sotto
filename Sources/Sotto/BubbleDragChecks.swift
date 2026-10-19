import AppKit
import SottoCore

/// Native input is delivered only to this controller's own bubble view. The
/// target provider contains synthetic geometry from windows created below.
@MainActor func ownBubbleDragChecks(output: URL) async -> [String: Bool] {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let area = screen.visibleFrame
    let width = min(680, area.width - 80), height = min(560, area.height - 80)
    let first = NSWindow(contentRect: .init(x: area.minX + 30, y: area.minY + 25, width: width, height: height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    let second = NSWindow(contentRect: .init(x: area.minX + 45, y: area.minY + 40, width: width - 35, height: height - 25),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let standalone = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    for window in [first, second, standalone] {
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
    }
    first.title = "合成拖动目标 A"; second.title = "合成拖动目标 B"
    first.orderFront(nil); second.orderFront(nil)
    defer { first.close(); second.close(); standalone.close() }

    let model = AppModel(testMode: true)
    model.companionEnabled = true
    model.question = "拖动检查合成草稿"; model.streamingText = "拖动检查合成回答"; model.busy = true
    let primaryTop = NSScreen.screens[0].frame.maxY
    func windowTarget(_ window: NSWindow) -> WeChatWindow {
        .init(id: UInt32(window.windowNumber), pid: getpid(), bounds:
            .init(x: window.frame.minX, y: primaryTop - window.frame.maxY,
                  width: window.frame.width, height: window.frame.height))
    }
    var target: WeChatWindow? = windowTarget(first)
    var relevant = true
    var providerCalls = 0
    var instant: TimeInterval = 2_000
    let controller = CompanionController(model: model, fixtureWindow: standalone, targetProvider: { providerCalls += 1; return target },
        relevantForeground: { relevant }, now: { instant }, observeWorkspace: false,
        observeFocus: false, reducedMotion: { true })
    defer { controller.hide() }
    var checks: [String: Bool] = [:], observations: [[String: Any]] = []
    var eventsCreated = true, eventCount = 0
    func rectangle(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
    func record(_ stage: String) {
        observations.append(["stage": stage, "targetID": target.map { Int($0.id) } ?? -1,
            "targetPID": target.map { Int($0.pid) } ?? -1,
            "hostFrame": target.map { rectangle($0.appKitFrame) } ?? [:],
            "bubbleFrame": rectangle(controller.bubble.frame), "panelFrame": rectangle(controller.panel.frame),
            "bubbleVisible": controller.bubble.isVisible, "panelVisible": controller.panel.isVisible,
            "expanded": model.companionExpanded, "eventCount": eventCount])
    }
    func closePanel() { model.companionExpanded = false; controller.update() }
    func settle() { controller.update(); instant += 0.6; controller.update() }
    func point(_ offset: CGPoint = .zero) -> CGPoint {
        .init(x: controller.bubble.frame.midX + offset.x, y: controller.bubble.frame.midY + offset.y)
    }
    func send(_ type: NSEvent.EventType, at screenPoint: CGPoint) {
        // The window moves during a drag. Recompute the local coordinate for
        // every event, including mouse-up, rather than caching its old origin.
        let local = controller.bubble.convertPoint(fromScreen: screenPoint)
        guard let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
            timestamp: instant + Double(eventCount) / 1000,
            windowNumber: controller.bubble.windowNumber, context: nil,
            eventNumber: eventCount + 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1),
              let view = controller.bubble.contentView else { eventsCreated = false; return }
        eventCount += 1
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: eventsCreated = false
        }
    }
    func drag(toOrigin origin: CGPoint) {
        let from = point()
        let destination = CGPoint(x: from.x + origin.x - controller.bubble.frame.minX,
                                  y: from.y + origin.y - controller.bubble.frame.minY)
        send(.leftMouseDown, at: from); send(.leftMouseDragged, at: destination)
        send(.leftMouseUp, at: destination)
    }
    func near(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5 && abs(lhs.minY - rhs.minY) <= 0.5 &&
            abs(lhs.width - rhs.width) <= 0.5 && abs(lhs.height - rhs.height) <= 0.5
    }
    func placement() -> BubblePlacement? {
        guard let target else { return nil }
        return BubblePlacement(hostFrame: target.appKitFrame, screenVisibleFrame: area)
    }
    func collapsed() -> Bool {
        !model.companionExpanded && !controller.panel.isVisible && controller.bubble.isVisible
    }
    func centered() {
        closePanel(); settle()
        if let frame = placement()?.frame(anchor: .init(x: 0.5, y: 0.5)) { drag(toOrigin: frame.origin) }
    }

    settle(); record("ready")
    let fixtureReady = collapsed() && controller.bubble.contentView != nil
    if let view = controller.bubble.contentView {
        let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: view.superview)
        checks["bubble_hit_testing_routes_to_input_owner"] = view.hitTest(center) === view
    } else { checks["bubble_hit_testing_routes_to_input_owner"] = false }
    let click = point()
    send(.leftMouseDown, at: click); send(.leftMouseUp, at: click)
    checks["bubble_native_click_opens_panel"] = model.companionExpanded && controller.panel.isVisible && !controller.bubble.isVisible
    closePanel()
    let jitterStart = point(), jitterFrame = controller.bubble.frame
    let jitterEnd = CGPoint(x: jitterStart.x - 3, y: jitterStart.y - 4)
    send(.leftMouseDown, at: jitterStart); send(.leftMouseDragged, at: jitterEnd); send(.leftMouseUp, at: jitterEnd)
    checks["bubble_subthreshold_jitter_is_click"] = model.companionExpanded && controller.panel.isVisible && near(controller.bubble.frame, jitterFrame)
    closePanel(); centered()
    let thresholdStart = point(), thresholdFrame = controller.bubble.frame
    let thresholdEnd = CGPoint(x: thresholdStart.x - 6, y: thresholdStart.y)
    send(.leftMouseDown, at: thresholdStart)
    let callsAfterPress = providerCalls
    send(.leftMouseDragged, at: thresholdEnd)
    checks["bubble_six_point_threshold_starts_drag"] = collapsed() &&
        near(controller.bubble.frame, thresholdFrame.offsetBy(dx: -6, dy: 0))
    let continuation = CGPoint(x: thresholdStart.x - 63, y: thresholdStart.y - 41)
    send(.leftMouseDragged, at: continuation); record("drag_live")
    checks["bubble_drag_moves_live_before_mouse_up"] = collapsed() &&
        near(controller.bubble.frame, thresholdFrame.offsetBy(dx: -63, dy: -41))
    checks["bubble_drag_hot_path_reuses_polled_target"] = providerCalls == callsAfterPress
    send(.leftMouseUp, at: continuation)
    checks["bubble_drag_release_does_not_expand"] = collapsed() &&
        near(controller.bubble.frame, thresholdFrame.offsetBy(dx: -63, dy: -41))
    let dropped = controller.bubble.frame
    for _ in 0..<8 { instant += 0.25; controller.update() }
    checks["bubble_polling_preserves_dragged_position"] = collapsed() && near(controller.bubble.frame, dropped)
    let cancelStart = point(), cancelEnd = CGPoint(x: point().x - 17, y: point().y - 13)
    send(.leftMouseDown, at: cancelStart); send(.leftMouseDragged, at: cancelEnd)
    let cancelledFrame = controller.bubble.frame
    if let event = NSEvent.mouseEvent(with: .leftMouseUp,
        location: controller.bubble.convertPoint(fromScreen: cancelEnd), modifierFlags: [],
        timestamp: instant, windowNumber: controller.bubble.windowNumber, context: nil,
        eventNumber: eventCount + 1, clickCount: 1, pressure: 0) {
        controller.bubble.contentView?.mouseCancelled(with: event)
    } else { eventsCreated = false }
    send(.leftMouseDragged, at: CGPoint(x: cancelEnd.x - 70, y: cancelEnd.y - 70)); send(.leftMouseUp, at: cancelEnd)
    checks["bubble_system_cancellation_ignores_stale_drag_and_release"] = collapsed() && near(controller.bubble.frame, cancelledFrame)
    checks["bubble_accessibility_press_still_opens_panel"] = controller.bubble.contentView?.accessibilityPerformPress() == true && model.companionExpanded && controller.panel.isVisible
    closePanel()

    if let legal = placement()?.allowedOriginRect {
        let extremes: [(String, CGPoint, CGPoint)] = [
            ("left", .init(x: legal.minX - 10_000, y: legal.midY), .init(x: legal.minX, y: legal.midY)),
            ("right", .init(x: legal.maxX + 10_000, y: legal.midY), .init(x: legal.maxX, y: legal.midY)),
            ("bottom", .init(x: legal.midX, y: legal.minY - 10_000), .init(x: legal.midX, y: legal.minY)),
            ("top", .init(x: legal.midX, y: legal.maxY + 10_000), .init(x: legal.midX, y: legal.maxY))]
        for (edge, requested, expected) in extremes {
            drag(toOrigin: requested); record("clamped_" + edge)
            checks["bubble_drag_clamps_" + edge] = collapsed() && near(controller.bubble.frame,
                .init(origin: expected, size: .init(width: 48, height: 48)))
        }
    } else {
        for edge in ["left", "right", "bottom", "top"] { checks["bubble_drag_clamps_" + edge] = false }
    }
    let anchor = CGPoint(x: 0.27, y: 0.36)
    if let frame = placement()?.frame(anchor: anchor) { drag(toOrigin: frame.origin) }
    // NSEvent/native window positions can be pixel-aligned. Use the actual
    // dropped frame, then make a sizeable change to distinguish relative
    // positioning from merely retaining the old absolute screen point.
    let droppedAnchor = placement()?.normalizedAnchor(for: controller.bubble.frame.origin)
    record("anchor_before_host_resize")
    var changed = first.frame.offsetBy(dx: 80, dy: 50)
    changed.size.width -= 150; changed.size.height -= 80
    first.setFrame(changed, display: true); target = windowTarget(first); controller.update(); record("host_moved_resized")
    checks["bubble_drag_follows_normalized_anchor_after_host_geometry"] = droppedAnchor.flatMap { placement()?.frame(anchor: $0) }.map {
        collapsed() && abs(controller.bubble.frame.minX - $0.minX) <= 1 && abs(controller.bubble.frame.minY - $0.minY) <= 1
    } == true
    let rememberedA = controller.bubble.frame
    target = windowTarget(second); settle(); record("new_window_b")
    checks["bubble_new_window_starts_at_default_anchor"] = placement()?.frame().map {
        collapsed() && near(controller.bubble.frame, $0)
    } == true
    if let frame = placement()?.frame(anchor: .init(x: 0.68, y: 0.21)) { drag(toOrigin: frame.origin) }
    let rememberedB = controller.bubble.frame
    target = windowTarget(first); settle(); record("returned_window_a")
    checks["bubble_return_to_window_restores_its_anchor"] = collapsed() && near(controller.bubble.frame, rememberedA)
    target = windowTarget(second); settle()
    checks["bubble_window_anchors_are_independent"] = collapsed() && near(controller.bubble.frame, rememberedB)
    if let original = target {
        target = .init(id: original.id, pid: original.pid + 1, bounds: original.bounds); settle()
        checks["bubble_anchor_identity_includes_process"] = placement()?.frame().map {
            collapsed() && near(controller.bubble.frame, $0)
        } == true
    } else { checks["bubble_anchor_identity_includes_process"] = false }
    target = windowTarget(first); settle()

    // Cancel with a gesture in progress; stale events are still sent directly to
    // the old view, as delayed AppKit delivery must never open a replacement.
    func beginPendingDrag() -> CGPoint {
        centered()
        let start = point(), end = CGPoint(x: point().x - 26, y: point().y - 19)
        send(.leftMouseDown, at: start); send(.leftMouseDragged, at: end)
        return end
    }
    var stale = beginPendingDrag()
    target = windowTarget(second); settle()
    let replacement = controller.bubble.frame
    send(.leftMouseDragged, at: .init(x: stale.x - 40, y: stale.y - 40)); send(.leftMouseUp, at: stale)
    checks["bubble_target_switch_cancels_pending_gesture"] = collapsed() && near(controller.bubble.frame, replacement)
    record("cancel_target_switch")

    centered()
    let unpolledClick = point()
    send(.leftMouseDown, at: unpolledClick)
    target = windowTarget(first)
    // A release can beat the next polling tick. It must obtain fresh focus
    // evidence rather than using the drag hot path's cached target.
    send(.leftMouseUp, at: unpolledClick)
    checks["bubble_release_revalidates_target_before_next_poll"] = !model.companionExpanded && !controller.panel.isVisible
    settle()

    stale = beginPendingDrag()
    let anchorBeforeUnpolledMove = placement()?.normalizedAnchor(for: controller.bubble.frame.origin)
    first.setFrame(first.frame.offsetBy(dx: 29, dy: 17), display: true)
    target = windowTarget(first)
    send(.leftMouseUp, at: CGPoint(x: stale.x - 71, y: stale.y - 53))
    settle()
    checks["bubble_release_rejects_stale_geometry_without_changing_anchor"] = anchorBeforeUnpolledMove.flatMap {
        placement()?.frame(anchor: $0)
    }.map { collapsed() && near(controller.bubble.frame, $0) } == true
    record("cancel_unpolled_host_geometry")

    stale = beginPendingDrag(); controller.hide()
    send(.leftMouseUp, at: stale)
    checks["bubble_hide_cancels_pending_gesture"] = !model.companionExpanded && !controller.panel.isVisible && !controller.bubble.isVisible
    settle(); stale = beginPendingDrag()
    model.showSettings = true; controller.update(); send(.leftMouseUp, at: stale)
    checks["bubble_settings_cancels_pending_gesture"] = !model.companionExpanded && !controller.panel.isVisible && !controller.bubble.isVisible
    model.showSettings = false; settle(); stale = beginPendingDrag()
    controller.activeSpaceDidChange(); send(.leftMouseUp, at: stale)
    checks["bubble_space_change_cancels_pending_gesture"] = !model.companionExpanded && !controller.panel.isVisible && !controller.bubble.isVisible
    settle(); stale = beginPendingDrag()
    let geometryHost = target?.id == UInt32(first.windowNumber) ? first : second
    geometryHost.setFrame(geometryHost.frame.offsetBy(dx: 7, dy: 9), display: true)
    target = windowTarget(geometryHost); controller.update()
    let geometryFrame = controller.bubble.frame
    send(.leftMouseDragged, at: .init(x: stale.x - 75, y: stale.y - 75)); send(.leftMouseUp, at: stale)
    checks["bubble_host_geometry_change_cancels_pending_gesture"] = collapsed() && near(controller.bubble.frame, geometryFrame)
    record("cancel_host_geometry")

    stale = beginPendingDrag(); relevant = false; controller.update(); send(.leftMouseUp, at: stale)
    checks["bubble_foreground_departure_cancels_pending_gesture"] = !model.companionExpanded && !controller.panel.isVisible && !controller.bubble.isVisible
    relevant = true; settle(); stale = beginPendingDrag()
    target = nil; controller.update(); send(.leftMouseUp, at: stale)
    checks["bubble_missing_host_cancels_pending_gesture"] = !model.companionExpanded && !controller.panel.isVisible && !controller.bubble.isVisible
    target = windowTarget(first); settle(); stale = beginPendingDrag()
    model.companionEnabled = false; controller.update(); send(.leftMouseUp, at: stale)
    checks["bubble_disabling_companion_cancels_pending_gesture"] = !model.companionExpanded && !controller.panel.isVisible && !controller.bubble.isVisible
    model.companionEnabled = true; settle(); centered()
    let upOnlyStart = point(), upOnlyFrame = controller.bubble.frame
    let upOnlyEnd = CGPoint(x: upOnlyStart.x - 42, y: upOnlyStart.y - 23)
    send(.leftMouseDown, at: upOnlyStart); send(.leftMouseUp, at: upOnlyEnd)
    checks["bubble_mouse_up_displacement_is_drag_without_drag_events"] = collapsed() &&
        near(controller.bubble.frame, upOnlyFrame.offsetBy(dx: -42, dy: -23))
    record("mouse_up_only_drag")
    checks["bubble_native_events_and_synthetic_state_preserved"] = fixtureReady && eventsCreated && eventCount > 60 &&
        controller.bubble.frame.size == .init(width: 48, height: 48) &&
        model.question == "拖动检查合成草稿" && model.streamingText == "拖动检查合成回答" && model.busy
    if let data = try? JSONSerialization.data(withJSONObject: ["syntheticOnly": true,
        "weChatInputEvents": 0, "realChatRead": false, "remoteRequests": 0,
        "inputSource": "NSEvent.mouseEvent sent to own bubble content view",
        "eventsCreated": eventsCreated, "eventCount": eventCount,
        "checks": checks, "observations": observations], options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("own-bubble-drag-observations.json"))
    }
    return checks
}
