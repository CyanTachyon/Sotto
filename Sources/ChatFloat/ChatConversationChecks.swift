import Foundation
import ChatCore

/// Exercises model state only, with fictional records and in-memory database callbacks.
/// No request reaches a model, credential files, or the database adapter.
@MainActor func chatConversationChecks() async throws -> [String: Bool] {
    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw ChatError.invalid("合成新对话检查等待超时")
    }
    let root = "/synthetic/new-conversation/db_storage"
    let a = DBGroup(id: "new-context-a", name: "合成会话 A", aliases: [])
    let b = DBGroup(id: "new-context-b", name: "合成会话 B", aliases: [])
    func requestModel() -> AppModel {
        let value = AppModel(testMode: true)
        value.root = root; value.groups = [a, b]; value.selectGroup(a.id, automatic: true)
        value.autoFollow = false
        value.config = ModelConfig(); value.config.endpoint = "https://synthetic.invalid/chat/completions"
        value.config.model = "synthetic-unused"; value.config.consentEndpoint = value.config.endpoint
        return value
    }
    var checks: [String: Bool] = [:]
    let model = requestModel()
    checks["empty_conversation_has_no_context_to_clear"] = !model.canStartNewConversation
    model.question = "合成草稿"
    checks["draft_enables_new_conversation"] = model.canStartNewConversation
    model.startNewConversation()
    checks["draft_only_new_conversation_clears_input"] = model.question.isEmpty && !model.canStartNewConversation

    // Establish a verified connection using callbacks, then retain it across context reset.
    model.databaseConnectionSource = .init(readManifest: { _ in
        #"{"keys":{"contact/contact.db":{"enc_key":"0000000000000000000000000000000000000000000000000000000000000000"}}}"#
    }, readGroups: { _ in .init(account: DatabaseBridge.account(root), groups: [a, b]) })
    model.connect(userInitiated: false)
    try await waitUntil { !model.connecting }
    guard model.hasDatabaseConnection else { throw ChatError.invalid("合成连接未完成") }
    try model.loadSyntheticPreview()
    model.question = "A 的旧草稿"
    let aTurn = model.turns.first?.id
    model.selectGroup(b.id, automatic: true)
    checks["uncached_conversation_starts_with_empty_input"] = model.question.isEmpty && model.turns.isEmpty && model.current == nil
    try model.loadSyntheticPreview(); model.question = "B 的独立草稿"
    let bTurn = model.turns.first?.id
    model.selectGroup(a.id, automatic: true)
    checks["conversation_drafts_exist_before_reset"] = model.turns.first?.id == aTurn && model.question == "A 的旧草稿"
    model.range = 0; model.start = Date(timeIntervalSince1970: 1_700_000_000)
    model.end = model.start.addingTimeInterval(1_800); model.includeUnknown = true
    let start = model.start, end = model.end, config = model.config
    model.streamingText = "合成流式部分"; model.pendingQuestion = "A 的在途问题"
    model.imageSummary = "合成图片状态"; model.showSources = true; model.busy = true; model.error = "旧错误"
    checks["busy_conversation_can_start_fresh"] = model.canStartNewConversation
    model.startNewConversation()
    checks["new_conversation_clears_all_visible_ai_context"] =
        !model.busy && model.question.isEmpty && model.turns.isEmpty && model.streamingText.isEmpty &&
        model.pendingQuestion.isEmpty && model.frozenSnapshot == nil && model.current == nil &&
        model.imageSummary.isEmpty &&
        model.error.isEmpty && !model.showSources && !model.canStartNewConversation
    checks["new_conversation_preserves_source_range_connection_and_model"] =
        model.live && model.groupID == a.id && model.root == root && !model.autoFollow &&
        model.range == 0 && model.start == start && model.end == end && model.includeUnknown &&
        model.config == config && model.hasDatabaseConnection && model.canAsk
    model.selectGroup(b.id, automatic: true)
    checks["clearing_a_preserves_b_answers_and_draft"] = model.turns.first?.id == bTurn && model.question == "B 的独立草稿"
    model.selectGroup(a.id, automatic: true)
    checks["returning_to_cleared_conversation_does_not_restore_old_draft_or_snapshot"] =
        model.question.isEmpty && model.turns.isEmpty && model.current == nil && model.frozenSnapshot == nil &&
        model.range == 0 && model.start == start && model.end == end

    let imported = try ChatImporter.parse(#"{"conversation":"合成导入","messages":[{"timestamp":"2026-10-16T00:00:00Z","sender":"合成人员","text":"仅用于新对话检查"}]}"#, filename: "synthetic.json")
    model.question = "导入前保留在数据库会话的草稿"
    model.select(imported)
    checks["import_selection_does_not_inherit_database_draft"] = model.question.isEmpty && model.current == imported && !model.live
    model.selectGroup(a.id, automatic: true)
    checks["return_from_import_restores_database_draft"] = model.question == "导入前保留在数据库会话的草稿" && model.groupID == a.id && model.live
    model.select(imported); model.question = "导入记录问题"
    model.startNewConversation()
    checks["new_conversation_keeps_imported_records_available"] =
        !model.live && model.current == imported && model.displayedMessages == imported.messages && model.canAsk &&
        model.question.isEmpty && model.turns.isEmpty && !model.canStartNewConversation

    // Cancellation must win even when the transport ignores cancellation until it returns.
    let pending = requestModel()
    var continuation: CheckedContinuation<DBRead, Error>?
    pending.databaseConnectionSource.readMessages = { _, _, _ in
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    pending.question = "提交后清空的合成问题"; pending.ask()
    try await waitUntil { continuation != nil }
    checks["accepted_submission_clears_input_while_request_runs"] = pending.busy && pending.question.isEmpty && !pending.pendingQuestion.isEmpty
    pending.startNewConversation()
    continuation?.resume(returning: .init(account: DatabaseBridge.account(root), chat: a.id, name: a.name,
        scannedShards: 1, omittedMedia: 0, completeLocalQuery: true, messages: []))
    continuation = nil
    try await Task.sleep(for: .milliseconds(40))
    checks["late_database_result_cannot_revive_cleared_context"] =
        !pending.busy && pending.current == nil && pending.frozenSnapshot == nil && pending.turns.isEmpty &&
        pending.question.isEmpty && pending.streamingText.isEmpty && pending.pendingQuestion.isEmpty && pending.error.isEmpty

    for keepNewDraft in [false, true] {
        let cancelled = requestModel()
        var stoppedRead: CheckedContinuation<DBRead, Error>?
        cancelled.databaseConnectionSource.readMessages = { _, _, _ in
            try await withCheckedThrowingContinuation { stoppedRead = $0 }
        }
        cancelled.question = "  首段前停止时恢复原文  "; cancelled.ask()
        try await waitUntil { stoppedRead != nil }
        if keepNewDraft { cancelled.question = "停止时保留这份新草稿" }
        cancelled.cancel()
        let expected = keepNewDraft ? "停止时保留这份新草稿" : "  首段前停止时恢复原文  "
        stoppedRead?.resume(throwing: ChatError.invalid("取消后到达的合成失败")); stoppedRead = nil
        try await Task.sleep(for: .milliseconds(40))
        checks[keepNewDraft ? "cancel_before_first_chunk_preserves_newer_input" : "cancel_before_first_chunk_restores_original_input"] =
            cancelled.question == expected && !cancelled.busy && cancelled.turns.isEmpty &&
            cancelled.pendingQuestion.isEmpty && cancelled.streamingText.isEmpty && cancelled.error.isEmpty
    }

    let invalid = requestModel(); invalid.config.endpoint = "ftp://synthetic.invalid"
    invalid.config.consentEndpoint = invalid.config.endpoint
    var invalidReads = 0
    invalid.databaseConnectionSource.readMessages = { _, _, _ in invalidReads += 1; throw ChatError.invalid("不应读取") }
    invalid.question = "  无效配置时保留原文  "; invalid.ask()
    try await waitUntil { !invalid.busy }
    checks["configuration_failure_preserves_input_without_reading_records"] =
        invalid.question == "  无效配置时保留原文  " && !invalid.error.isEmpty && invalidReads == 0

    let failed = requestModel()
    failed.databaseConnectionSource.readMessages = { _, _, _ in throw ChatError.invalid("合成读取失败") }
    failed.question = "  失败后恢复此原文  "; failed.ask()
    try await waitUntil { !failed.busy }
    checks["submission_failure_restores_original_input"] = failed.question == "  失败后恢复此原文  " && !failed.error.isEmpty
    failed.question = "另一次提交"; failed.ask(); failed.question = "预检期间的新草稿"
    try await waitUntil { !failed.busy }
    checks["late_failure_does_not_erase_newer_input"] = failed.question == "预检期间的新草稿" && !failed.error.isEmpty

    // Selecting a saved import must adopt its own span, not the default recent window.
    let oldImport = try ChatImporter.parse(
        #"{"conversation":"旧导入","messages":[{"timestamp":"2020-01-01T00:00:00Z","sender":"甲","text":"旧消息"}]}"#,
        filename: "old.json")
    let importModel = AppModel(testMode: true)
    importModel.range = 1800; importModel.end = Date()
    importModel.select(oldImport)
    checks["reselecting_import_resets_range_to_session_span"] =
        importModel.range == 0 && importModel.start == oldImport.messages[0].timestamp && importModel.end == oldImport.messages[0].timestamp

    // Refreshing records keeps displayed answers but drops the frozen snapshot.
    let refresh = requestModel()
    try refresh.loadSyntheticPreview()
    let refreshTurnCount = refresh.turns.count
    refresh.refreshRecords()
    checks["refresh_keeps_answers_and_clears_snapshot"] =
        refresh.turns.count == refreshTurnCount && refresh.frozenSnapshot == nil && !refresh.busy && refresh.error.isEmpty

    // Imported records must not be silently switched to the database source.
    let importedModel = AppModel(testMode: true)
    importedModel.groups = [a]
    importedModel.select(oldImport)
    importedModel.autoFollow = true
    importedModel.followChanged()
    checks["imported_conversation_cannot_enable_follow"] =
        !importedModel.live && !importedModel.autoFollow && importedModel.current?.id == oldImport.id
    return checks
}
