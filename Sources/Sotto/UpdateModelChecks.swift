import Foundation
import SottoCore

/// Only fictional model state; no updater is started and no network is used.
@MainActor func updateModelChecks() throws -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let model = AppModel(testMode: true)
    checks["update_empty_model_does_not_claim_content_loss"] = !model.hasEphemeralConversationContent
    model.question = "尚未发送的合成草稿"
    checks["update_restart_guard_sees_current_draft"] = model.hasEphemeralConversationContent
    model.question = ""; model.streamingText = "合成流式片段"
    checks["update_restart_guard_sees_partial_answer"] = model.hasEphemeralConversationContent
    model.streamingText = ""; model.pendingQuestion = "尚未返回的问题"
    checks["update_restart_guard_sees_pending_question"] = model.hasEphemeralConversationContent
    model.pendingQuestion = ""
    model.root = "/synthetic/update-state/db_storage"
    let a = DBGroup(id: "update-a", name: "合成更新 A", aliases: [])
    let b = DBGroup(id: "update-b", name: "合成更新 B", aliases: [])
    model.groups = [a, b]; model.selectGroup(a.id)
    model.question = "仅在另一会话中的草稿"; model.selectGroup(b.id)
    checks["update_restart_guard_sees_other_conversation_draft"] = model.question.isEmpty && model.hasEphemeralConversationContent
    model.selectGroup(a.id); model.startNewConversation(); model.selectGroup(b.id)
    checks["update_cleared_conversations_do_not_keep_loss_warning"] = !model.hasEphemeralConversationContent
    model.selectGroup(a.id); try model.loadSyntheticPreview(); model.selectGroup(b.id)
    checks["update_restart_guard_sees_other_conversation_answers"] = model.turns.isEmpty && model.hasEphemeralConversationContent
    let updates = AppUpdateController(model: model, enabled: false)
    updates.setAutomaticallyChecksForUpdates(true); updates.checkForUpdates(nil)
    checks["update_synthetic_controller_cannot_start_checks_or_enable_schedule"] =
        !updates.canCheckForUpdates && !updates.automaticallyChecksForUpdates
    checks["update_disabled_controller_does_not_intercept_normal_quit"] = updates.allowsApplicationTermination()
    return checks
}
