import Foundation
import SottoCore

@MainActor func connectionModelChecks() async throws -> [String: Bool] {
    let defaults = UserDefaults.standard
    let saved = ["databaseRoot", "selectedDatabaseGroupV3", "followCurrentConversationV4"].map { ($0, defaults.object(forKey: $0)) }
    defer { for (key, value) in saved { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
    let accountA = "/synthetic/connection-a/db_storage", accountB = "/synthetic/connection-b/db_storage"
    let manifest = #"{"keys":{"contact/contact.db":{"enc_key":"0000000000000000000000000000000000000000000000000000000000000000"}}}"#
    func groups(_ root: String) -> DBGroups {
        .init(account: DatabaseBridge.account(root), groups: [.init(id: root == accountA ? "synthetic-a" : "synthetic-b", name: "合成连接检查", aliases: [])])
    }
    func wait(_ model: AppModel) async throws {
        for _ in 0..<200 { if !model.connecting { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw ChatError.invalid("合成连接检查等待超时")
    }
    var checks: [String: Bool] = [:], credentialReads = 0, groupReads = 0
    let model = AppModel(testMode: true); model.root = accountA
    model.databaseConnectionSource = .init(readManifest: { _ in credentialReads += 1; return manifest }, readGroups: { root in
        groupReads += 1; try await Task.sleep(for: .milliseconds(30)); return groups(root)
    })
    model.connect(userInitiated: false); model.connect(userInitiated: false); model.connect(userInitiated: true)
    try await wait(model)
    checks["saved_credentials_connect_silently_without_manual_action"] = model.hasDatabaseConnection && model.live && credentialReads == 1
    checks["overlapping_connection_requests_coalesce"] = groupReads == 1
    try model.loadSyntheticPreview(); model.live = true; model.groupID = "synthetic-a"; model.question = "保留此草稿"
    let sessionID = model.current?.id, turnID = model.turns.first?.id
    model.connect(userInitiated: true); try await wait(model)
    checks["same_account_verification_preserves_answers_and_draft"] = model.current?.id == sessionID && model.turns.first?.id == turnID && model.question == "保留此草稿" && model.groupID == "synthetic-a"
    checks["explicit_verification_rereads_local_credential_file"] = credentialReads == 2
    model.connect(userInitiated: false); try await wait(model)
    checks["healthy_connection_does_not_repeat_database_work"] = groupReads == 2
    let healthyReadGroups = model.databaseConnectionSource.readGroups
    model.databaseConnectionSource.readGroups = { _ in throw ChatError.invalid("合成重新验证失败") }
    model.connect(userInitiated: true); try await wait(model)
    checks["failed_explicit_reverification_invalidates_health_without_losing_history"] = !model.hasDatabaseConnection && model.current?.id == sessionID && model.turns.first?.id == turnID && model.question == "保留此草稿"
    model.databaseConnectionSource.readGroups = healthyReadGroups
    model.connect(userInitiated: true); try await wait(model)

    let recovering = AppModel(testMode: true); recovering.root = accountA
    var recoveryReads = 0
    recovering.databaseConnectionSource = .init(readManifest: { _ in
        recoveryReads += 1
        if recoveryReads == 1 { throw ChatError.invalid("合成本机文件暂时不可读") }; return manifest
    }, readGroups: groups)
    recovering.connect(userInitiated: false); try await wait(recovering)
    checks["transient_failure_does_not_claim_connected"] = !recovering.hasDatabaseConnection && !recovering.connecting
    let missing = AppModel(testMode: true); missing.root = accountA
    var missingReads = 0, missingGroupReads = 0, savedFile = false
    missing.databaseConnectionSource = .init(readManifest: { _ in missingReads += 1; return savedFile ? manifest : "" }, readGroups: { root in
        missingGroupReads += 1; return groups(root)
    })
    missing.connect(userInitiated: false); try await wait(missing)
    let invalidFile = AppModel(testMode: true); invalidFile.root = accountA
    var invalidFileReads = 0
    invalidFile.databaseConnectionSource = .init(readManifest: { _ in invalidFileReads += 1; throw CredentialStore.Failure.invalidFile }, readGroups: groups)
    invalidFile.connect(userInitiated: false); try await wait(invalidFile)
    try await Task.sleep(for: .milliseconds(2_050))
    recovering.connect(userInitiated: false); try await wait(recovering)
    checks["transient_credential_failure_recovers_silently"] = recovering.hasDatabaseConnection && recoveryReads == 2
    missing.connect(userInitiated: false); invalidFile.connect(userInitiated: false)
    try await wait(missing); try await wait(invalidFile)
    checks["missing_credential_file_waits_for_setup_without_reading_database"] = missingReads == 1 && missingGroupReads == 0 && !missing.hasDatabaseConnection && missing.setupLog.contains("保存")
    checks["invalid_credential_file_does_not_retry_until_explicit_action"] = invalidFileReads == 1 && !invalidFile.hasDatabaseConnection && invalidFile.setupLog.contains("校验")
    savedFile = true; missing.connect(userInitiated: true); try await wait(missing)
    checks["explicit_verification_uses_newly_saved_local_file"] = missing.hasDatabaseConnection && missingReads == 2 && missingGroupReads == 1

    let imported = AppModel(testMode: true); imported.root = accountA
    imported.databaseConnectionSource = .init(readManifest: { _ in manifest }, readGroups: { root in
        try await Task.sleep(for: .milliseconds(30)); return groups(root)
    })
    imported.connect(userInitiated: false)
    let session = ChatImporter.demo(); imported.select(session)
    try await wait(imported)
    checks["background_connection_does_not_replace_selected_local_record"] = imported.hasDatabaseConnection && !imported.live && imported.current?.id == session.id
    imported.connect(userInitiated: true); try await wait(imported)
    checks["explicit_verification_can_return_from_local_record_to_database"] = imported.hasDatabaseConnection && imported.live && imported.current?.id != session.id

    let range = try TimeWindow(start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 1_100))
    func records(_ root: String, _ chat: String) -> DBRead {
        .init(account: DatabaseBridge.account(root), chat: chat, name: "合成连接检查", scannedShards: 1, omittedMedia: 0, completeLocalQuery: true, messages: [])
    }
    var readAttempts: [(String, String, Date, Date)] = []
    model.databaseConnectionSource.readMessages = { root, chat, range in
        readAttempts.append((root, chat, range.start, range.end))
        if readAttempts.count == 1 { throw ChatError.invalid("合成暂时读库失败") }
        return records(root, chat)
    }
    _ = try await model.readDatabaseRecords(root: accountA, chat: "synthetic-a", window: range)
    checks["message_retry_keeps_exact_account_conversation_and_time_range"] = readAttempts.count == 2 && readAttempts.allSatisfy { $0.0 == accountA && $0.1 == "synthetic-a" && $0.2 == range.start && $0.3 == range.end }
    checks["successful_query_retry_restores_database_health"] = model.hasDatabaseConnection && !model.messageQueryNeedsVerification
    var failedReads = 0
    model.databaseConnectionSource.readMessages = { _, _, _ in failedReads += 1; throw ChatError.invalid("合成持续读库失败") }
    do { _ = try await model.readDatabaseRecords(root: accountA, chat: "synthetic-a", window: range); checks["message_query_failure_marks_connection_unhealthy"] = false }
    catch { checks["message_query_failure_marks_connection_unhealthy"] = failedReads == 2 && !model.hasDatabaseConnection && model.messageQueryNeedsVerification }
    model.connect(userInitiated: false); try await wait(model)
    checks["contact_verification_does_not_claim_failed_message_query_recovered"] = !model.hasDatabaseConnection && model.messageQueryNeedsVerification && !model.groups.isEmpty
    checks["query_failure_and_recheck_preserve_answer_and_draft"] = model.current?.id == sessionID && model.turns.first?.id == turnID && model.question == "保留此草稿"
    model.databaseConnectionSource.readMessages = { root, chat, _ in records(root, chat) }
    _ = try await model.readDatabaseRecords(root: accountA, chat: "synthetic-a", window: range)
    checks["later_successful_message_query_clears_pending_verification"] = model.hasDatabaseConnection && !model.messageQueryNeedsVerification
    model.config.endpoint = "ftp://invalid.example"; model.config.consentEndpoint = model.config.endpoint
    model.ask()
    for _ in 0..<100 { if !model.busy { break }; try await Task.sleep(for: .milliseconds(5)) }
    checks["model_configuration_error_does_not_invalidate_database"] = !model.busy && !model.error.isEmpty && model.hasDatabaseConnection && !model.messageQueryNeedsVerification

    var wrongScopeReads = 0
    model.databaseConnectionSource.readMessages = { _, chat, _ in wrongScopeReads += 1; return records(accountB, chat) }
    do { _ = try await model.readDatabaseRecords(root: accountA, chat: "synthetic-a", window: range); checks["wrong_account_response_cannot_mark_query_healthy"] = false }
    catch { checks["wrong_account_response_cannot_mark_query_healthy"] = wrongScopeReads == 2 && !model.hasDatabaseConnection && model.messageQueryNeedsVerification }

    let switched = AppModel(testMode: true); switched.root = accountA
    var beganA = false
    switched.databaseConnectionSource = .init(readManifest: { _ in manifest }, readGroups: { root in
        if root == accountA { beganA = true; try? await Task.sleep(for: .milliseconds(150)) }
        return groups(root)
    })
    switched.connect(userInitiated: false)
    for _ in 0..<50 { if beganA { break }; try await Task.sleep(for: .milliseconds(5)) }
    switched.selectDatabaseRoot(accountB); switched.connect(userInitiated: false); try await wait(switched)
    try await Task.sleep(for: .milliseconds(180))
    checks["late_result_cannot_restore_previous_account"] = beganA && switched.hasDatabaseConnection && switched.groups.map(\.id) == ["synthetic-b"] && !switched.connecting
    return checks
}
