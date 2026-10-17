import Foundation
import ChatCore

@MainActor func followModelChecks() async throws -> [String: Bool] {
    let model = AppModel(testMode: true)
    let target = DBGroup(id: "synthetic-window-b", name: "讨论 👩‍💻  A", aliases: [])
    model.groups = [target]
    model.live = true; model.autoFollow = true
    model.companionEnabled = true; model.companionExpanded = false
    model.followForegroundIsRelevant = { true }
    var nativeReads = 0
    model.followAXReader = { _ in
        nativeReads += 1
        return .init(group: target, state: "confirmed", visited: 1, evidenceCount: 1, roleCounts: [:])
    }
    var checks: [String: Bool] = [:]
    model.pollIdentity()
    await Task.yield()
    checks["hidden_companion_does_not_poll_identity"] = nativeReads == 0
    model.isStandaloneConversationVisible = { true }
    model.pollIdentity()
    for _ in 0..<100 {
        if model.groupID == target.id { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    checks["development_fixture_can_follow_native_identity"] =
        nativeReads == 1 && model.groupID == target.id && model.followState == "confirmed" && model.canAsk
    try model.loadSyntheticPreview()
    let previousAnswer = model.turns.first?.id
    for state in ["ambiguous", "unsupportedWindow", "unsupported", "noWindow", "incomplete", "unmatched"] {
        model.followAXReader = { _ in
            nativeReads += 1
            return .init(group: nil, state: state, visited: 0, evidenceCount: 0, roleCounts: [:])
        }
        let detection = await model.inspectFollow()
        model.applyFollowDetection(detection)
        checks["native_\(state)_blocks_sending_and_preserves_previous_conversation"] =
            !model.canAsk && model.groupID == target.id && model.turns.first?.id == previousAnswer
    }
    model.applyFollowDetection(.init(group: target, state: "unverified", visited: 0, evidenceCount: 1, roleCounts: [:]))
    checks["candidate_without_confirmed_state_cannot_authorize_sending"] = !model.canAsk
    model.applyFollowDetection(.init(group: target, state: "confirmed", visited: 1, evidenceCount: 1, roleCounts: [:]))
    checks["native_confirmation_resumes_selected_conversation"] = model.canAsk && model.turns.first?.id == previousAnswer
    let previousReads = nativeReads
    model.followForegroundIsRelevant = { false }
    model.pollIdentity()
    await Task.yield()
    checks["other_foreground_app_prevents_background_follow_poll"] = nativeReads == previousReads
    return checks
}
