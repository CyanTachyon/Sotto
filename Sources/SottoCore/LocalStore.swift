import Foundation
import Darwin

public final class LocalStore {
    public let directory: URL
    public init(directory: URL? = nil) throws {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("moe.tachyon.sotto", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
    }
    public func load() throws -> [ChatSession] {
        let url = directory.appendingPathComponent("sessions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 100_000_000 else {
            throw ChatError.invalid("本地缓存过大，已拒绝载入。")
        }
        let values = try JSONDecoder().decode([ChatSession].self, from: Data(contentsOf: url))
        guard values.count <= 30, values.allSatisfy({ session in
            session.origin == .imported && session.messages.allSatisfy { $0.sessionID == session.id }
        }) else { throw ChatError.invalid("本地缓存会话校验失败。") }
        return values
    }
    public func save(_ values: [ChatSession]) throws {
        let url = directory.appendingPathComponent("sessions.json")
        let data = try JSONEncoder().encode(values.filter { $0.origin == .imported })
        guard data.count <= 100_000_000 else { throw ChatError.invalid("本地缓存过大，未保存。") }
        try writePrivate(data, to: url)
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
    /// Publish a complete file with 0600 permissions. The directory is already
    /// 0700, but this avoids a window in which a newly written cache is group/world
    /// readable before the post-write chmod.
    private func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".pending-" + UUID().uuidString)
        do {
            try data.write(to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let result = temporary.path.withCString { source in
                url.path.withCString { destination in rename(source, destination) }
            }
            guard result == 0 else { throw ChatError.invalid("本地缓存写入失败。") }
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

