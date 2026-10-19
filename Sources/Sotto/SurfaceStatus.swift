import AppKit
import CoreGraphics

@MainActor extension AppDelegate {
    func writeSurfaceStatus() {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        func info(_ window: NSWindow?) -> [String: Any] {
            guard let window else { return [:] }
            let index = windows.firstIndex { ($0[kCGWindowNumber as String] as? UInt32) == UInt32(window.windowNumber) }
            return ["windowID": window.windowNumber, "visible": window.isVisible, "onScreen": index != nil, "z": index ?? -1,
                    "bounds": index.flatMap { windows[$0][kCGWindowBounds as String] } ?? NSNull(), "level": window.level.rawValue]
        }
        let target = WeChatWindow.current()
        let targetIndex = target.flatMap { target in windows.firstIndex { ($0[kCGWindowNumber as String] as? UInt32) == target.id } }
        let report: [String: Any] = ["companionEnabled": model.companionEnabled, "expanded": model.companionExpanded,
            "presentationMode": testMode ? "developer_fixture" : "wechat_companion_only",
            "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
            "standalone": info(panel), "bubble": info(companion?.bubble), "companion": info(companion?.panel),
            "wechatOnScreen": target != nil, "wechatZ": targetIndex ?? -1,
            "wechatBounds": targetIndex.flatMap { windows[$0][kCGWindowBounds as String] } ?? NSNull(),
            "answerCount": model.turns.count, "streamingCharacters": model.streamingText.count,
            "followingWindow": model.isFollowingWindow, "manualConversationSelection": model.hasManualConversationSelection, "needsConversationSelection": model.needsConversationSelection, "followState": model.followState,
            "checkedAt": Date().timeIntervalSince1970]
        let directory = experiencePreview ? Bundle.main.bundleURL.deletingLastPathComponent() : model.local?.directory
        if let directory, let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let file = directory.appendingPathComponent("surface-status.json")
            try? data.write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            if experiencePreview, let fixture = panel {
                render(model.companionExpanded ? companion?.panel ?? fixture : fixture, directory.appendingPathComponent("preview-view.png"))
            }
        }
    }
}
