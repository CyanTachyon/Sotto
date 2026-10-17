import Foundation

public enum ChatError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public struct ChatImage: Codable, Equatable, Sendable {
    public let path: String?
    public let status: String
    public init(path: String? = nil, status: String) { self.path = path; self.status = status }
}
public struct ModelImage: Sendable {
    public let messageID: UUID
    public let mimeType: String
    public let quality: String
    public let data: Data
    public init(messageID: UUID, mimeType: String = "image/jpeg", data: Data, quality: String = "本地图片，已按发送尺寸缩放") { self.messageID = messageID; self.mimeType = mimeType; self.data = data; self.quality = quality }
}
public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let timestamp: Date?
    public let sender: String?
    public let text: String
    public let source: String
    public let sourceLine: Int
    public let observedAt: Date
    public let image: ChatImage?
    public init(id: UUID = UUID(), sessionID: UUID, timestamp: Date?, sender: String?, text: String,
                source: String, sourceLine: Int, observedAt: Date = Date(), image: ChatImage? = nil) {
        self.id = id; self.sessionID = sessionID; self.timestamp = timestamp; self.sender = sender
        self.text = text; self.source = source; self.sourceLine = sourceLine
        self.observedAt = observedAt; self.image = image
    }
}

public struct ChatSession: Codable, Identifiable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case imported, database, demo }
    public let id: UUID
    public let name: String
    public let origin: Origin
    public let createdAt: Date
    public let sourceDescription: String
    public let messages: [ChatMessage]
    public init(id: UUID, name: String, origin: Origin, createdAt: Date = Date(), sourceDescription: String,
                messages: [ChatMessage]) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              messages.allSatisfy({ $0.sessionID == id }), Set(messages.map(\.id)).count == messages.count else {
            throw ChatError.invalid("会话身份或消息身份不一致，已拒绝载入。")
        }
        self.id = id; self.name = name; self.origin = origin; self.createdAt = createdAt
        self.sourceDescription = sourceDescription; self.messages = messages
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, origin, createdAt, sourceDescription, messages
    }
    /// Decoding goes through the same validation as construction. This keeps a
    /// damaged or edited sessions.json from bypassing name/message identity checks.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let origin = try container.decode(Origin.self, forKey: .origin)
        let createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let sourceDescription = try container.decodeIfPresent(String.self, forKey: .sourceDescription) ?? ""
        let messages = try container.decode([ChatMessage].self, forKey: .messages)
        try self.init(id: id, name: name, origin: origin, createdAt: createdAt,
                      sourceDescription: sourceDescription, messages: messages)
    }
    public var unknownCount: Int { messages.filter { $0.timestamp == nil }.count }
    public var coverageLabel: String {
        let times = messages.compactMap(\.timestamp)
        let span: String
        if let first = times.min(), let last = times.max() { span = "已知时间 \(Display.date(first)) — \(Display.date(last))" }
        else { span = "消息时间未知；采集于 \(Display.date(createdAt))" }
        return "\(span)\n\(origin == .database ? sourceDescription + "；仅本机已同步记录，逐库快照，非云端完整历史。" : "仅含本次导入记录，不能证明期间完整覆盖。")"
    }
}

public enum Display {
    public static func date(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm:ss"; return f.string(from: date)
    }
    public static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

public struct TimeWindow: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) throws {
        guard start <= end else { throw ChatError.invalid("开始时间必须早于或等于结束时间。") }
        self.start = start; self.end = end
    }
    private enum CodingKeys: String, CodingKey { case start, end }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(start: try container.decode(Date.self, forKey: .start),
                      end: try container.decode(Date.self, forKey: .end))
    }
    public func contains(_ date: Date) -> Bool { date >= start && date <= end }
}

public struct Snapshot: Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let sessionName: String
    public let createdAt: Date
    public let window: TimeWindow
    public let messages: [ChatMessage]
    public let includedUnknownCount: Int
    public let coverage: String
    public func referenceID(at index: Int) -> String { "S" + id.uuidString.prefix(8).lowercased() + "-M\(index + 1)" }
    public var textBytes: Int { messages.reduce(0) { $0 + $1.text.utf8.count } }
    public var estimatedTokens: Int { messages.reduce(0) { $0 + $1.text.count + 40 } }
    public init(session: ChatSession, window: TimeWindow, includeUnknown: Bool, now: Date = Date()) throws {
        guard session.messages.allSatisfy({ $0.sessionID == session.id }) else {
            throw ChatError.invalid("发现其他会话消息，已阻止请求。")
        }
        let selected = session.messages.filter { message in
            if let time = message.timestamp { return window.contains(time) }
            return includeUnknown
        }
        guard !selected.isEmpty else {
            throw ChatError.invalid("所选范围没有可用的已知时间消息。可调整范围、导入记录，或明确勾选附加时间未知文字。")
        }
        id = UUID(); sessionID = session.id; sessionName = session.name
        createdAt = now; self.window = window
        messages = selected.enumerated().sorted { a, b in
            let x = a.element.timestamp ?? .distantFuture, y = b.element.timestamp ?? .distantFuture
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
        includedUnknownCount = selected.filter { $0.timestamp == nil }.count
        coverage = session.coverageLabel
    }
}

/// A new selection or cancellation invalidates all completions, including transports that ignore cancel.
public struct RequestFence: Sendable {
    public private(set) var sessionID: UUID?
    public private(set) var token: UUID?
    public init() {}
    public mutating func select(_ id: UUID?) { sessionID = id; token = nil }
    public mutating func begin(sessionID: UUID) throws -> UUID {
        guard self.sessionID == sessionID else { throw ChatError.invalid("当前群已改变，请重新提问。") }
        let value = UUID(); token = value; return value
    }
    public mutating func cancel() { token = nil }
    public func accepts(token: UUID, sessionID: UUID) -> Bool { self.token == token && self.sessionID == sessionID }
}
