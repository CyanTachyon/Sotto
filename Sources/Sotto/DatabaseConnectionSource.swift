import Foundation
import SottoCore

/// The external database operations used by connection setup and scoped reads. Checks replace these
/// with synthetic data so recovery and account races never read real credential files.
struct DatabaseConnectionSource {
    var readManifest: (String) async throws -> String = { root in
        try await Task.detached { try CredentialStore.database(DatabaseBridge.account(root)) }.value
    }
    var readGroups: (String) async throws -> DBGroups = { root in
        try await DatabaseBridge.request("groups", root: root)
    }
    var readMessages: (String, String, TimeWindow) async throws -> DBRead = { root, chat, window in
        try await DatabaseBridge.request("read", root: root, chat: chat, window: window)
    }
}
