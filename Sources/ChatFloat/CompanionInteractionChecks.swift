import AppKit
import ChatCore
import QuartzCore

/// Exercise focus changes and animation races using only this process's windows.
/// A fixture window stands in for WeChat; no external app is activated or queried.
@MainActor func ownWindowInteractionChecks(output: URL) async -> [String: Bool] {
    let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    let host = NSWindow(contentRect: .init(x: area.minX + 50, y: area.minY + 40, width: 680, height: 600),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let auxiliary = NSWindow(contentRect: .init(x: area.minX + 80, y: area.minY + 80, width: 400, height: 340),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let standalone = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    for window in [host, auxiliary, standalone] {
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
    }
    host.title = "合成聊天 · 动画与焦点检查"; auxiliary.title = "合成辅助操作"
    host.makeKeyAndOrderFront(nil); NSApp.activate()
    defer { host.close(); auxiliary.close(); standalone.close() }

    let model = AppModel(testMode: true)
    model.autoFollow = false; model.companionEnabled = true
    model.question = "合成草稿：失焦后仍保留"; model.streamingText = "合成流式回答"; model.busy = true
    do {
        let snapshot = try SyntheticScenario.snapshot()
        let answer = try GroundedAnswer(validating: SyntheticScenario.narrative(snapshot))
        model.turns = [AnswerTurn(question: "合成问题", answer: answer, snapshot: snapshot)]
    } catch { return ["interaction_fixture_setup": false] }
    let turnIDs = model.turns.map(\.id)
    let top = NSScreen.screens[0].frame.maxY
    let initialTarget = WeChatWindow(id: UInt32(host.windowNumber), pid: getpid(), bounds:
        .init(x: host.frame.minX, y: top - host.frame.maxY, width: host.frame.width, height: host.frame.height))
    var target: WeChatWindow? = initialTarget
    var instant: TimeInterval = 1_000
    var relevant = true, reduceMotion = false, interactionActive = false
    let controller = CompanionController(model: model, fixtureWindow: standalone, targetProvider: { target },
        relevantForeground: { relevant }, now: { instant }, observeWorkspace: false,
        observeFocus: true, reducedMotion: { reduceMotion }, focusIsWithinCompanion: { interactionActive })
    defer { controller.hide() }
    var checks: [String: Bool] = [:]
    var observations: [[String: Any]] = []
    func pause(_ milliseconds: Int = 300) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    func record(_ stage: String) {
        observations.append(["stage": stage, "uptime": ProcessInfo.processInfo.systemUptime,
            "panelVisible": controller.panel.isVisible, "bubbleVisible": controller.bubble.isVisible,
            "expanded": model.companionExpanded, "panelKey": controller.panel.isKeyWindow,
            "panelAlpha": controller.panel.alphaValue, "bubbleAlpha": controller.bubble.alphaValue,
            "panelIgnoresMouseEvents": controller.panel.ignoresMouseEvents,
            "targetID": target.map { Int($0.id) } ?? -1])
    }
    func settleTarget() { controller.update(); instant += 0.6; controller.update() }
    func reopen() async {
        target = initialTarget; relevant = true
        settleTarget(); _ = controller.present(); await pause()
    }
    settleTarget()
    let finalFrame = controller.panel.frame
    checks["motion_fixture_bubble_ready"] = controller.bubble.isVisible && !controller.panel.isVisible
    _ = controller.present()
    await pause(55); record("opening_intermediate")
    checks["opening_has_visible_intermediate_opacity"] = controller.panel.isVisible && controller.panel.alphaValue > 0 && controller.panel.alphaValue < 1
    checks["opening_has_subtle_content_scale"] = controller.panel.contentView?.layer.map {
        $0.sublayerTransform.m11 > 0.95 && $0.sublayerTransform.m11 < 1
    } == true
    checks["opening_does_not_reflow_window_geometry"] = controller.panel.frame == finalFrame
    await pause(); record("opening_complete")
    checks["opening_finishes_key_and_fully_visible"] = controller.panel.isKeyWindow && controller.panel.isVisible &&
        controller.panel.alphaValue == 1 && !controller.bubble.isVisible && !controller.panel.ignoresMouseEvents
    // Same underlying native window, but the user gives keyboard focus back to it.
    host.makeKeyAndOrderFront(nil)
    await pause(240); record("same_target_blur_transition")
    checks["same_target_focus_return_clears_expansion"] = !model.companionExpanded
    checks["closing_panel_cannot_intercept_clicks"] = !controller.panel.isVisible || controller.panel.ignoresMouseEvents
    await pause(); record("same_target_blur_complete")
    checks["same_target_focus_return_leaves_only_bubble"] = !controller.panel.isVisible && controller.bubble.isVisible &&
        controller.bubble.alphaValue == 1 && NSApp.keyWindow === host
    for _ in 0..<5 { instant += 0.25; controller.update() }
    checks["polling_after_blur_cannot_reopen_panel"] = !model.companionExpanded && !controller.panel.isVisible

    await reopen()
    host.makeKeyAndOrderFront(nil); await pause(35)
    controller.panel.makeKeyAndOrderFront(nil)
    await pause()
    checks["brief_focus_handoff_returning_to_panel_does_not_close"] = model.companionExpanded && controller.panel.isKeyWindow
    // A framework child window is part of the companion, not an outside click.
    controller.panel.addChildWindow(auxiliary, ordered: .above)
    auxiliary.makeKeyAndOrderFront(nil); await pause()
    checks["child_window_focus_keeps_companion_open"] = model.companionExpanded
    controller.panel.removeChildWindow(auxiliary); auxiliary.orderOut(nil)
    controller.panel.makeKeyAndOrderFront(nil); await pause(30)

    let popover = NSPopover()
    let content = NSViewController()
    content.view = NSView(frame: .init(x: 0, y: 0, width: 220, height: 100))
    let field = NSTextField(string: "合成会话选择器")
    field.frame = .init(x: 16, y: 35, width: 180, height: 24); content.view.addSubview(field)
    popover.contentViewController = content; popover.behavior = .transient
    popover.show(relativeTo: .init(x: 200, y: 360, width: 20, height: 20), of: controller.panel.contentView!, preferredEdge: .minX)
    await pause(80)
    content.view.window?.makeKeyAndOrderFront(nil); await pause()
    checks["real_popover_can_take_focus_without_collapsing_panel"] = popover.isShown && model.companionExpanded
    popover.performClose(nil); controller.panel.makeKeyAndOrderFront(nil); await pause()
    checks["closing_popover_back_to_panel_keeps_expansion"] = model.companionExpanded && controller.panel.isVisible

    // Menu tracking notifications are injected; no mouse/keyboard events are sent.
    let menu = NSMenu(title: "合成菜单")
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    host.makeKeyAndOrderFront(nil); await pause()
    checks["menu_tracking_suppresses_transient_key_loss"] = model.companionExpanded
    controller.panel.makeKeyAndOrderFront(nil)
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    await pause()
    checks["menu_dismissal_back_to_panel_keeps_expansion"] = model.companionExpanded

    interactionActive = true
    host.makeKeyAndOrderFront(nil); await pause()
    checks["explicit_picker_interaction_does_not_collapse"] = model.companionExpanded
    controller.panel.makeKeyAndOrderFront(nil); interactionActive = false; await pause()

    for protectingPicker in [false, true] {
        await reopen()
        if protectingPicker { interactionActive = true }
        else { NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu) }
        // An external-app activation can arrive before the transient UI closes.
        relevant = false; target = nil; controller.update()
        let label = protectingPicker ? "picker" : "menu"
        checks[label + "_cannot_preserve_expansion_after_leaving_application"] = !model.companionExpanded && !controller.panel.isVisible
        interactionActive = false
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        await pause()
        relevant = true; target = initialTarget; settleTarget(); await pause()
        checks[label + "_external_departure_returns_to_bubble"] = controller.bubble.isVisible && !controller.panel.isVisible && !model.companionExpanded
    }

    for keyPath in [\AppModel.showSettings, \AppModel.showConnection, \AppModel.showSources] {
        await reopen()
        model[keyPath: keyPath] = true
        auxiliary.makeKeyAndOrderFront(nil); controller.update(); await pause()
        let label = keyPath == \AppModel.showSettings ? "settings" : keyPath == \AppModel.showConnection ? "connection" : "sources"
        checks[label + "_focus_is_not_treated_as_outside_dismissal"] = model.companionExpanded && !controller.panel.isVisible && auxiliary.isKeyWindow
        model[keyPath: keyPath] = false; auxiliary.orderOut(nil)
        controller.resumeAfterAuxiliary(); settleTarget(); await pause()
        checks[label + "_close_restores_panel_keyboard_focus"] = model.companionExpanded && controller.panel.isVisible && controller.panel.isKeyWindow
        host.makeKeyAndOrderFront(nil); await pause(500)
        checks[label + "_restored_panel_still_collapses_on_focus_return"] = !model.companionExpanded && !controller.panel.isVisible && controller.bubble.isVisible
    }

    await reopen()
    model.showSettings = true; controller.hide(); controller.update()
    model.showSettings = false; controller.resumeAfterAuxiliary()
    relevant = false; target = nil; controller.update()
    relevant = true; target = initialTarget; settleTarget(); await pause()
    checks["leaving_during_auxiliary_restore_wait_cannot_reopen_panel"] = !model.companionExpanded &&
        !controller.panel.isVisible && controller.bubble.isVisible && !controller.panel.isKeyWindow

    // Reversing before completion must not leave a transparent or input-blocking window.
    await reopen()
    model.companionExpanded = false; controller.update(); await pause(40)
    _ = controller.present(); await pause()
    checks["rapid_close_then_open_finishes_with_usable_panel"] = model.companionExpanded && controller.panel.isVisible &&
        controller.panel.alphaValue == 1 && !controller.panel.ignoresMouseEvents && !controller.bubble.isVisible
    model.companionExpanded = false; controller.update(); await pause(30)
    _ = controller.present(); await pause(30)
    model.companionExpanded = false; controller.update(); await pause()
    checks["rapid_open_then_close_finishes_with_clickable_bubble"] = !model.companionExpanded && !controller.panel.isVisible &&
        controller.bubble.isVisible && controller.bubble.alphaValue == 1 && !controller.bubble.ignoresMouseEvents

    _ = controller.present(); await pause(35)
    controller.hide(); await pause()
    checks["hide_cancels_opening_without_late_reappearance"] = !controller.panel.isVisible && !controller.bubble.isVisible
    await reopen()
    model.companionExpanded = false; controller.update(); await pause(35)
    controller.hide(); await pause()
    checks["hide_cancels_closing_without_late_bubble"] = !controller.panel.isVisible && !controller.bubble.isVisible

    await reopen()
    model.companionExpanded = false; controller.update(); await pause()
    _ = controller.present(); await pause(35)
    let frameBeforeSwitch = controller.panel.frame
    target = .init(id: initialTarget.id + 100, pid: initialTarget.pid, bounds: initialTarget.bounds.offsetBy(dx: 25, dy: 0))
    controller.update()
    checks["target_switch_interrupts_motion_before_repositioning"] = !model.companionExpanded && !controller.panel.isVisible &&
        controller.panel.frame == frameBeforeSwitch
    instant += 0.3; controller.update(); await pause()
    checks["old_open_completion_cannot_expand_new_target"] = !controller.panel.isVisible && controller.bubble.isVisible && !model.companionExpanded

    await reopen()
    controller.activeSpaceDidChange(); await pause()
    checks["space_change_cancels_animation_surfaces"] = !controller.panel.isVisible && !controller.bubble.isVisible
    instant += 0.6; settleTarget()
    model.companionExpanded = false; controller.update(); await pause()
    reduceMotion = true
    _ = controller.present(); record("reduce_motion_open")
    checks["reduced_motion_open_is_immediate_and_unscaled"] = controller.panel.isVisible && controller.panel.alphaValue == 1 && !controller.bubble.isVisible &&
        controller.panel.contentView?.layer.map { CATransform3DIsIdentity($0.sublayerTransform) } == true
    model.companionExpanded = false; controller.update()
    checks["reduced_motion_close_is_immediate"] = !controller.panel.isVisible && controller.bubble.isVisible && controller.bubble.alphaValue == 1
    checks["focus_and_animation_preserve_draft_answers_and_generation"] = model.question == "合成草稿：失焦后仍保留" &&
        model.streamingText == "合成流式回答" && model.turns.map(\.id) == turnIDs && model.busy
    if let data = try? JSONSerialization.data(withJSONObject: ["syntheticOnly": true, "weChatInputEvents": 0,
        "realChatRead": false, "remoteRequests": 0, "focusSource": "own AppKit windows",
        "menuTrackingNotificationsInjected": true, "spaceNotificationsInjected": true,
        "observations": observations], options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("own-window-interaction-observations.json"))
    }
    return checks
}
