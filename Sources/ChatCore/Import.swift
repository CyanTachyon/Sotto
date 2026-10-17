import Foundation

public enum ChatImporter {
    private struct FileData: Decodable { let conversation: String; let messages: [Item] }
    private struct Item: Decodable { let timestamp: String; let sender: String; let text: String }
    public static func timestamp(_ text: String) throws -> Date {
        // Require explicit date + offset. Never interpret a naked clock time as today.
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else {
            throw ChatError.invalid("时间须为含日期和时区的 ISO 8601，例如 2026-10-15T21:10:00+08:00。")
        }
        let f = ISO8601DateFormatter()
        if text.contains(".") { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
        guard let date = f.date(from: text) else { throw ChatError.invalid("日期无效。") }
        return date
    }
    public static func parse(_ text: String, filename: String, now: Date = Date()) throws -> ChatSession {
        guard text.utf8.count <= 5_000_000 else { throw ChatError.invalid("文件超过 5 MB。") }
        let name: String
        let entries: [(String, String, String, Int)]
        if filename.lowercased().hasSuffix(".json") {
            let file: FileData
            do { file = try JSONDecoder().decode(FileData.self, from: Data(text.utf8)) }
            catch { throw ChatError.invalid("JSON 格式不符，请参考附带的导入示例。") }
            name = file.conversation
            entries = file.messages.enumerated().map { ($0.element.timestamp, $0.element.sender, $0.element.text, $0.offset + 1) }
        } else {
            let lines = text.components(separatedBy: .newlines)
            guard let first = lines.first, first.hasPrefix("# 会话: ") else {
                throw ChatError.invalid("文本第一行须为「# 会话: 群名」，后续每行：时间<TAB>发言者<TAB>文字。")
            }
            name = String(first.dropFirst(6))
            entries = try lines.enumerated().dropFirst().filter { !$0.element.isEmpty }.map { index, line in
                let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 3 else { throw ChatError.invalid("第 \(index + 1) 行不符合三列 TAB 格式。") }
                return (parts[0], parts[1], parts[2], index + 1)
            }
        }
        guard !entries.isEmpty else { throw ChatError.invalid("文件中没有记录。") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120 else {
            throw ChatError.invalid("会话名称不能为空，且不能超过 120 字。")
        }
        let id = UUID()
        let messages = try entries.map { time, sender, content, line in
            guard !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.utf8.count <= 100_000 else {
                throw ChatError.invalid("第 \(line) 条记录的发言者/正文为空或过长。")
            }
            return ChatMessage(sessionID: id, timestamp: try timestamp(time), sender: sender, text: content,
                               source: filename, sourceLine: line, observedAt: now)
        }
        return try ChatSession(id: id, name: name, origin: .imported, createdAt: now,
                               sourceDescription: "导入文件 · \(filename)", messages: messages)
    }
    public static func demo(now: Date = Date()) -> ChatSession {
        let id = UUID()
        let lines = [("林安", "发布候选版已经准备好，请大家今天 22 点前完成回归。"),
                     ("周宁", "我来负责登录和支付流程的回归，发现问题会发到这里。"),
                     ("陈雨", "测试机还缺一台，我明天上午补上。发布暂定明天下午，等回归结果再确认。")]
        let messages = lines.enumerated().map { i, line in
            ChatMessage(sessionID: id, timestamp: now.addingTimeInterval(Double(i - 3) * 240), sender: line.0,
                        text: line.1, source: "内置虚构演示", sourceLine: i + 1, observedAt: now)
        }
        return try! ChatSession(id: id, name: "演示 · 项目讨论群（虚构）", origin: .demo,
                                createdAt: now, sourceDescription: "演示数据 · 非真实微信", messages: messages)
    }
}
