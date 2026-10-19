// Release-only Ed25519 signing. Runtime credentials and the Keychain are never used.
import Foundation
import CryptoKit
import Darwin

enum SigningFailure: Error { case invalid(String) }
let args = Array(CommandLine.arguments.dropFirst())
let state = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/moe.tachyon.sotto.update-signing", isDirectory: true)
let privateFile = state.appendingPathComponent("private-key")
func fail(_ reason: String) throws -> Never { throw SigningFailure.invalid(reason) }
func protected(_ url: URL, directory: Bool) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == getuid(),
          info.st_mode & 0o777 == (directory ? 0o700 : 0o600),
          info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
        try fail("Signing file ownership, type or permissions are invalid.")
    }
}
func publicKey(_ path: String) throws -> Data {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let value = String(data: data, encoding: .utf8),
          let decoded = Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          decoded.count == 32 else { try fail("Invalid update public key.") }
    return decoded
}
func loadKey(matching path: String) throws -> Curve25519.Signing.PrivateKey {
    try protected(state, directory: true); try protected(privateFile, directory: false)
    guard let encoded = String(data: try Data(contentsOf: privateFile), encoding: .utf8),
          let seed = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          seed.count == 32 else { try fail("Invalid update signing file.") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    guard key.publicKey.rawRepresentation == (try publicKey(path)) else {
        try fail("Update signing identity does not match the embedded public key.")
    }
    return key
}
func result(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
do {
    umask(0o077)
    guard args.count >= 2 else { try fail("Usage: update-signing.swift setup|check <public-key-file> | sign <public-key-file> <archive> | verify <public-key-file> <archive> <signature>") }
    switch args[0] {
    case "setup":
        guard args.count == 2 else { try fail("Unexpected arguments.") }
        let publicFile = URL(fileURLWithPath: args[1])
        if !FileManager.default.fileExists(atPath: privateFile.path) {
            guard !FileManager.default.fileExists(atPath: publicFile.path) else {
                try fail("Private key missing for an existing public key; no replacement was generated.")
            }
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try protected(state, directory: true)
            let key = Curve25519.Signing.PrivateKey()
            let descriptor = open(privateFile.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { try fail("Could not create update signing file.") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: key.rawRepresentation.base64EncodedData())
            try handle.close()
            try (key.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: publicFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicFile.path)
        }
        _ = try loadKey(matching: args[1])
        try result(["ready": true, "storage": "release_only_file", "keychain": false])
    case "check":
        guard args.count == 2 else { try fail("Unexpected arguments.") }
        _ = try loadKey(matching: args[1]); try result(["ready": true])
    case "sign":
        guard args.count == 3 else { try fail("Unexpected arguments.") }
        let key = try loadKey(matching: args[1]), data = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
        let signature = try key.signature(for: data)
        try result(["edSignature": signature.base64EncodedString(), "length": data.count])
    case "verify":
        guard args.count == 4, let signature = Data(base64Encoded: args[3]) else { try fail("Unexpected arguments.") }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey(args[1]))
        let data = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
        guard key.isValidSignature(signature, for: data) else { try fail("Invalid archive signature.") }
        try result(["valid": true])
    default: try fail("Unknown signing operation.")
    }
} catch SigningFailure.invalid(let reason) {
    fputs("Update signing stopped: \(reason)\n", stderr); exit(1)
} catch {
    // Do not print arbitrary file contents or errors that might include secrets.
    fputs("Update signing stopped: could not complete signing operation.\n", stderr); exit(1)
}
