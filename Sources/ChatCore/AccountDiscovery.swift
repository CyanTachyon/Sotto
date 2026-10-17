import Foundation

public struct DiscoveredAccount: Identifiable, Sendable {
    public var id: String { root.path }
    public let root: URL
    public let messageShards: Int
    public var displayName: String {
        let account = root.deletingLastPathComponent().lastPathComponent
        let shortened = account.count > 16 ? String(account.prefix(8)) + "…" + String(account.suffix(4)) : account
        return shortened + " · \(messageShards) 个聊天分库"
    }
}

public struct AccountDiscoveryResult: Sendable {
    public enum State: String, Sendable { case available, permissionRequired, notFound, unavailable }
    public let state: State
    public let accounts: [DiscoveredAccount]
}

public enum AccountDiscovery {
    public static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files", isDirectory: true)
    }
    /// Metadata only; never reads database bodies or searches unrelated accounts/locations.
    public static func scan(directory: URL = standardDirectory) -> AccountDiscoveryResult {
        let manager = FileManager.default
        do {
            let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            var found: [DiscoveredAccount] = []
            for child in children {
                let root = child.appendingPathComponent("db_storage", isDirectory: true)
                do {
                    let attributes = try manager.attributesOfItem(atPath: root.appendingPathComponent("contact/contact.db").path)
                    guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else { continue }
                    let messageDirectory = root.appendingPathComponent("message", isDirectory: true)
                    let shards: [URL]
                    do {
                        shards = try manager.contentsOfDirectory(at: messageDirectory, includingPropertiesForKeys: nil).filter {
                            $0.lastPathComponent.range(of: "^message_[0-9]+\\.db$", options: .regularExpression) != nil
                        }
                    }
                    catch where isMissing(error) { shards = [] }
                    found.append(DiscoveredAccount(root: root.resolvingSymlinksInPath(), messageShards: shards.count))
                } catch where isMissing(error) { continue }
            }
            return AccountDiscoveryResult(state: found.isEmpty ? .notFound : .available, accounts: found.sorted { $0.root.path < $1.root.path })
        } catch {
            return AccountDiscoveryResult(state: isPermission(error) ? .permissionRequired : isMissing(error) ? .notFound : .unavailable, accounts: [])
        }
    }
    private static func isMissing(_ error: Error) -> Bool {
        let e = error as NSError
        return (e.domain == NSCocoaErrorDomain && [4, 260].contains(e.code)) || (e.domain == NSPOSIXErrorDomain && e.code == 2)
    }
    private static func isPermission(_ error: Error) -> Bool {
        let e = error as NSError
        if (e.domain == NSCocoaErrorDomain && [257, 513].contains(e.code)) || (e.domain == NSPOSIXErrorDomain && [1, 13].contains(e.code)) { return true }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error { return isPermission(underlying) }
        return false
    }
}
