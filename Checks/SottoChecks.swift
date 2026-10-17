import Foundation
import SottoCore


// Minimal portable assertions: Apple's CLT distribution here does not include XCTest.
private var failures = 0
private class PortableCheckCase {}
private func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) { failures += 1; print("FAIL \(file):\(line) \(message)") }
private func XCTAssertTrue(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { if !value() { XCTFail("expected true", file: file, line: line) } }
private func XCTAssertFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(!value(), file: file, line: line) }
private func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) rethrows { if try a() != b() { XCTFail("values differ", file: file, line: line) } }
private func XCTAssertNil<T>(_ a: T?, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(a == nil, file: file, line: line) }
private func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try body(); XCTFail("expected error", file: file, line: line) } catch {} }
private func XCTAssertNoThrow<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) { do { _ = try body() } catch { XCTFail("unexpected error", file: file, line: line) } }
private func XCTUnwrap<T>(_ value: T?) throws -> T { guard let value else { throw ChatError.invalid("unwrap failed") }; return value }

private final class CoreTests: PortableCheckCase {
    func testStreamingFramingAndInterruptions() throws {
        var stream = CompletionStream()
        for line in [": keepalive", "event: message", #"data: {"choices":[{"delta":{"reasoning_content":"HIDDEN_REASONING"}}]}"#, "", #"data: {"choices":[{"delta":{"content":"你好 **世"}}]}"#, "", #"data: {"choices":[{"delta":{"content":"界**"},"finish_reason":"stop"}]}"#, "", "data: [DONE]", ""] { try stream.line(line) }
        try stream.end(); XCTAssertEqual(stream.text, "你好 **世界**"); XCTAssertTrue(stream.finished)
        var partial = CompletionStream()
        try partial.line(#"data: {"choices":[{"delta":{"content":"保留片段"}}]}"#); try partial.line("")
        XCTAssertThrowsError(try partial.end()); XCTAssertEqual(partial.text, "保留片段")
        try partial.line("data: not JSON"); XCTAssertThrowsError(try partial.line(""))
    }
    func testMarkdownBlocksAndIncompleteFence() throws {
        let text = "# 标题\n\n**强调** 与 `code`\n\n- 第一项\n  - 嵌套项\n\n> 引用内容\n\n| 人 | 事 |\n| --- | --- |\n| A | B |\n\n```swift\nlet x = 1"
        let blocks = MarkdownBlocks.parse(text)
        XCTAssertTrue(blocks.contains(.heading(1, "标题")))
        XCTAssertTrue(blocks.contains(.item("•", "嵌套项", 1)))
        XCTAssertTrue(blocks.contains(.quote("引用内容")))
        XCTAssertTrue(blocks.contains(.table(["人","事"], [["A","B"]])))
        XCTAssertEqual(blocks.last, .code("swift", "let x = 1"))
        XCTAssertEqual(MarkdownBlocks.cells(#"| a\|b | `c|d` |"#), ["a|b", "`c|d`"])
        XCTAssertEqual(MarkdownBlocks.parse("---"), [.rule])
    }
    func fixture() throws -> (ChatSession, TimeWindow) {
        let id = UUID()
        let messages = [99.0, 100, 150, 200, 201].enumerated().map { i, time in
            ChatMessage(sessionID: id, timestamp: Date(timeIntervalSince1970: time), sender: "成员", text: "真实原文\(i)", source: "fixture", sourceLine: i + 1)
        } + [ChatMessage(sessionID: id, timestamp: nil, sender: nil, text: "未知时间原文", source: "fixture", sourceLine: 6)]
        return (try ChatSession(id: id, name: "人工群", origin: .imported, sourceDescription: "fixture", messages: messages),
                try TimeWindow(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200)))
    }
    func testTimeFilterInclusiveAndUnknownExcluded() throws {
        let (session, window) = try fixture()
        let s = try Snapshot(session: session, window: window, includeUnknown: false)
        XCTAssertEqual(s.messages.count, 3)
        XCTAssertEqual(s.messages.first?.timestamp, window.start); XCTAssertEqual(s.messages.last?.timestamp, window.end)
        let included = try Snapshot(session: session, window: window, includeUnknown: true)
        XCTAssertEqual(included.messages.count, 4); XCTAssertEqual(included.includedUnknownCount, 1)
        XCTAssertTrue(s.coverage.contains("不能证明"))
    }
    func testNoMessagesAndBadRangeReject() throws {
        let (session, _) = try fixture()
        XCTAssertThrowsError(try TimeWindow(start: Date(timeIntervalSince1970: 2), end: Date(timeIntervalSince1970: 1)))
        XCTAssertThrowsError(try Snapshot(session: session, window: TimeWindow(start: .distantFuture, end: .distantFuture), includeUnknown: false))
    }
    func testCrossConversationAndDuplicateIdentityReject() throws {
        let (session, _) = try fixture()
        XCTAssertThrowsError(try ChatSession(id: UUID(), name: "另一个群", origin: .imported, sourceDescription: "fixture", messages: session.messages))
        XCTAssertThrowsError(try ChatSession(id: session.id, name: "群", origin: .imported, sourceDescription: "fixture", messages: [session.messages[0], session.messages[0]]))
    }
    func testDecodingRevalidatesPersistedSessionsAndWindows() throws {
        let (session, window) = try fixture()
        let encoded = try JSONEncoder().encode(session)
        XCTAssertNoThrow(try JSONDecoder().decode(ChatSession.self, from: encoded))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["name"] = "   "
        XCTAssertThrowsError(try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: object)))
        object["name"] = "人工群"
        var messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        messages[1]["id"] = messages[0]["id"]
        object["messages"] = messages
        XCTAssertThrowsError(try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: object)))
        let windowData = try JSONEncoder().encode(window)
        var windowObject = try XCTUnwrap(JSONSerialization.jsonObject(with: windowData) as? [String: Any])
        let start = try XCTUnwrap(windowObject["start"] as? Double)
        windowObject["end"] = start - 10
        XCTAssertThrowsError(try JSONDecoder().decode(TimeWindow.self, from: JSONSerialization.data(withJSONObject: windowObject)))
    }
    func testCompletionStreamBounds() throws {
        var line = CompletionStream(maximumLineBytes: 8, maximumEventBytes: 64)
        var lineRejected = false
        do { for _ in 0..<20 { _ = try line.byte(97) } } catch { lineRejected = true }
        XCTAssertTrue(lineRejected)
        var event = CompletionStream(maximumLineBytes: 100, maximumEventBytes: 8)
        XCTAssertThrowsError(try event.line("data: 123456789"))
    }
    func testLateCompletionFenceSwitchCancelAndNewRequest() throws {
        var f = RequestFence(); let a = UUID(), b = UUID(); f.select(a)
        let first = try f.begin(sessionID: a); XCTAssertTrue(f.accepts(token: first, sessionID: a))
        f.select(b); XCTAssertFalse(f.accepts(token: first, sessionID: a)); XCTAssertThrowsError(try f.begin(sessionID: a))
        let second = try f.begin(sessionID: b); f.cancel(); XCTAssertFalse(f.accepts(token: second, sessionID: b))
        let third = try f.begin(sessionID: b); let fourth = try f.begin(sessionID: b)
        XCTAssertFalse(f.accepts(token: third, sessionID: b)); XCTAssertTrue(f.accepts(token: fourth, sessionID: b))
    }
    func testNaturalAnswerPreservesMarkdownAndLiteralJSON() throws {
        for text in ["## 结论\n\n**自然回答**，结果尚待确认。\n\n```swift\nlet a = 1\n```",
                     #"{"sections":[{"text":"这是要展示的 JSON 示例","source_ids":["M1"]}],"insufficient":"原样展示"}"#,
                     "```json\n{\"claims\":[{\"text\":\"JSON 示例\"}]}\n```"] {
            let result = try GroundedAnswer(validating: Data(text.utf8))
            XCTAssertEqual(result.text, text)
        }
    }
    func testFollowMetadataMissingConflictAndIncomplete() {
        let groups = [TitleCandidate(id: "a", aliases: ["项目群"]), TitleCandidate(id: "b", aliases: ["发布群"]), TitleCandidate(id: "c", aliases: ["同名群"]), TitleCandidate(id: "d", aliases: ["同名群"])]
        XCTAssertEqual(TitleIdentity.resolve([ConversationEvidence("微信", kind: .windowTitle), ConversationEvidence("项目群（42人）", kind: .header)], candidates: groups).id, "a")
        XCTAssertEqual(TitleIdentity.resolve([ConversationEvidence("WeChat - 项目群 (42)", kind: .windowTitle)], candidates: groups).id, "a")
        XCTAssertEqual(TitleIdentity.resolve([], candidates: groups).state, .noMetadata)
        XCTAssertEqual(TitleIdentity.resolve([ConversationEvidence("项目群", kind: .header), ConversationEvidence("私聊对象", kind: .selectedRow)], candidates: groups).state, .unmatched)
        XCTAssertEqual(TitleIdentity.resolve([ConversationEvidence("项目群", kind: .windowTitle), ConversationEvidence("发布群", kind: .selectedRow)], candidates: groups).state, .conflicting)
        XCTAssertEqual(TitleIdentity.resolve([ConversationEvidence("项目群", kind: .windowTitle)], candidates: groups, complete: false).state, .incomplete)
        XCTAssertEqual(TitleIdentity.resolve([ConversationEvidence("同名群（3）", kind: .selectedRow)], candidates: groups).state, .ambiguous)
        XCTAssertNil(TitleIdentity.resolve("项目", candidates: groups))
    }
    func testNoisyEventNarrativeAndFollowup() throws {
        let snapshot = try SyntheticScenario.snapshot()
        let answer = try GroundedAnswer(validating: SyntheticScenario.narrative(snapshot))
        XCTAssertTrue(answer.text.contains("预发")); XCTAssertTrue(answer.text.contains("线上"))
        XCTAssertTrue(answer.text.contains("负责人未定")); XCTAssertFalse(answer.text.contains("咖啡"))
        var config = ModelConfig(); config.model = "synthetic"
        let body = try Prompt.body(snapshot: snapshot, question: "所以15点还开吗？", history: [Followup(question: "过去半小时发生了什么？", answer: answer)], config: config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]!.contains("不要求 JSON"))
        let user = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: Any])
        XCTAssertEqual((user["prior_turns"] as? [Any])?.count, 1)
        let prior = try XCTUnwrap(user["prior_turns"] as? [[String: Any]])
        XCTAssertEqual(prior[0]["answer"] as? String, answer.text)
        let result = try GroundedAnswer(validating: Data("已改到 15:30，客户已同意。".utf8))
        XCTAssertEqual(result.text, "已改到 15:30，客户已同意。")

    }
    func testLongNaturalAndVisionRequests() throws {
        let id = UUID(), now = Date()
        let rows = (0..<6100).map { index in ChatMessage(sessionID: id, timestamp: now.addingTimeInterval(-Double(index)*90), sender: "synthetic", text: String(repeating: "测试正文", count: 6) + " END\(index)", source: "synthetic", sourceLine: index + 1, image: index == 0 ? ChatImage(status: "synthetic") : nil) }
        let session = try ChatSession(id: id, name: "synthetic", origin: .demo, sourceDescription: "7 days", messages: rows)
        let snapshot = try Snapshot(session: session, window: TimeWindow(start: now.addingTimeInterval(-604800), end: now), includeUnknown: false)
        XCTAssertEqual(snapshot.messages.count, 6100); XCTAssertTrue(snapshot.textBytes > 80000)
        var config = ModelConfig(); config.model = "fixture"; config.contextTokens = 100
        let image = ModelImage(messageID: rows[0].id, mimeType: "image/png", data: Data([1,2,3]))
        let unrelated = ModelImage(messageID: UUID(), data: Data([4,5,6]))
        let plain = try Prompt.body(snapshot: snapshot, question: "总结", history: [], config: config, images: [image])
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("image_url"))
        config.supportsVision = true
        let body = try Prompt.body(snapshot: snapshot, question: "自然回答", history: [], config: config, images: [image, unrelated])
        let object = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let messages = object["messages"] as! [[String: Any]]
        let parts = messages[1]["content"] as! [[String: Any]]
        XCTAssertEqual(parts.filter { $0["type"] as? String == "image_url" }.count, 1)
        let data = try JSONSerialization.jsonObject(with: Data((parts[0]["text"] as! String).utf8)) as! [String: Any]
        XCTAssertEqual((data["messages"] as! [Any]).count, 6100)
        for raw in ["大家认为这算是‘完成’了。", "他说\"可以开始\"。这是自然概括。", "无引用回答", "{bad json", "```json\n{}\n```"] {
            let answer = try GroundedAnswer(validating: Data(raw.utf8))
            XCTAssertEqual(answer.text, raw)
        }
        let decoded = try JSONDecoder().decode(ModelConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        let legacy = try JSONDecoder().decode(ModelConfig.self, from: Data(#"{"endpoint":"https://example.com","model":"incomplete","consentEndpoint":"https://example.com"}"#.utf8))
        XCTAssertEqual(legacy.endpoint, "https://example.com")
        XCTAssertEqual(legacy.supportsVision, false)
        XCTAssertEqual(legacy.contextTokens, 128000)
        XCTAssertEqual(legacy.imageBudgetMB, 20)

    }
    func testImportRequiresExplicitZoneAndPreservesSource() throws {
        let text = "# 会话: 项目群\n2026-10-15T21:10:00+08:00\t小王\t原始正文\n"
        let session = try ChatImporter.parse(text, filename: "人工.txt")
        XCTAssertEqual(session.name, "项目群"); XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.messages[0].sender, "小王"); XCTAssertEqual(session.messages[0].sourceLine, 2)
        XCTAssertEqual(Display.iso(session.messages[0].timestamp!), "2026-10-15T13:10:00Z")
        XCTAssertThrowsError(try ChatImporter.timestamp("2026-10-15T21:10:00"))
        XCTAssertThrowsError(try ChatImporter.timestamp("21:10"))
        XCTAssertThrowsError(try ChatImporter.parse("# 会话: 群\n错误数据", filename: "x.txt"))
    }
    func testPromptContainsOnlySelectedScopeAndUntrustedPolicy() throws {
        let (session, window) = try fixture(); let s = try Snapshot(session: session, window: window, includeUnknown: false)
        var config = ModelConfig(); config.model = "test"
        let data = try Prompt.body(snapshot: s, question: "谁提出了事情？", history: [], config: config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let user = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: Any])
        XCTAssertEqual((user["messages"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(user["coverage_complete"] as? Bool, false)
        XCTAssertTrue(messages[0]["content"]!.contains("不可信"))
        XCTAssertFalse(messages[1]["content"]!.contains("未知时间原文"))
        XCTAssertFalse(messages[1]["content"]!.contains("真实原文0"))
    }
    func testEndpointSecurity() throws {
        for url in ["http://example.com/v1/chat/completions", "https://u:p@example.com/x", "https://a.com/x?key=abc"] {
            var c = ModelConfig(); c.endpoint = url; c.model = "m"; XCTAssertThrowsError(try c.url())
        }
        for url in ["https://example.com/v1/chat/completions", "http://127.0.0.1:11434/v1/chat/completions"] {
            var c = ModelConfig(); c.endpoint = url; c.model = "m"; XCTAssertNoThrow(try c.url())
        }
    }
    func testAccountDiscoveryMetadataAndMultipleAccounts() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        XCTAssertEqual(AccountDiscovery.scan(directory: base).state, .notFound)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertEqual(AccountDiscovery.scan(directory: base).state, .notFound)
        for name in ["synthetic-a", "synthetic-b"] {
            let root = base.appendingPathComponent(name).appendingPathComponent("db_storage")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("contact"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("message"), withIntermediateDirectories: true)
            try Data([0x42]).write(to: root.appendingPathComponent("contact/contact.db"))
            try Data([0x43]).write(to: root.appendingPathComponent("message/message_0.db"))
            for auxiliary in ["message_fts.db", "message_resource.db", "biz_message_0.db", "message_0.db-wal", "message_.db"] {
                try Data([0x43]).write(to: root.appendingPathComponent("message/\(auxiliary)"))
            }
        }
        let result = AccountDiscovery.scan(directory: base)
        XCTAssertEqual(result.state, .available); XCTAssertEqual(result.accounts.count, 2)
        XCTAssertTrue(result.accounts.allSatisfy { $0.messageShards == 1 })
        XCTAssertTrue(result.accounts.allSatisfy { $0.root.lastPathComponent == "db_storage" })
        XCTAssertTrue(result.accounts.allSatisfy { $0.displayName.contains("1 个聊天分库") })
    }
    func testDuplicateGroupTitlesFailClosed() {
        let candidates = [TitleCandidate(id: "a", aliases: ["项目群"]), TitleCandidate(id: "b", aliases: ["同名群"]), TitleCandidate(id: "c", aliases: ["同名群"])]
        XCTAssertEqual(TitleIdentity.resolve("项目群 (42)", candidates: candidates), "a")
        XCTAssertNil(TitleIdentity.resolve("同名群（3）", candidates: candidates))
        XCTAssertNil(TitleIdentity.resolve("另一个群", candidates: candidates))
        XCTAssertNil(TitleIdentity.resolve("微信", candidates: [TitleCandidate(id: "a", aliases: ["微信"])]))
        XCTAssertNil(TitleIdentity.resolve("项目", candidates: candidates))
    }
    func testStoreKeepsOnlyImportedAndPathGuard() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try LocalStore(directory: url); let (session, _) = try fixture()
        try store.save([session, ChatImporter.demo()]); try XCTAssertEqual(store.load().count, 1)
        XCTAssertNil(store.imageURL("../../secret.png")); try store.clear(); try XCTAssertEqual(store.load().count, 0)
    }
    func testLegacyIdentityMigrationCopiesConfigAndCredentials() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-migration-" + UUID().uuidString)
        let oldSuite = "sotto.migration.old." + UUID().uuidString
        let newSuite = "sotto.migration.new." + UUID().uuidString
        defer { try? FileManager.default.removeItem(at: root) }
        let oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        let newDefaults = try XCTUnwrap(UserDefaults(suiteName: newSuite))
        defer {
            oldDefaults.removePersistentDomain(forName: oldSuite)
            newDefaults.removePersistentDomain(forName: newSuite)
        }
        oldDefaults.set("legacy-root", forKey: "databaseRoot")
        oldDefaults.set(true, forKey: "followCurrentConversationV4")
        let oldDirectory = root.appendingPathComponent(oldSuite, isDirectory: true)
        let credentials = oldDirectory.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
        try Data("synthetic-credential".utf8).write(to: credentials.appendingPathComponent("key.txt"))
        LegacyMigration.run(applicationSupport: root, defaults: newDefaults, oldBundleIdentifier: oldSuite)
        XCTAssertEqual(newDefaults.string(forKey: "databaseRoot"), "legacy-root")
        XCTAssertEqual(newDefaults.object(forKey: "followCurrentConversationV4") as? Bool, true)
        let migrated = root.appendingPathComponent(LegacyMigration.newBundleIdentifier, isDirectory: true)
            .appendingPathComponent("credentials/key.txt")
        let migratedText = try String(contentsOf: migrated, encoding: .utf8)
        XCTAssertEqual(migratedText, "synthetic-credential")
    }
}

private final class MockProtocol: URLProtocol {
    static var mode = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.mode == 3 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.respond(status: 200, content: "{}") }
        } else if Self.mode == 0 { respond(status: 401, content: "SECRET_ECHO_MUST_NOT_APPEAR") }
        else if Self.mode == 1 { respond(status: 200, content: "not-json") }
        else {
            let raw = "有消息，以下为自然回答。"
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": raw]]]])
            respond(status: 200, content: String(decoding: data, as: UTF8.self))
        }
    }
    func respond(status: Int, content: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(content.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor StreamObservations {
    var values: [String] = []
    var times: [Date] = []
    func append(_ value: String) { values.append(value); times.append(Date()) }
    func state() -> ([String], [Date]) { (values, times) }
}
private final class NetworkTests: PortableCheckCase {
    func testLoopbackStreaming(_ endpoint: String) async throws {
        let (session, window) = try CoreTests().fixture()
        let snapshot = try Snapshot(session: session, window: window, includeUnknown: false)
        var config = ModelConfig(); config.endpoint = endpoint; config.model = "synthetic-stream"; config.consentEndpoint = endpoint
        let observations = StreamObservations()
        let answer = try await ModelClient().ask(snapshot: snapshot, question: "合成流测试", history: [], config: config, key: "") { await observations.append($0) }
        let (values, times) = await observations.state()
        XCTAssertTrue(values.count > 3)
        XCTAssertTrue((times.last?.timeIntervalSince(times.first!) ?? 0) > 0.2)
        XCTAssertTrue(values.last?.contains("END_STREAM_OK") == true)
        XCTAssertTrue(answer.text.contains("你好，世界"))
        config.model = "disconnect"
        let interrupted = StreamObservations()
        do { _ = try await ModelClient().ask(snapshot: snapshot, question: "合成中断测试", history: [], config: config, key: "") { await interrupted.append($0) }; XCTFail("must reject incomplete stream") }
        catch { XCTAssertTrue(error.localizedDescription.contains("断开")) }
        let (partial, _) = await interrupted.state(); XCTAssertTrue(partial.last?.isEmpty == false)
        config.model = "json-fallback"
        let fallback = try await ModelClient().ask(snapshot: snapshot, question: "合成兼容测试", history: [], config: config, key: "") { _ in }
        XCTAssertTrue(fallback.text.contains("END_STREAM_OK"))
        config.model = "synthetic-stream"
        let cancelConfig = config
        let cancelled = Task { try await ModelClient().ask(snapshot: snapshot, question: "合成停止测试", history: [], config: cancelConfig, key: "") { _ in } }
        try await Task.sleep(for: .milliseconds(180)); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("stream must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testRealRequestValidationErrorsAndCancellation() async throws {
        let (session, window) = try CoreTests().fixture(); let snapshot = try Snapshot(session: session, window: window, includeUnknown: false)
        var config = ModelConfig(); config.endpoint = "https://fixture.invalid/chat/completions"; config.model = "fixture"; config.consentEndpoint = config.endpoint
        let setup = URLSessionConfiguration.ephemeral; setup.protocolClasses = [MockProtocol.self]
        let client = ModelClient(session: URLSession(configuration: setup))
        MockProtocol.mode = 0
        do { _ = try await client.ask(snapshot: snapshot, question: "提问", history: [], config: config, key: "test"); XCTFail("must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("401")); XCTAssertFalse(error.localizedDescription.contains("SECRET")) }
        MockProtocol.mode = 1
        do { _ = try await client.ask(snapshot: snapshot, question: "提问", history: [], config: config, key: ""); XCTFail("must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("不兼容")) }
        MockProtocol.mode = 2
        let result = try await client.ask(snapshot: snapshot, question: "提问", history: [], config: config, key: "")
        XCTAssertFalse(result.text.isEmpty)
        MockProtocol.mode = 3
        let task = Task { try await client.ask(snapshot: snapshot, question: "提问", history: [], config: config, key: "") }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        config.consentEndpoint = "other"
        do { _ = try await client.ask(snapshot: snapshot, question: "提问", history: [], config: config, key: ""); XCTFail("must block") }
        catch { XCTAssertTrue(error.localizedDescription.contains("允许")) }
    }
}

@main struct Checks {
    static func main() async {
        let tests = CoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("local credentials / modes / atomic replacement / isolated accounts / unsafe file rejection", checkCredentialStore),
            ("chat window eligibility / preview rejection / missing metadata / duplicate titles", checkWeChatWindowEligibility),
            ("AX focused title / exact emoji and spacing / aliases / unique identity", checkFocusedTitleIdentity),
            ("automatic connection / bounded backoff / no overlap / healthy idle / deletion", checkConnectionRecovery),
            ("SSE Unicode / reasoning exclusion / interrupted stream", tests.testStreamingFramingAndInterruptions),
            ("Markdown blocks / table / nested list / partial code fence", tests.testMarkdownBlocksAndIncompleteFence),
            ("time / unknown / coverage", tests.testTimeFilterInclusiveAndUnknownExcluded),
            ("empty / reversed range", tests.testNoMessagesAndBadRangeReject),
            ("conversation / message identity", tests.testCrossConversationAndDuplicateIdentityReject),
            ("decoded sessions/windows revalidate", tests.testDecodingRevalidatesPersistedSessionsAndWindows),
            ("SSE line and event bounds", tests.testCompletionStreamBounds),
            ("switch / cancel / late completion", tests.testLateCompletionFenceSwitchCancelAndNewRequest),
            ("natural Markdown and literal JSON remain model text", tests.testNaturalAnswerPreservesMarkdownAndLiteralJSON),
            ("AX metadata missing / conflict / private chat / incomplete", tests.testFollowMetadataMissingConflictAndIncomplete),
            ("noisy event narrative / scoped natural followup", tests.testNoisyEventNarrativeAndFollowup),
            ("long records / natural text / multimodal scope / complete current config", tests.testLongNaturalAndVisionRequests),
            ("timestamp import source", tests.testImportRequiresExplicitZoneAndPreservesSource),
            ("prompt scope / injection boundary", tests.testPromptContainsOnlySelectedScopeAndUntrustedPolicy),
            ("endpoint transport security", tests.testEndpointSecurity),
            ("local storage / path guard", tests.testStoreKeepsOnlyImportedAndPathGuard),
            ("legacy ChatFloat identity migration", tests.testLegacyIdentityMigrationCopiesConfigAndCredentials),
            ("duplicate / unknown / exact group title", tests.testDuplicateGroupTitlesFailClosed),
            ("automatic account metadata discovery / multiple accounts", tests.testAccountDiscoveryMetadataAndMultipleAccounts)]
        for (name, run) in checks { do { let before = failures; try run(); print(failures == before ? "PASS " + name : "FAIL " + name) } catch { XCTFail(name + " threw: " + error.localizedDescription) } }
        do { let before = failures; try await NetworkTests().testRealRequestValidationErrorsAndCancellation(); print(failures == before ? "PASS model HTTP / schema / consent / cancellation" : "FAIL network") } catch { XCTFail(error.localizedDescription) }
        if let endpoint = ProcessInfo.processInfo.environment["SOTTO_LOOPBACK_TEST"], endpoint.hasPrefix("http://127.0.0.1:") {
            do {
                let (session, window) = try tests.fixture()
                let snapshot = try Snapshot(session: session, window: window, includeUnknown: false)
                var config = ModelConfig(); config.endpoint = endpoint; config.model = "synthetic-fixture"; config.consentEndpoint = endpoint
                let answer = try await ModelClient().ask(snapshot: snapshot, question: "人工接口测试", history: [], config: config, key: "")
                XCTAssertFalse(answer.text.isEmpty)
                print("PASS actual loopback HTTP request and grounded response (synthetic fixture server)")
            } catch { XCTFail("loopback: " + error.localizedDescription) }
        }
        if let endpoint = ProcessInfo.processInfo.environment["SOTTO_STREAM_TEST"], endpoint.hasPrefix("http://127.0.0.1:") {
            do { let before = failures; try await NetworkTests().testLoopbackStreaming(endpoint); print(failures == before ? "PASS real loopback SSE timing / UTF8 splitting / interrupted partial / JSON fallback / cancellation" : "FAIL loopback stream") }
            catch { XCTFail("stream loopback: " + error.localizedDescription) }
        }
        print("Checks: \(checks.count + 1); failures: \(failures). Synthetic data only.")
        exit(failures == 0 ? 0 : 1)
    }
}
