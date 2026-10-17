import AppKit
import ApplicationServices
import SottoCore
import CryptoKit
import Darwin

struct DBGroup: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let aliases: [String]
    var isGroup: Bool { id.hasSuffix("@chatroom") }
    var kindLabel: String { isGroup ? "群聊" : "私聊" }
}
struct DBGroups: Decodable { let account: String; let groups: [DBGroup] }
struct DBRow: Decodable {
    let database: String; let localID: String; let serverID: String?
    let timestamp: Int; let senderID: String?; let sender: String?; let text: String?; let type: Int; let image: ChatImage?
}
struct DBRead: Decodable {
    let account: String; let chat: String; let name: String
    let scannedShards: Int; let omittedMedia: Int; let completeLocalQuery: Bool; let messages: [DBRow]
    func session(expectedAccount: String, expectedChat: String, window: TimeWindow) throws -> ChatSession {
        guard account == expectedAccount, chat == expectedChat, completeLocalQuery,
              messages.allSatisfy({ window.contains(Date(timeIntervalSince1970: Double($0.timestamp))) }) else {
            throw ChatError.invalid("数据库返回了范围外数据或其他账号/会话，已拒绝载入。")
        }
        let id = UUID()
        let values = messages.enumerated().compactMap { index, row -> ChatMessage? in
            guard [1,3].contains(row.type) || row.type & 0xffffffff == 49, let text = row.text, !text.isEmpty else { return nil }
            return ChatMessage(sessionID: id, timestamp: Date(timeIntervalSince1970: Double(row.timestamp)), sender: row.sender,
                text: text, source: "数据库 \(row.database) · 会话 \(chat) · local_id=\(row.localID) · server_id=\(row.serverID ?? "未知") · sender_id=\(row.senderID ?? "未知")", sourceLine: index + 1, image: row.image)
        }
        let coverage = "查询 \(Display.date(window.start)) — \(Display.date(window.end))；\(scannedShards) 个消息分库；略过 \(omittedMedia) 条其他类型消息"
        return try ChatSession(id: id, name: name, origin: .database, sourceDescription: coverage, messages: values)
    }
}

struct DatabaseBridge {
    static func account(_ root: String) -> String {
        SHA256.hash(data: Data(URL(fileURLWithPath: root).resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// Production launches must use the adapter shipped inside the application
    /// bundle. Falling back to the current directory would let an unexpected
    /// working directory supply the script that receives database credentials.
    static var backend: URL? {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("Backend/reader.py").path) {
            return resources.appendingPathComponent("Backend")
        }
        // `swift run`/debug binaries have no app resources. Only those
        // non-release builds may use the repository Backend; the signed release
        // bundle must never send credentials to a script from the current directory.
        guard Bundle.main.bundleIdentifier != "moe.tachyon.sotto" else { return nil }
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Backend", isDirectory: true)
        guard FileManager.default.fileExists(atPath: candidate.appendingPathComponent("reader.py").path) else { return nil }
        return candidate
    }
    static func request<T: Decodable>(_ command: String, root: String, chat: String? = nil, window: TimeWindow? = nil) async throws -> T {
        let account = account(root)
        let secret = try await Task.detached { try CredentialStore.database(account) }.value
        guard !secret.isEmpty, let keys = try? JSONSerialization.jsonObject(with: Data(secret.utf8)) as? [String: Any] else {
            throw ChatError.invalid("此账号尚无有效数据库密钥。请在连接设置中完成一次取钥，或导入已有的逐库密钥清单。")
        }
        var request: [String: Any] = ["root": root, "account": account, "keys": keys, "command": command]
        if let chat { request["chat"] = chat }
        if let window { request["start"] = Int(ceil(window.start.timeIntervalSince1970)); request["end"] = Int(floor(window.end.timeIntervalSince1970)) }
        let input = try JSONSerialization.data(withJSONObject: request)
        let bytes = try await run(script: "reader.py", input: input)
        if let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: String], let code = object["error"] {
            let explanations = ["permission_denied": "macOS 拒绝访问微信数据。请给本应用完全磁盘访问权限后重新打开。",
                "missing_key": "部分微信数据库缺少对应密钥，暂时无法完整读取。请到连接设置检查或导入已有的逐库密钥。",
                "conversation_not_in_account": "本机已没有这个会话的聊天记录，请重新选择会话。",
                "no_message_shards": "尚未找到本机聊天记录。请先让微信同步记录，再重新检测。",
                "database_read_failed": "数据库校验或查询失败：密钥、库格式可能已变化。请检查连接。"]
            throw ChatError.invalid(explanations[code] ?? "数据库读取未完成（\(code)），没有返回部分结果。")
        }
        do { return try JSONDecoder().decode(T.self, from: bytes) }
        catch { throw ChatError.invalid("数据库适配器返回格式不兼容。") }
    }
    static func run(script: String, input: Data, timeout: TimeInterval = 120) async throws -> Data {
        guard let backend else {
            throw ChatError.invalid("应用包缺少本地数据库适配器，无法读取聊天记录。请重新安装完整应用。")
        }
        let scriptURL = backend.appendingPathComponent(script)
        guard FileManager.default.fileExists(atPath: scriptURL.path) else {
            throw ChatError.invalid("应用包缺少数据库适配脚本 \(script)，请重新安装完整应用。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [scriptURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, value in value }
        let pipeIn = Pipe(), pipeOut = Pipe()
        process.standardInput = pipeIn; process.standardOutput = pipeOut; process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            try pipeIn.fileHandleForWriting.write(contentsOf: input)
            try pipeIn.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            throw ChatError.invalid("无法启动本地数据库适配器。请确认系统 Python 可用。")
        }
        let readTask = Task.detached { pipeOut.fileHandleForReading.readDataToEndOfFile() }
        let deadline = Date().addingTimeInterval(max(1, timeout))
        do {
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
                try Task.checkCancellation()
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .milliseconds(400))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = await readTask.result
                throw ChatError.invalid("数据库操作超时（\(Int(timeout)) 秒），已停止。请缩小范围或重试。")
            }
        } catch {
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = await readTask.result
            throw error
        }
        let data = await readTask.value
        process.waitUntilExit()
        return data
    }
}

