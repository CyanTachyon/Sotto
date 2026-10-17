import AppKit
import ChatCore
import SwiftUI
import UniformTypeIdentifiers

struct AnswerTurn: Identifiable {
    let id = UUID()
    let question: String
    let answer: GroundedAnswer
    let snapshot: Snapshot
}

@MainActor final class AppModel: ObservableObject {
    let isDevelopmentMode: Bool
    @Published var sessions: [ChatSession] = []
    @Published var current: ChatSession?
    @Published var groups: [DBGroup] = []
    @Published var groupID = ""
    @Published var root = UserDefaults.standard.string(forKey: "databaseRoot") ?? ""
    @Published var autoFollow = (UserDefaults.standard.object(forKey: "followCurrentConversationV4") as? Bool) ?? true
    @Published var companionEnabled = true {
        didSet { if !isDevelopmentMode && !companionEnabled { companionEnabled = true } }
    }
    @Published var companionExpanded = false
    // Development fixtures can render the conversation without a WeChat window.
    var isStandaloneConversationVisible: () -> Bool = { false }
    var followForegroundIsRelevant: () -> Bool = { WeChatWindow.isRelevantForeground }
    var followAXReader: ([DBGroup]) -> CurrentWeChat.Detection = { CurrentWeChat.detect(from: $0) }
    @Published var streamingText = ""
    @Published var streamingRevision = 0
    @Published var pendingQuestion = ""
    private var pendingInput = ""
    private var streamingSnapshot: Snapshot?
    private var identityTask: Task<Void, Never>?
    private var identityGeneration = UUID()
    @Published var followState = "not_checked"
    @Published var followMessage = ""
    private var followVisited = 0
    private var followEvidence = 0
    private var followRoleCounts: [String:Int] = [:]
    private var groundingState = "not_checked"
    @Published var evidenceMessages: [ChatMessage]?
    @Published var identity = "尚未连接微信数据库"
    @Published var question = ""
    @Published var range = 1800
    static let timePresets: [(Int, String)] = [(900,"最近 15 分钟"),(1800,"最近 30 分钟"),(3600,"最近 1 小时"),(10800,"最近 3 小时"),(18000,"最近 5 小时"),(43200,"最近 12 小时"),(86400,"最近 1 天"),(259200,"最近 3 天"),(604800,"最近 7 天"),(0,"自定义")]
    @Published var imageSummary = ""
    private var frozenImages: [ModelImage] = []
    private var imageConfig: ModelConfig?
    @Published var start = Date().addingTimeInterval(-1800)
    @Published var end = Date()
    @Published var includeUnknown = false
    @Published var turns: [AnswerTurn] = []
    @Published var phase = "就绪"
    @Published var busy = false
    @Published var error = ""
    @Published var showSettings = false
    @Published var showConnection = false { didSet { if showConnection { resumeAutomaticConnection() } } }
    @Published var showSources = false
    @Published var pinned = (UserDefaults.standard.object(forKey: "explicitPinChoiceV2") as? Bool) ?? false
    @Published var config = ModelConfig()
    @Published var initializing = false
    @Published var setupLog = ""
    @Published var connecting = false
    @Published var detecting = false
    @Published var discoveredAccounts: [DiscoveredAccount] = []
    @Published var discoveryState = "not_checked"
    @Published var discoveryMessage = "可以自动找到此 Mac 上的微信数据，无需了解文件夹路径。"
    var assistanceActive = false
    private var discoveredShardCount = 0
    private var databaseKeyCount = 0
    private var credentialState = "not_checked"
    private var connectedDatabaseRoot: String?
    @Published private(set) var messageQueryNeedsVerification = false
    private var connectionRecovery = ConnectionRecovery()
    private var connectionGeneration = UUID()
    private var connectionTask: Task<Void, Never>?
    private var connectionRecoveryEnabled = true
    private var connectionObservers: [(NotificationCenter, NSObjectProtocol)] = []
    var databaseConnectionSource = DatabaseConnectionSource()
    @Published var evidenceSelection: ChatMessage?
    var local: LocalStore?
    private var fence = RequestFence()
    private var operation: UUID?
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var frozen: Snapshot?
    private struct ConversationDraft {
        let current: ChatSession?; let frozen: Snapshot?; let turns: [AnswerTurn]; let question: String
        let range: Int; let start: Date; let end: Date; let images: [ModelImage]; let imageConfig: ModelConfig?; let imageSummary: String
    }
    private var drafts: [String: ConversationDraft] = [:]
    private func draftKey(_ id: String) -> String { root + "\u{1f}" + id }
    private let client = ModelClient()
    var live = false

    init(testMode: Bool = false) {
        isDevelopmentMode = testMode
        connectionRecoveryEnabled = !testMode
        if let data = UserDefaults.standard.data(forKey: "modelConfig"), let value = try? JSONDecoder().decode(ModelConfig.self, from: data) { config = value }
        if testMode { root = ""; pinned = false; autoFollow = false; companionEnabled = false; if CommandLine.arguments.contains("--ui-test") { config = ModelConfig(); root = "" } }
        if !testMode {
            do { local = try LocalStore(); sessions = try local?.load().filter { $0.origin == .imported } ?? [] }
            catch { self.error = "本地导入缓存读取失败，可在设置中清理后重试。" }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollIdentity(); self?.recoverDatabaseConnectionIfNeeded() }
        }
        if !testMode {
            for (center, name) in [(NotificationCenter.default, NSApplication.didBecomeActiveNotification), (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification)] {
                let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.resumeAutomaticConnection() }
                }
                connectionObservers.append((center, token))
            }
        }
    }
    deinit { for (center, token) in connectionObservers { center.removeObserver(token) }; timer?.invalidate() }
    var selectedGroup: DBGroup? { groups.first { $0.id == groupID } }
    var isDatabase: Bool { live }
    var hasDatabaseConnection: Bool { !root.isEmpty && connectedDatabaseRoot == root && !messageQueryNeedsVerification }
    var frozenSnapshot: Snapshot? { frozen }
    var displayedMessages: [ChatMessage] { frozen?.messages ?? current?.messages ?? [] }
    var canAsk: Bool { !busy && (!live ? current != nil : selectedGroup != nil && (!autoFollow || followState == "confirmed")) }
    var canStartNewConversation: Bool {
        busy || !question.isEmpty || !turns.isEmpty || !streamingText.isEmpty || !pendingQuestion.isEmpty ||
            frozen != nil || (live && current != nil) || evidenceSelection != nil || evidenceMessages != nil ||
            !frozenImages.isEmpty || imageConfig != nil || !imageSummary.isEmpty
    }
    var receiver: String { (try? config.url().host) ?? "未设置模型服务" }

    func invalidate(clear: Bool = true) {
        operation = nil; task?.cancel(); task = nil; fence.cancel(); busy = false; pendingInput = ""
        phase = "就绪"
        if clear { streamingText = ""; streamingSnapshot = nil; pendingQuestion = ""; frozenImages = []; imageConfig = nil; imageSummary = ""; frozen = nil; turns = []; evidenceSelection = nil; evidenceMessages = nil }
    }
    func select(_ session: ChatSession) {
        guard isDevelopmentMode || session.origin != .demo else { return }
        stashConversation(); invalidate(); question = ""; live = false; autoFollow = false; groupID = ""; current = session
        fence.select(session.id); identity = session.origin == .demo ? "演示模式 · 全部为虚构消息" : "导入记录 · 独立会话"
    }
    private func preservePartial(_ note: String) {
        guard let snapshot = streamingSnapshot, !streamingText.isEmpty else { return }
        if let answer = try? GroundedAnswer.validate(Data((streamingText + "\n\n（" + note + "）").utf8), snapshot: snapshot) {
            turns.append(AnswerTurn(question: pendingQuestion, answer: answer, snapshot: snapshot))
        }
        streamingText = ""; streamingSnapshot = nil; pendingQuestion = ""
    }
    private func stashConversation() {
        guard live, !groupID.isEmpty else { return }
        let draftQuestion = busy && question.isEmpty ? pendingInput : question
        preservePartial("生成已停止，以上为已收到的部分回答")
        drafts[draftKey(groupID)] = ConversationDraft(current: current, frozen: frozen, turns: turns, question: draftQuestion, range: range, start: start, end: end, images: frozenImages, imageConfig: imageConfig, imageSummary: imageSummary)
    }
    func selectGroup(_ id: String, automatic: Bool = false) {
        if groupID != id { stashConversation(); invalidate(); current = nil; question = ""; groupID = id
            if let saved = drafts[draftKey(id)] {
                current = saved.current; frozen = saved.frozen; turns = saved.turns; question = saved.question
                range = saved.range; start = saved.start; end = saved.end; frozenImages = saved.images; imageConfig = saved.imageConfig; imageSummary = saved.imageSummary
                if let current { fence.select(current.id) }
            }
        }
        live = true
        if !automatic { autoFollow = false; UserDefaults.standard.set(false, forKey: "followCurrentConversationV4"); UserDefaults.standard.set(id, forKey: "selectedDatabaseGroupV3") }
        identity = id.isEmpty ? "尚未确认当前会话" : (autoFollow ? "跟随微信当前会话" : "已固定此会话")
    }
    func setCompanionEnabled(_ enabled: Bool) {
        companionEnabled = isDevelopmentMode ? enabled : true
    }
    func inspectFollow() async -> CurrentWeChat.Detection {
        let detected = await resolveFollow()
        followState = detected.state; followMessage = detected.message
        followVisited = detected.visited; followEvidence = detected.evidenceCount; followRoleCounts = detected.roleCounts
        return detected
    }
    private func resolveFollow() async -> CurrentWeChat.Detection {
        followAXReader(groups)
    }
    private func verifiedCurrentID() async -> String? {
        guard followForegroundIsRelevant() else { return nil }
        let result = await resolveFollow()
        return result.state == "confirmed" ? result.group?.id : nil
    }
    func applyFollowDetection(_ detected: CurrentWeChat.Detection) {
        followState = detected.state; followMessage = detected.message
        followVisited = detected.visited; followEvidence = detected.evidenceCount; followRoleCounts = detected.roleCounts
        let id = detected.state == "confirmed" ? detected.group?.id : nil
        // Keep the previous answer visible while identity is temporarily unavailable.
        // canAsk blocks sending until current identity is confirmed again.
        if let id, id != groupID { selectGroup(id, automatic: true) }
        identity = detected.message
    }
    func pollIdentity() {
        guard live, autoFollow, !groups.isEmpty, identityTask == nil, followForegroundIsRelevant() else { return }
        if companionEnabled && !companionExpanded && !(isDevelopmentMode && isStandaloneConversationVisible()) { return }
        let expectedRoot = root; let generation = identityGeneration
        identityTask = Task { [weak self] in
            guard let self else { return }
            defer { if identityGeneration == generation { identityTask = nil } }
            let detected = await resolveFollow()
            guard !Task.isCancelled, live, autoFollow, root == expectedRoot, generation == identityGeneration else { return }
            applyFollowDetection(detected)
        }
    }
    func followChanged() {
        UserDefaults.standard.set(autoFollow, forKey: "followCurrentConversationV4")
        identityGeneration = UUID(); identityTask?.cancel(); identityTask = nil
        if autoFollow { live = true; followState = "checking"; identity = "正在核对微信当前会话…"; pollIdentity() }
        else { identity = "已固定此会话" }
        writeConnectionStatus()
    }
    func window() throws -> TimeWindow {
        let now = Date()
        // The date pickers expose minutes; discard hidden seconds from their initial Date values.
        let customStart = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 60) * 60)
        let customEnd = Date(timeIntervalSince1970: floor(end.timeIntervalSince1970 / 60) * 60)
        return try TimeWindow(start: range == 0 ? customStart : now.addingTimeInterval(-Double(range)), end: range == 0 ? customEnd : now)
    }
    func startNewConversation() {
        identityGeneration = UUID(); identityTask?.cancel(); identityTask = nil
        invalidate()
        question = ""; error = ""; groundingState = "not_checked"; showSources = false
        // Imported records are the selected source, not AI conversation history.
        // Database records are reread for the next fresh time snapshot.
        if live { current = nil }
        fence.select(current?.id)
        stashConversation()
    }
    func resetQuestion() { startNewConversation() }

    func ask() {
        guard canAsk else { return }
        let submittedQuestion = question
        let text = submittedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        streamingText = ""; pendingQuestion = text; pendingInput = submittedQuestion; streamingSnapshot = nil
        error = ""; busy = true; phase = live && frozen == nil ? "正在读取加密数据库快照…" : "正在准备问题…"
        let op = UUID(); operation = op
        let requestConfig = config
        let expectedGroup = groupID; let expectedLive = live; let imported = current
        task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try requestConfig.url()
                guard requestConfig.consentEndpoint == requestConfig.endpoint else { throw ChatError.invalid("请先在模型设置中允许发送当前快照。") }
                guard self.operation == op else { return }
                if self.question == submittedQuestion { self.question = "" }
                if expectedLive && self.autoFollow {
                    guard await self.verifiedCurrentID() == expectedGroup else { throw ChatError.invalid("微信当前会话无法确认或已经改变，请重新绑定。") }
                }
                let snapshot: Snapshot
                if let frozen = self.frozen { snapshot = frozen }
                else if expectedLive {
                    let window = try self.window()
                    let result = try await self.readDatabaseRecords(root: self.root, chat: expectedGroup, window: window)
                    guard self.operation == op, self.groupID == expectedGroup, self.live else { return }
                    let account = DatabaseBridge.account(self.root)
                    let session = try await Task.detached { try result.session(expectedAccount: account, expectedChat: expectedGroup, window: window) }.value
                    try Task.checkCancellation()
                    guard self.operation == op, self.groupID == expectedGroup, self.live else { return }
                    self.current = session; self.fence.select(session.id)
                    snapshot = try await Task.detached { try Snapshot(session: session, window: window, includeUnknown: false) }.value
                } else {
                    guard let imported else { throw ChatError.invalid("请先连接数据。") }
                    snapshot = try Snapshot(session: imported, window: self.window(), includeUnknown: self.includeUnknown)
                }
                try Task.checkCancellation()
                guard self.operation == op else { return }
                if expectedLive && self.autoFollow {
                    guard await self.verifiedCurrentID() == expectedGroup else { throw ChatError.invalid("读取期间微信切换了会话，已丢弃这次结果。") }
                }
                try Task.checkCancellation()
                guard self.operation == op else { return }
                let token = try self.fence.begin(sessionID: snapshot.sessionID)
                self.frozen = snapshot; self.phase = "AI 正在回答 · 快照已固定…"
                if self.imageConfig != requestConfig {
                    let prepared = await ImageLoader.prepare(snapshot: snapshot, root: self.root, config: requestConfig, chat: expectedGroup)
                    try Task.checkCancellation()
                    guard self.operation == op else { return }
                    self.frozenImages = prepared.images; self.imageSummary = prepared.summary; self.imageConfig = requestConfig
                }
                let key = try await CredentialStore.readAsync(endpoint: requestConfig.endpoint)
                try Task.checkCancellation()
                guard self.operation == op else { return }
                let history = self.turns.filter { $0.snapshot.id == snapshot.id }.map { Followup(question: $0.question, answer: $0.answer) }
                self.streamingSnapshot = snapshot; self.phase = "正在生成回答…"
                let answer = try await self.client.ask(snapshot: snapshot, question: text, history: history, config: requestConfig, key: key, images: self.frozenImages) { [weak self] content in
                    await self?.receiveStream(content, operation: op, conversation: expectedGroup)
                }
                try Task.checkCancellation()
                guard self.operation == op, self.fence.accepts(token: token, sessionID: snapshot.sessionID) else { return }
                if expectedLive && self.autoFollow && WeChatWindow.isRelevantForeground {
                    guard await self.verifiedCurrentID() == expectedGroup else { throw ChatError.invalid("回答完成时当前会话已改变或无法确认，已丢弃回答。") }
                }
                try Task.checkCancellation()
                guard self.operation == op, self.fence.accepts(token: token, sessionID: snapshot.sessionID) else { return }
                self.streamingText = ""; self.streamingSnapshot = nil; self.pendingQuestion = ""; self.pendingInput = ""
                self.turns.append(AnswerTurn(question: text, answer: answer, snapshot: snapshot))
                self.phase = "回答完成 · 可继续追问"; self.busy = false; self.operation = nil
                self.groundingState = "natural_answer_displayed"; self.writeConnectionStatus()
            } catch is CancellationError {
                if self.operation == op { self.busy = false; self.phase = "已取消"; self.operation = nil }
            } catch {
                guard self.operation == op else { return }
                if self.question.isEmpty { self.question = submittedQuestion }
                self.preservePartial("生成未完成，已保留部分回答")
                self.pendingQuestion = ""; self.pendingInput = ""
                self.error = error.localizedDescription; self.busy = false; self.phase = "未完成"; self.operation = nil
                self.groundingState = "request_error"; self.writeConnectionStatus()
            }
        }
    }
    private func receiveStream(_ content: String, operation expected: UUID, conversation: String) {
        guard operation == expected, groupID == conversation else { return }
        streamingText = content; streamingRevision += 1
    }
    func readDatabaseRecords(root selectedRoot: String, chat: String, window: TimeWindow) async throws -> DBRead {
        // Keep the exact requested account, conversation, and time bounds for both
        // attempts. Model requests and identity checks are outside this retry path.
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                guard root == selectedRoot else { throw CancellationError() }
                let result = try await databaseConnectionSource.readMessages(selectedRoot, chat, window)
                try Task.checkCancellation()
                guard root == selectedRoot else { throw CancellationError() }
                guard result.account == DatabaseBridge.account(selectedRoot), result.chat == chat, result.completeLocalQuery,
                      result.messages.allSatisfy({ window.contains(Date(timeIntervalSince1970: Double($0.timestamp))) }) else {
                    throw ChatError.invalid("数据库返回了范围外数据或其他账号/会话，已拒绝载入。")
                }
                let recoveredQuery = messageQueryNeedsVerification
                messageQueryNeedsVerification = false
                if !groups.isEmpty { connectedDatabaseRoot = selectedRoot; connectionRecovery.succeeded() }
                if recoveredQuery { setupLog = "聊天分库查询已恢复，可继续当前问题。" }
                credentialState = "message_query_verified"; writeConnectionStatus()
                return result
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                guard root == selectedRoot else { throw CancellationError() }
                messageQueryNeedsVerification = true; connectedDatabaseRoot = nil; credentialState = "message_query_failed"
                if !connecting { connectionRecovery = ConnectionRecovery() }
                setupLog = "上次聊天分库查询未通过；联系人库复检成功也不代表聊天分库已经恢复。原问题和已有回答已保留。"
                writeConnectionStatus()
                if attempt == 0 { try await Task.sleep(for: .milliseconds(250)) }
                else { throw ChatError.invalid("聊天记录读取失败，已自动重试一次。\(error.localizedDescription)") }
            }
        }
        throw CancellationError()
    }
    func cancel() {
        let originalInput = pendingInput, previousTurns = turns.count
        preservePartial("已停止生成")
        if turns.count == previousTurns && question.isEmpty { question = originalInput }
        streamingText = ""; streamingSnapshot = nil; pendingQuestion = ""
        invalidate(clear: false); phase = "已停止"
    }

    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .plainText]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey]); guard (values.fileSize ?? Int.max) <= 100_000_000 else { throw ChatError.invalid("导入文件超过 100 MB。") }
                let session = try ChatImporter.parse(String(contentsOf: url, encoding: .utf8), filename: url.lastPathComponent)
                sessions.insert(session, at: 0); sessions = Array(sessions.prefix(20)); try local?.save(sessions)
                select(session); range = 0
                start = session.messages.compactMap(\.timestamp).min() ?? Date(); end = session.messages.compactMap(\.timestamp).max() ?? Date()
                error = ""
            } catch { self.error = error.localizedDescription }
        }
    }
    func loadSyntheticPreview() throws {
        guard isDevelopmentMode else { throw ChatError.invalid("合成预览仅用于开发与测试。") }
        let snapshot = try SyntheticScenario.snapshot()
        current = try ChatSession(id: snapshot.sessionID, name: snapshot.sessionName, origin: .demo, sourceDescription: "完全虚构的界面验收样例", messages: snapshot.messages)
        frozen = snapshot; fence.select(snapshot.sessionID)
        turns = [AnswerTurn(question: "过去半小时发生了什么？", answer: try GroundedAnswer.validate(SyntheticScenario.narrative(snapshot), snapshot: snapshot), snapshot: snapshot)]
        identity = "虚构界面样例 · 不是模型实测回答"
    }
    func demo() {
        guard isDevelopmentMode else { return }
        let session = ChatImporter.demo(); sessions.removeAll { $0.origin == .demo }; sessions.insert(session, at: 0)
        select(session); range = 1800
    }
    func setPinnedByUser(_ value: Bool) {
        pinned = value; UserDefaults.standard.set(value, forKey: "explicitPinChoiceV2")
    }
    func assistSetup(openPermissions: Bool = true, presentConnection: Bool = false) {
        guard !detecting, !initializing, !connecting else { return }
        assistanceActive = true; if presentConnection { showConnection = true }; detecting = true
        discoveryState = "checking"; discoveryMessage = "正在由群聊伴读自动检测本机微信数据…"
        writeConnectionStatus()
        Task {
            let result = await Task.detached { AccountDiscovery.scan() }.value
            detecting = false; discoveredAccounts = result.accounts
            discoveryState = result.state.rawValue
            switch result.state {
            case .available:
                if let saved = result.accounts.first(where: { $0.root.path == root }) { useDiscoveredAccount(saved) }
                else if result.accounts.count == 1 { useDiscoveredAccount(result.accounts[0]) }
                else {
                    discoveryMessage = "找到 \(result.accounts.count) 个本机微信账号，请在下方选择本人要使用的账号。"
                    writeConnectionStatus()
                }
            case .permissionRequired:
                discoveryMessage = "macOS 暂未允许群聊伴读读取微信数据。请给“群聊伴读”开启完全磁盘访问，不需要给 Codex 授权。"
                setupLog = "授权完成后点击“授权后继续检测”，应用会自动选择唯一账号并检查已有密钥。"
                writeConnectionStatus()
                if openPermissions { openDataPermissionSettings() }
            case .notFound:
                discoveryMessage = "未找到本机已同步的微信数据。请先在原版微信登录本人账号，或从“其他位置”选择已移动的数据目录。"
                writeConnectionStatus()
            case .unavailable:
                discoveryMessage = "暂时无法检查微信数据，请检查磁盘访问权限后重试。"
                writeConnectionStatus()
            }
        }
    }
    func useDiscoveredAccount(_ account: DiscoveredAccount) {
        guard !initializing else { return }
        selectDatabaseRoot(account.root.path)
        discoveredShardCount = account.messageShards
        discoveryState = "available"; discoveryMessage = "已自动定位微信数据，找到 \(account.messageShards) 个聊天分库。"
        guard connectedDatabaseRoot != root else { writeConnectionStatus(); return }
        if !connecting { connectionRecovery = ConnectionRecovery(); connect(userInitiated: false) }
    }

    func selectDatabaseRoot(_ selectedRoot: String) {
        guard root != selectedRoot else { return }
        stashConversation(); invalidate(); groups = []; groupID = ""; current = nil; live = false
        identityGeneration = UUID(); identityTask?.cancel(); identityTask = nil
        connectionGeneration = UUID(); connectionTask?.cancel(); connectionTask = nil; connecting = false
        connectedDatabaseRoot = nil; messageQueryNeedsVerification = false; connectionRecovery = ConnectionRecovery()
        databaseKeyCount = 0; credentialState = "not_checked"
        root = selectedRoot; UserDefaults.standard.set(root, forKey: "databaseRoot")
    }

    func resumeAutomaticConnection() {
        guard connectionRecoveryEnabled, connectedDatabaseRoot != root else { return }
        connectionRecovery.resume()
        recoverDatabaseConnectionIfNeeded()
    }

    private func recoverDatabaseConnectionIfNeeded() {
        guard connectionRecoveryEnabled, !root.isEmpty, connectedDatabaseRoot != root,
              !connecting, !detecting, !initializing, !busy,
              let next = connectionRecovery.nextAttemptAt, Date() >= next else { return }
        connect(userInitiated: false)
    }

    func openDataPermissionSettings() {
        // Finder selects the exact running app, avoiding authorization of another extracted copy.
        for window in NSApp.windows where window is MainWindow { window.orderOut(nil) }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
        }
    }
    func writeConnectionStatus() {
        guard let local else { return }
        let action: String
        if discoveryState == "permissionRequired" { action = "enable_full_disk_access_for_ChatFloat" }
        else if discoveryState == "checking" { action = "wait_for_app_data_access_prompt" }
        else if !discoveredAccounts.isEmpty && root.isEmpty { action = "select_own_account" }
        else if hasDatabaseConnection { action = "database_connected" }
        else if connecting { action = "connecting_automatically" }
        else if !root.isEmpty && connectionRecovery.nextAttemptAt != nil { action = "retrying_connection_automatically" }
        else if messageQueryNeedsVerification { action = "retry_message_query" }
        else if ["credential_file_unavailable", "credential_file_invalid"].contains(credentialState) { action = "check_local_credential_file" }
        else if !root.isEmpty && databaseKeyCount == 0 { action = "save_database_credentials" }
        else { action = "continue_in_connection_window" }
        let status: [String: Any] = ["appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "bundlePath": Bundle.main.bundleURL.path, "dataAccess": discoveryState,
            "accountCandidateCount": discoveredAccounts.count, "accountSelected": !root.isEmpty,
            "messageShardCount": discoveredShardCount, "databaseKeyCount": databaseKeyCount,
            "credentialState": credentialState, "groupCount": groups.count, "databaseConnected": hasDatabaseConnection,
            "contactDatabaseVerified": connectedDatabaseRoot == root, "messageQueryNeedsVerification": messageQueryNeedsVerification,
            "connectionAttemptCount": connectionRecovery.attemptCount, "connectionRetryScheduled": connectionRecovery.nextAttemptAt != nil,
            "accessibilityGranted": CurrentWeChat.trusted, "modelConfigured": !config.endpoint.isEmpty && !config.model.isEmpty,
            "followState": followState, "followNodesVisited": followVisited, "followEvidenceCount": followEvidence,
            "followRoleCounts": followRoleCounts, "autoFollow": autoFollow, "groupSelected": !groupID.isEmpty, "groundingState": groundingState,
            "companionEnabled": companionEnabled, "supportsVision": config.supportsVision, "contextTokens": config.contextTokens, "credentialFiles": CredentialStore.diagnosticCounts, "answerTurnCount": turns.count, "initializing": initializing, "userAction": action, "checkedAt": Display.iso(Date())]
        let target = local.directory.appendingPathComponent("connection-status.json")
        do {
            try JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]).write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch { /* Diagnostics must never disrupt configuration or print credentials. */ }
    }
    func chooseRoot() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.message = "选择本人账号的 db_storage 文件夹。不同账号的密钥分别保存。"
        if picker.runModal() == .OK, let url = picker.url {
            guard url.lastPathComponent == "db_storage" else { error = "请选择账号目录内的 db_storage 文件夹。"; return }
            selectDatabaseRoot(url.resolvingSymlinksInPath().path)
            identity = "尚未连接所选账号数据库"
            connectionRecovery = ConnectionRecovery(); connect(userInitiated: false)
        }
    }
    func connect(userInitiated: Bool = true) {
        guard !root.isEmpty, !connecting, !initializing,
              connectionRecovery.begin(userInitiated: userInitiated) else { return }
        let selectedRoot = root, generation = connectionGeneration
        let alreadyConnected = connectedDatabaseRoot == selectedRoot
        connecting = true
        if !alreadyConnected, current == nil { identity = "正在自动连接微信数据库…" }
        if userInitiated { error = "" }
        writeConnectionStatus()
        connectionTask = Task {
            defer {
                if connectionGeneration == generation { connecting = false; connectionTask = nil; writeConnectionStatus() }
            }
            var readCredential = false
            do {
                let manifest = try await databaseConnectionSource.readManifest(selectedRoot)
                guard root == selectedRoot, connectionGeneration == generation, !Task.isCancelled else { return }
                readCredential = true
                guard !manifest.isEmpty else {
                    databaseKeyCount = 0; credentialState = "missing"
                    throw ChatError.invalid("此账号尚未保存本机数据库密钥。请导入逐库密钥清单，或完成首次初始化。")
                }
                guard let bytes = manifest.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let keys = object["keys"] as? [String: Any], !keys.isEmpty else {
                    databaseKeyCount = 0; credentialState = "credential_file_invalid"
                    throw ChatError.invalid("此账号的本机密钥清单无效，请检查后重新导入。")
                }
                databaseKeyCount = keys.count; credentialState = "present_unverified"
                let result = try await databaseConnectionSource.readGroups(selectedRoot)
                guard root == selectedRoot, connectionGeneration == generation, !Task.isCancelled else { return }
                guard result.account == DatabaseBridge.account(selectedRoot) else { throw ChatError.invalid("数据库账号校验不一致，已停止连接。") }
                groups = result.groups.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                connectedDatabaseRoot = selectedRoot; connectionRecovery.succeeded()
                credentialState = "contact_database_verified"; discoveryState = "available"
                setupLog = messageQueryNeedsVerification
                    ? "会话列表已验证，但上次聊天内容查询尚未通过。请重试原问题；聊天查询成功后才恢复正常状态。"
                    : "已验证本机聊天记录，找到 \(groups.count) 个有记录的会话。"
                if !messageQueryNeedsVerification { error = "" }
                // Rechecking the same account must not clear answers, drafts, or an
                // imported session the user deliberately selected while connecting.
                if !live, current != nil, current?.origin != .database {
                    guard userInitiated else { return }
                    invalidate(); current = nil
                }
                live = true
                if !groupID.isEmpty, groups.contains(where: { $0.id == groupID }) { return }
                if !groupID.isEmpty { selectGroup("", automatic: autoFollow) }
                identity = "数据库已连接 · 请选择会话或启用跟随"
                if autoFollow { pollIdentity() }
                else if let saved = UserDefaults.standard.string(forKey: "selectedDatabaseGroupV3"), groups.contains(where: { $0.id == saved }) { selectGroup(saved) }
            } catch {
                guard root == selectedRoot, connectionGeneration == generation, !Task.isCancelled else { return }
                connectedDatabaseRoot = nil; connectionRecovery.failed()
                if !readCredential {
                    databaseKeyCount = 0
                    let failure = error as? CredentialStore.Failure
                    credentialState = failure == .invalidFile || failure == .invalidManifest || failure == .invalidInput
                        ? "credential_file_invalid" : "credential_file_unavailable"
                }
                if ["missing", "credential_file_invalid"].contains(credentialState) { connectionRecovery.suspend() }
                self.error = error.localizedDescription
                if current == nil { identity = connectionRecovery.nextAttemptAt == nil ? "数据库连接未完成" : "正在自动恢复数据库连接…" }
                if credentialState == "missing" {
                    setupLog = "请先保存此账号的数据库密钥，再验证连接。"
                } else if credentialState == "credential_file_invalid" {
                    setupLog = "本机密钥文件未通过校验，请检查文件权限或重新导入有效清单。"
                } else if credentialState == "credential_file_unavailable" {
                    setupLog = "本机密钥文件暂时无法访问，后台会有限次重试；也可检查文件权限后重新验证。"
                } else if connectionRecovery.nextAttemptAt != nil {
                    setupLog = "连接暂未完成，正在自动重试，无需反复点击验证。"
                }
            }
        }
    }
    func importKeys() {
        guard !connecting, !initializing else { return }
        guard !root.isEmpty else { error = "请先选择本人账号的 db_storage。"; return }
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.json]
        picker.message = "仅支持逐库相对路径 → enc_key 的 JSON 清单；表情库单把密钥不能代表聊天分库。"
        if picker.runModal() == .OK, let url = picker.url {
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 1_000_000 else { throw ChatError.invalid("密钥清单过大。") }
                try CredentialStore.saveDatabase(String(decoding: data, as: UTF8.self), account: DatabaseBridge.account(root))
                setupLog = "清单已保存为此账号的本机密钥文件，正在自动验证连接。"
                connectedDatabaseRoot = nil; connectionRecovery = ConnectionRecovery(); connect(userInitiated: false)
            } catch { self.error = error.localizedDescription }
        }
    }
    func removeDatabaseKeys() throws {
        guard !root.isEmpty, !connecting, !initializing else { return }
        try CredentialStore.deleteDatabase(DatabaseBridge.account(root))
        invalidate(); groups = []; groupID = ""; current = nil; live = false
        connectedDatabaseRoot = nil; messageQueryNeedsVerification = false; connectionRecovery.suspend(); databaseKeyCount = 0; credentialState = "missing"
        identity = "此账号的数据库密钥已删除"; setupLog = "此账号密钥已删除。"
        writeConnectionStatus()
    }
    func initializeKeys() {
        guard !root.isEmpty, !initializing, !connecting else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").isEmpty else {
            error = "请先在微信菜单中正常退出微信，再点一次开始。应用不会替你退出。"; return
        }
        initializing = true; setupLog = "启动本地初始化…"; error = ""
        let selectedRoot = root
        let resources = DatabaseBridge.backend
        let executable = Bundle.main.executableURL?.path ?? ""
        let directory = local?.directory.path ?? NSTemporaryDirectory()
        let owner = self
        Task.detached { [owner] in
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, value in value }
            process.arguments = [resources.appendingPathComponent("bootstrap.py").path, "--acknowledge-copy", selectedRoot, executable, directory]
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                var pending = Data()
                while true {
                    let chunk = output.fileHandleForReading.availableData
                    if chunk.isEmpty { break }; pending.append(chunk)
                    while let index = pending.firstIndex(of: 10) {
                        let line = pending.prefix(upTo: index); pending.removeSubrange(...index)
                        if let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                            let text: String
                            if let status = json["status"] as? String { text = status }
                            else if let count = json["verified_databases"] as? Int { text = "已验证 \(count) 个数据库密钥" }
                            else { text = (json["type"] as? String) ?? "初始化处理中" }
                            await MainActor.run { owner.setupLog += "\n" + text }
                        }
                    }
                }
                process.waitUntilExit()
                let ok = process.terminationStatus == 0
                await MainActor.run {
                    owner.initializing = false
                    owner.setupLog += ok ? "\n取钥流程结束，正在自动验证连接。原版微信仍由你自行打开。" : "\n取钥未完整成功。可验证已捕获的密钥覆盖；若失败请保留原版并检查系统许可。"
                    if ok, owner.root == selectedRoot {
                        owner.connectedDatabaseRoot = nil; owner.connectionRecovery = ConnectionRecovery(); owner.connect(userInitiated: false)
                    }
                }
            } catch {
                await MainActor.run { owner.initializing = false; owner.error = "无法启动初始化。请确认已安装 Xcode Command Line Tools。" }
            }
        }
    }
    func clearData() {
        let alert = NSAlert(); alert.messageText = "清理此应用的消息缓存与回答？"; alert.informativeText = "微信原始数据库和已保存的本机密钥文件不受影响。"
        alert.addButton(withTitle: "清理"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            do { try local?.clear(); invalidate(); drafts = [:]; current = nil; sessions = [] } catch { self.error = "清理失败。" }
        }
    }
    func saveConfig(_ value: ModelConfig, key: String) async throws {
        _ = try value.url()
        if !key.isEmpty { try await Task.detached { try CredentialStore.save(key, endpoint: value.endpoint) }.value }
        UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "modelConfig"); config = value; writeConnectionStatus()
    }
}
