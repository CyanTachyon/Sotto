import Foundation

/// One-time migration from the pre-rename application identity. The old folder
/// is copied, not moved, so an archived ChatFloat build can still be inspected.
/// TCC permissions are identity-bound and cannot be migrated by this code.
public enum LegacyMigration {
    public static let oldBundleIdentifier = "cn.local.ChatFloat"
    public static let newBundleIdentifier = "moe.tachyon.sotto"
    private static let preferenceKeys = [
        "databaseRoot", "modelConfig", "followCurrentConversationV4",
        "selectedDatabaseGroupV3", "appAppearanceV1"
    ]

    public static func run(applicationSupport: URL? = nil,
                           defaults: UserDefaults = .standard,
                           oldBundleIdentifier: String = oldBundleIdentifier) {
        let manager = FileManager.default
        let support = applicationSupport ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDirectory = support.appendingPathComponent(oldBundleIdentifier, isDirectory: true)
        let newDirectory = support.appendingPathComponent(newBundleIdentifier, isDirectory: true)
        if !manager.fileExists(atPath: newDirectory.path), manager.fileExists(atPath: oldDirectory.path) {
            do {
                try manager.copyItem(at: oldDirectory, to: newDirectory)
                try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: newDirectory.path)
            } catch {
                // A failed copy leaves the new identity empty; the user can re-import
                // keys/config rather than blocking app launch.
            }
        }
        guard let oldDefaults = UserDefaults(suiteName: oldBundleIdentifier) else { return }
        for key in preferenceKeys where defaults.object(forKey: key) == nil {
            if let value = oldDefaults.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }
}
