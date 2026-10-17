import Foundation

public final class LocalStore {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cn.local.ChatFloat", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }
    public func load() throws -> [ChatSession] {
        let url = directory.appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([ChatSession].self, from: Data(contentsOf: url))
        guard values.count <= 30, values.allSatisfy({ session in
            session.messages.allSatisfy { $0.sessionID == session.id }
        }) else { throw ChatError.invalid("本地缓存会话校验失败。") }
        return values
    }
    public func save(_ values: [ChatSession]) throws {
        let url = directory.appendingPathComponent("sessions.json")
        try JSONEncoder().encode(values.filter { $0.origin == .imported }).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func saveImage(_ data: Data) throws -> String {
        let name = UUID().uuidString + ".png"; let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return name
    }
    public func imageURL(_ name: String) -> URL? {
        guard UUID(uuidString: String(name.dropLast(4))) != nil, name.hasSuffix(".png"), !name.contains("/") else { return nil }
        return directory.appendingPathComponent(name)
    }
    public func clear() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if url.lastPathComponent == "sessions.json" || imageURL(url.lastPathComponent) != nil { try FileManager.default.removeItem(at: url) }
        }
    }
}

