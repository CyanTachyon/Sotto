import Foundation

/// SSE framing is independent of transport chunk boundaries and of model reasoning deltas.
public struct CompletionStream {
    public private(set) var text = ""
    public private(set) var finished = false
    public private(set) var lengthLimited = false
    private var dataLines: [String] = []
    private var pendingLine = Data()
    private var previousCR = false
    private var firstLine = true
    public init() {}
    /// Foundation's AsyncBytes.lines drops empty lines; SSE requires preserving them.
    @discardableResult public mutating func byte(_ byte: UInt8) throws -> Bool {
        if byte == 10 && previousCR { previousCR = false; return false }
        previousCR = byte == 13
        guard byte == 10 || byte == 13 else { pendingLine.append(byte); return false }
        try flushLine(); return true
    }
    private mutating func flushLine() throws {
        if firstLine && pendingLine.starts(with: [0xef, 0xbb, 0xbf]) { pendingLine.removeFirst(3) }
        firstLine = false
        guard let value = String(data: pendingLine, encoding: .utf8) else { throw ChatError.invalid("模型流式响应编码错误，已收到的文字已保留。") }
        pendingLine.removeAll(keepingCapacity: true); try line(value)
    }
    public mutating func line(_ line: String) throws {
        if line.isEmpty { try dispatch(); return }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5)); if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
    }
    public mutating func end() throws {
        if !pendingLine.isEmpty { try flushLine() }
        try dispatch()
        guard finished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.invalid(text.isEmpty ? "模型没有返回回答内容。" : "连接在回答完成前断开，已收到的文字已保留。")
        }
    }
    private mutating func dispatch() throws {
        guard !dataLines.isEmpty else { return }
        let event = dataLines.joined(separator: "\n"); dataLines.removeAll(keepingCapacity: true)
        if event == "[DONE]" { finished = true; return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? [String: Any] else {
            throw ChatError.invalid("模型流式响应格式错误，已收到的文字已保留。")
        }
        if object["error"] != nil { throw ChatError.invalid("模型服务中断了生成，已收到的文字已保留。") }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return }
        if let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String { text += content }
        if let reason = choice["finish_reason"] as? String {
            finished = true; lengthLimited = reason == "length"
        }
    }
}
