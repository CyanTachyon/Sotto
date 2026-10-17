import Foundation
import Darwin
import ChatCore

func checkCredentialStore() throws {
    func require(_ value: Bool, _ label: String) throws { if !value { throw ChatError.invalid(label) } }
    func rejects(_ label: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw ChatError.invalid(label)
    }
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("credential-check-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: root) }
    let directory = root.appendingPathComponent("credentials", isDirectory: true)
    let store = try CredentialStore(testDirectory: directory)
    let endpoint = "https://synthetic.invalid/v1", other = "https://other.invalid/v1"
    try require(try store.read(endpoint: endpoint) == "", "missing credential must be empty")
    try require(!manager.fileExists(atPath: directory.path), "reading a missing credential must not create storage")
    try store.save("synthetic-original", endpoint: endpoint)
    let file = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first!
    let directoryMode = try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    let fileMode = try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    try require(directoryMode?.intValue == 0o700 && fileMode?.intValue == 0o600, "private directory and file modes")
    try require(file.lastPathComponent.range(of: "^[0-9a-f]{64}\\.txt$", options: .regularExpression) != nil, "filename must only contain endpoint hash")
    let reopened = try CredentialStore(testDirectory: directory)
    try require(try reopened.read(endpoint: endpoint) == "synthetic-original", "a new store instance must read saved UTF8")
    let originalFile = Darwin.open(file.path, O_RDONLY | O_CLOEXEC)
    guard originalFile >= 0 else { throw ChatError.invalid("synthetic atomic read setup") }
    defer { Darwin.close(originalFile) }
    try store.save("synthetic-replacement-中文", endpoint: endpoint)
    let previous = FileHandle(fileDescriptor: originalFile, closeOnDealloc: false).readDataToEndOfFile()
    try require(String(data: previous, encoding: .utf8) == "synthetic-original", "replacement must publish a new complete file")
    try require(try reopened.read(endpoint: endpoint) == "synthetic-replacement-中文", "replacement must be visible without stale process cache")

    try store.save("other-value", endpoint: other)
    let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
    let manifest = "{\"keys\":{\"contact/contact.db\":{\"enc_key\":\"" + String(repeating: "01", count: 32) + "\"}}}"
    try store.saveDatabase(manifest, account: a); try store.saveDatabase(manifest, account: b)
    try require(try reopened.database(a) == manifest && reopened.database(b) == manifest, "database accounts must survive reopening")
    try store.deleteDatabase(a); try store.deleteDatabase(a)
    try require(try reopened.database(a).isEmpty && reopened.database(b) == manifest && reopened.read(endpoint: other) == "other-value", "deletion must not affect another account or API")
    try store.delete(endpoint: endpoint)
    try require(try reopened.read(endpoint: endpoint).isEmpty, "deleted credentials cannot reappear in another instance")

    // Invalid input cannot create a file, disclose a value, or escape the test directory.
    try rejects("test path must stay under system temporary directory") { _ = try CredentialStore(testDirectory: URL(fileURLWithPath: "/credential-test-forbidden")) }
    try rejects("empty endpoint must reject") { try store.save("synthetic", endpoint: "") }
    try rejects("empty value must reject") { try store.save("", endpoint: endpoint) }
    try rejects("oversized value must reject") { try store.save(String(repeating: "x", count: 1_000_001), endpoint: endpoint) }
    try rejects("account format must reject") { try store.saveDatabase(manifest, account: "../invalid") }
    for path in ["../contact.db", "/contact.db", "contact//contact.db", "contact/./contact.db", "contact\\contact.db", ""] {
        let bad = try JSONSerialization.data(withJSONObject: ["keys": [path: ["enc_key": String(repeating: "02", count: 32)]]])
        try rejects("unsafe database path must reject") { try store.saveDatabase(String(decoding: bad, as: UTF8.self), account: a) }
    }
    for bad in ["not JSON", "{}", #"{"keys":{}}"#, #"{"keys":{"contact/contact.db":{"enc_key":"short"}}}"#] {
        try rejects("invalid database manifest must reject") { try store.saveDatabase(bad, account: a) }
    }
    try store.save("invalid JSON", endpoint: "database-account:" + a)
    try rejects("database reads must validate saved content too") { _ = try reopened.database(a) }
    try store.deleteDatabase(a)

    try store.save("synthetic", endpoint: endpoint)
    try Data([0xff, 0xfe]).write(to: file)
    try rejects("invalid UTF8 must reject") { _ = try reopened.read(endpoint: endpoint) }
    try Data(repeating: 0x78, count: 1_000_001).write(to: file)
    try rejects("oversized corrupt file must reject reads") { _ = try reopened.read(endpoint: endpoint) }
    try store.save("repaired-synthetic", endpoint: endpoint)
    try require(try reopened.read(endpoint: endpoint) == "repaired-synthetic", "safe oversized file must allow replacement")
    try Data(repeating: 0x78, count: 1_000_001).write(to: file)
    try store.delete(endpoint: endpoint)
    try require(try reopened.read(endpoint: endpoint).isEmpty, "safe oversized file must allow deletion")
    let outside = root.appendingPathComponent("synthetic-target")
    try Data("unchanged-synthetic-target".utf8).write(to: outside)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
    try manager.createSymbolicLink(at: file, withDestinationURL: outside)
    try rejects("symlink read must reject") { _ = try store.read(endpoint: endpoint) }
    try rejects("symlink overwrite must reject") { try store.save("replacement", endpoint: endpoint) }
    try rejects("symlink delete must reject") { try store.delete(endpoint: endpoint) }
    try require(try String(contentsOf: outside, encoding: .utf8) == "unchanged-synthetic-target", "linked target must remain unchanged")
    try manager.removeItem(at: file)
    guard link(outside.path, file.path) == 0 else { throw ChatError.invalid("synthetic hardlink setup") }
    try rejects("hard-linked credential must reject") { _ = try store.read(endpoint: endpoint) }
    try manager.removeItem(at: file)
    guard mkfifo(file.path, 0o600) == 0 else { throw ChatError.invalid("synthetic FIFO setup") }
    try rejects("nonregular credential must reject without blocking") { _ = try store.read(endpoint: endpoint) }
    try manager.removeItem(at: file)
    try store.save("synthetic", endpoint: endpoint)
    try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try rejects("readable-by-others file must reject") { _ = try store.read(endpoint: endpoint) }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try rejects("nonprivate directory must reject") { _ = try store.read(endpoint: endpoint) }
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let directoryLink = root.appendingPathComponent("directory-link")
    try manager.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
    let linkedStore = try CredentialStore(testDirectory: directoryLink)
    try rejects("credential directory symlink must reject") { _ = try linkedStore.read(endpoint: endpoint) }

    // Clearing imported messages is a separate operation and must leave keys intact.
    let local = try LocalStore(directory: root)
    try local.save([]); try local.clear()
    try require(try reopened.read(endpoint: endpoint) == "synthetic" && reopened.database(b) == manifest, "message-cache cleanup must preserve credential files")
    let counts = store.diagnosticCounts
    try require(Set(counts.keys) == Set(["fileReads", "fileWrites", "fileDeletes", "failedOperations"]), "diagnostics must contain only counters")
    try require((counts["failedOperations"] ?? 0) > 0, "failed file operations must be counted")
}
