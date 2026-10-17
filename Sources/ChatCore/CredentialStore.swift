import Foundation
import CryptoKit
import Darwin

/// Plain UTF-8 files owned by the current user. Endpoint names never become paths.
public final class CredentialStore: @unchecked Sendable {
    public enum Failure: LocalizedError, Equatable {
        case invalidInput, invalidManifest, invalidFile, unavailable
        public var errorDescription: String? {
            switch self {
            case .invalidInput: return "密钥或服务地址格式无效，未保存。"
            case .invalidManifest: return "数据库密钥清单无效，请检查后重新导入。"
            case .invalidFile: return "本机密钥文件的内容、类型或权限不正确，请检查后重新保存。"
            case .unavailable: return "暂时无法访问本机密钥文件，请检查文件权限后重试。"
            }
        }
    }
    private static let maximumBytes = 1_000_000
    private static let shared = CredentialStore()
    private let parent: URL
    private let directoryName: String
    private let production: Bool
    private let lock = NSLock()
    private var counts = ["fileReads": 0, "fileWrites": 0, "fileDeletes": 0, "failedOperations": 0]

    private init() {
        parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cn.local.ChatFloat", isDirectory: true)
        directoryName = "credentials"; production = true
    }
    /// Tests cannot redirect production storage or place credentials outside a temporary subtree.
    public init(testDirectory: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = testDirectory.standardizedFileURL
        let resolvedParent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = resolvedParent.appendingPathComponent(candidate.lastPathComponent)
        guard candidate.isFileURL, resolved.pathComponents.starts(with: temporary.pathComponents),
              resolved.pathComponents.count > temporary.pathComponents.count,
              !candidate.lastPathComponent.isEmpty else { throw Failure.invalidInput }
        parent = resolvedParent; directoryName = candidate.lastPathComponent; production = false
    }
    public static var diagnosticCounts: [String: Int] { shared.diagnosticCounts }
    public var diagnosticCounts: [String: Int] {
        lock.lock(); defer { lock.unlock() }; return counts
    }
    public static func read(endpoint: String) throws -> String { try shared.read(endpoint: endpoint) }
    public static func readAsync(endpoint: String) async throws -> String {
        try await Task.detached { try read(endpoint: endpoint) }.value
    }
    public static func save(_ value: String, endpoint: String) throws { try shared.save(value, endpoint: endpoint) }
    public static func delete(endpoint: String) throws { try shared.delete(endpoint: endpoint) }
    public static func database(_ account: String) throws -> String { try shared.database(account) }
    public static func saveDatabase(_ manifest: String, account: String) throws { try shared.saveDatabase(manifest, account: account) }
    public static func deleteDatabase(_ account: String) throws { try shared.deleteDatabase(account) }

    private func perform<T>(_ counter: String, _ action: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        counts[counter, default: 0] += 1
        do { return try action() }
        catch { counts["failedOperations", default: 0] += 1; throw error }
    }
    private func filename(_ endpoint: String) throws -> String {
        guard !endpoint.isEmpty, endpoint.utf8.count <= 8_192, !endpoint.contains("\0") else { throw Failure.invalidInput }
        return SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined() + ".txt"
    }
    private func checkDirectory(_ descriptor: Int32, privateMode: Bool) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              (!privateMode || (info.st_uid == getuid() && info.st_mode & 0o777 == 0o700)) else { throw Failure.invalidFile }
    }
    private func openDirectory(create: Bool) throws -> Int32? {
        if create && production, mkdir(parent.path, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
        let base = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if base < 0 { if errno == ENOENT && !create { return nil }; throw Failure.unavailable }
        defer { Darwin.close(base) }
        try checkDirectory(base, privateMode: production)
        if create, mkdirat(base, directoryName, 0o700) != 0 && errno != EEXIST { throw Failure.unavailable }
        let descriptor = openat(base, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 { if errno == ENOENT && !create { return nil }; throw Failure.invalidFile }
        do { try checkDirectory(descriptor, privateMode: true); return descriptor }
        catch { Darwin.close(descriptor); throw error }
    }
    private func checkFile(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o777 == 0o600 else { throw Failure.invalidFile }
    }
    private func existingFile(_ directory: Int32, _ name: String) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }; throw Failure.unavailable
        }
        try checkFile(info); return true
    }
    public func read(endpoint: String) throws -> String {
        try perform("fileReads") {
            let name = try filename(endpoint)
            guard let directory = try openDirectory(create: false) else { return "" }
            defer { Darwin.close(directory) }
            let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if file < 0 { if errno == ENOENT { return "" }; throw Failure.invalidFile }
            defer { Darwin.close(file) }
            var info = stat()
            guard fstat(file, &info) == 0 else { throw Failure.unavailable }
            try checkFile(info)
            guard info.st_size >= 0, info.st_size <= Self.maximumBytes else { throw Failure.invalidFile }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
                if count == 0 { break }
                guard data.count + count <= Self.maximumBytes else { throw Failure.invalidFile }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Failure.invalidFile }
            return value
        }
    }
    public func save(_ value: String, endpoint: String) throws {
        try perform("fileWrites") {
            let name = try filename(endpoint), data = Data(value.utf8)
            guard !data.isEmpty, data.count <= Self.maximumBytes else { throw Failure.invalidInput }
            guard let directory = try openDirectory(create: true) else { throw Failure.unavailable }
            defer { Darwin.close(directory) }
            _ = try existingFile(directory, name)
            let temporary = ".pending-" + UUID().uuidString
            let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw Failure.unavailable }
            defer { Darwin.close(file); unlinkat(directory, temporary, 0) }
            guard fchmod(file, 0o600) == 0 else { throw Failure.unavailable }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw Failure.unavailable }
                    offset += count
                }
            }
            guard fsync(file) == 0 else { throw Failure.unavailable }
            _ = try existingFile(directory, name)
            guard renameat(directory, temporary, directory, name) == 0 else { throw Failure.unavailable }
            // The file is complete before publication; a crash cannot expose a partial value.
            _ = fsync(directory)
        }
    }
    public func delete(endpoint: String) throws {
        try perform("fileDeletes") {
            let name = try filename(endpoint)
            guard let directory = try openDirectory(create: false) else { return }
            defer { Darwin.close(directory) }
            guard try existingFile(directory, name) else { return }
            guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw Failure.unavailable }
            _ = fsync(directory)
        }
    }
    private func databaseEndpoint(_ account: String) throws -> String {
        guard account.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw Failure.invalidManifest }
        return "database-account:" + account
    }
    public func database(_ account: String) throws -> String {
        let value = try read(endpoint: databaseEndpoint(account))
        if !value.isEmpty { try Self.validateManifest(value) }
        return value
    }
    public func saveDatabase(_ manifest: String, account: String) throws {
        let endpoint = try databaseEndpoint(account)
        try Self.validateManifest(manifest)
        try save(manifest, endpoint: endpoint)
    }
    public func deleteDatabase(_ account: String) throws { try delete(endpoint: databaseEndpoint(account)) }
    private static func validateManifest(_ manifest: String) throws {
        let data = Data(manifest.utf8)
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = object["keys"] as? [String: [String: String]], !keys.isEmpty,
              keys.allSatisfy({ path, value in
                  let components = path.split(separator: "/", omittingEmptySubsequences: false)
                  return !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0") && path.utf8.count <= 1_024 &&
                      path.hasSuffix(".db") && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } &&
                      value["enc_key"]?.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
              }) else { throw Failure.invalidManifest }
    }
}
