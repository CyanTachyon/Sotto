import Foundation
import SottoCore

/// All window identities, detections, and records in this check are synthetic.
/// No Accessibility read, database query, credential lookup, or model request occurs.
@MainActor func followModelChecks() async throws -> [String: Bool] {
    let target = DBGroup(id: "synthetic-window-a", name: "讨论 👩‍💻  A", aliases: [])
    let other = DBGroup(id: "synthetic-window-b", name: "合成讨论 B", aliases: [])
    let windowA = WeChatWindow(id: 9_101, pid: 900_001, bounds: .init(x: 10, y: 10, width: 800, height: 600))
    let windowB = WeChatWindow(id: 9_102, pid: windowA.pid, bounds: .init(x: 850, y: 10, width: 800, height: 600))
    func detection(_ state: String, group: DBGroup? = nil) -> CurrentWeChat.Detection {
        .init(group: group, state: state, visited: 0, evidenceCount: group == nil ? 0 : 1, roleCounts: [:])
    }
    func settlePoll() async throws { try await Task.sleep(for: .milliseconds(20)) }
    func syntheticModel() -> AppModel {
        let value = AppModel(testMode: true)
        value.groups = [target, other]
        value.followForegroundIsRelevant = { true }
        value.followAXReader = { _ in detection("unmatched") }
        return value
    }
    let model = syntheticModel()
    model.live = true
    model.observeConversationWindow(windowA)
    model.companionEnabled = true; model.companionExpanded = false
    var nativeReads = 0
    model.followAXReader = { _ in
        nativeReads += 1
        return detection("confirmed", group: target)
    }
    var checks: [String: Bool] = [:]
    model.pollIdentity()
    try await settlePoll()
    checks["hidden_companion_does_not_poll_identity"] = nativeReads == 0
    model.isStandaloneConversationVisible = { true }
    model.pollIdentity()
    try await settlePoll()
    checks["development_fixture_can_follow_native_identity"] =
        nativeReads == 1 && model.groupID == target.id && model.followState == "confirmed" &&
        model.isFollowingWindow && model.canAsk
    try model.loadSyntheticPreview()
    let previousAnswer = model.turns.first?.id
    model.question = "A 的合成草稿"
    for state in ["ambiguous", "unsupportedWindow", "unsupported", "noWindow", "notRunning", "incomplete", "unmatched", "permissionRequired", "conflicting"] {
        model.followAXReader = { _ in
            nativeReads += 1
            return detection(state)
        }
        let observed = await model.inspectFollow()
        model.applyFollowDetection(observed)
        checks["native_\(state)_blocks_sending_and_preserves_previous_conversation"] =
            !model.canAsk && model.needsConversationSelection && model.groupID == target.id &&
            model.turns.first?.id == previousAnswer && model.question == "A 的合成草稿"
    }
    model.applyFollowDetection(detection("unverified", group: target))
    checks["candidate_without_confirmed_state_cannot_authorize_sending"] = !model.canAsk && !model.isFollowingWindow
    model.applyFollowDetection(detection("confirmed", group: target))
    checks["native_confirmation_resumes_selected_conversation"] =
        model.canAsk && model.isFollowingWindow && model.turns.first?.id == previousAnswer

    model.applyFollowDetection(detection("ambiguous"))
    model.selectGroup(target.id)
    checks["manual_fallback_authorizes_the_selected_conversation"] =
        model.canAsk && model.hasManualConversationSelection && !model.isFollowingWindow && !model.needsConversationSelection
    for state in ["ambiguous", "incomplete", "unmatched", "unverified", "conflicting", "permissionRequired", "unsupported"] {
        model.applyFollowDetection(detection(state, group: state == "unverified" ? other : nil))
        checks["same_window_\(state)_preserves_manual_fallback"] =
            model.canAsk && model.hasManualConversationSelection && model.groupID == target.id
    }
    let readsBeforeManualPoll = nativeReads
    model.followAXReader = { _ in
        nativeReads += 1
        return detection("confirmed", group: other)
    }
    model.pollIdentity()
    try await settlePoll()
    checks["manual_fallback_does_not_disable_future_confirmed_follow"] =
        nativeReads == readsBeforeManualPoll + 1 && model.groupID == other.id && model.isFollowingWindow &&
        !model.hasManualConversationSelection && model.canAsk && model.turns.isEmpty && model.question.isEmpty
    model.question = "B 的合成草稿"
    model.applyFollowDetection(detection("confirmed", group: target))
    checks["automatic_follow_restores_the_correct_conversation_history_and_draft"] =
        model.groupID == target.id && model.turns.first?.id == previousAnswer && model.question == "A 的合成草稿"

    model.applyFollowDetection(detection("ambiguous")); model.selectGroup(target.id)
    let movedWindowA = WeChatWindow(id: windowA.id, pid: windowA.pid, bounds: .init(x: 40, y: 20, width: 900, height: 700))
    model.observeConversationWindow(movedWindowA)
    checks["same_window_geometry_change_preserves_manual_fallback"] =
        model.hasManualConversationSelection && model.canAsk
    model.observeConversationWindow(windowB)
    checks["different_window_revokes_manual_fallback_and_preserves_visible_context"] =
        !model.hasManualConversationSelection && model.needsConversationSelection && !model.canAsk &&
        model.turns.first?.id == previousAnswer && model.question == "A 的合成草稿"
    model.selectGroup(other.id)
    let restartedWindow = WeChatWindow(id: windowB.id, pid: 900_002, bounds: windowB.bounds)
    model.observeConversationWindow(restartedWindow)
    checks["different_process_cannot_reuse_the_same_window_manual_fallback"] =
        !model.hasManualConversationSelection && model.needsConversationSelection && !model.canAsk
    for state in ["noWindow", "notRunning", "unsupportedWindow"] {
        model.observeConversationWindow(windowA); model.selectGroup(target.id)
        model.applyFollowDetection(detection(state))
        checks["native_\(state)_revokes_manual_fallback"] =
            !model.hasManualConversationSelection && model.needsConversationSelection && !model.canAsk
    }

    let readsBeforeUnrelatedApp = nativeReads
    model.followForegroundIsRelevant = { false }
    model.pollIdentity()
    try await settlePoll()
    checks["other_foreground_app_prevents_background_follow_poll"] = nativeReads == readsBeforeUnrelatedApp

    let queued = syntheticModel()
    queued.live = true; queued.observeConversationWindow(windowA)
    queued.followAXReader = { _ in detection("confirmed", group: other) }
    queued.pollIdentity()
    queued.selectGroup(target.id)
    try await settlePoll()
    checks["queued_identity_poll_cannot_override_a_newer_manual_selection"] =
        queued.groupID == target.id && queued.hasManualConversationSelection && queued.canAsk

    let changedWindow = syntheticModel()
    changedWindow.live = true; changedWindow.observeConversationWindow(windowA)
    changedWindow.followAXReader = { _ in detection("confirmed", group: target) }
    changedWindow.pollIdentity()
    changedWindow.observeConversationWindow(windowB)
    try await settlePoll()
    checks["queued_identity_poll_cannot_bind_a_different_window"] =
        changedWindow.needsConversationSelection && !changedWindow.canAsk && changedWindow.groupID.isEmpty

    let imported = syntheticModel()
    var importedReads = 0
    imported.followAXReader = { _ in importedReads += 1; return detection("confirmed", group: other) }
    let session = try ChatImporter.parse(#"{"conversation":"合成导入","messages":[{"timestamp":"2026-10-16T00:00:00Z","sender":"合成人员","text":"独立导入记录"}]}"#, filename: "synthetic-follow.json")
    imported.select(session); imported.pollIdentity()
    try await settlePoll()
    imported.applyFollowDetection(detection("confirmed", group: other))
    checks["imported_records_do_not_poll_or_switch_to_a_database_conversation"] =
        importedReads == 0 && !imported.live && imported.current == session && imported.groupID.isEmpty && imported.canAsk
    return checks
}
