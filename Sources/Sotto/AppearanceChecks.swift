import AppKit
import SwiftUI
import SottoCore

@MainActor extension AppDelegate {
    /// Entirely synthetic native rendering; never discovers accounts or reads credentials.
    func runAppearanceChecks(output: String) async {
        let directory = URL(fileURLWithPath: output)
        var checks: [String: Bool] = [:]
        let suite = "moe.tachyon.sotto.AppearanceCheck." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let savedPreferences = ["selectedDatabaseGroupV3", "followCurrentConversationV4"].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            panel.orderOut(nil)
            let controller = AppAppearanceController(defaults: defaults)
            checks["default_follows_system"] = controller.mode == .system
            controller.start()
            checks["system_uses_inherited_appearance"] = NSApp.appearance == nil
            let sample = AppModel(testMode: true)
            try sample.loadExperiencePreview()
            sample.companionEnabled = false
            sample.companionExpanded = true
            let empty = AppModel(testMode: true); empty.config = ModelConfig()
            let connected = AppModel(testMode: true); connected.root = "/synthetic/appearance/db_storage"
            connected.databaseConnectionSource = .init(readManifest: { _ in
                #"{"keys":{"contact/contact.db":{"enc_key":"0000000000000000000000000000000000000000000000000000000000000000"}}}"#
            }, readGroups: { root in
                .init(account: DatabaseBridge.account(root), groups: [.init(id: "preview-private", name: "虚构联系人", aliases: []), .init(id: "preview-group@chatroom", name: "虚构项目群 🌿", aliases: [])])
            })
            connected.connect(userInitiated: false)
            for _ in 0..<100 { if !connected.connecting { break }; try await Task.sleep(for: .milliseconds(20)) }
            connected.groupID = ""
            checks["synthetic_connected_state_ready"] = connected.hasDatabaseConnection && connected.selectedGroup == nil
            let fixtures: [(String, AnyView, NSSize)] = [
                ("chat", AnyView(FloatView(model: sample)), .init(width: 400, height: 760)),
                ("chat-compact", AnyView(FloatView(model: sample)), .init(width: 360, height: 600)),
                ("welcome", AnyView(FloatView(model: empty)), .init(width: 400, height: 600)),
                ("connected-empty", AnyView(FloatView(model: connected)), .init(width: 400, height: 600)),
                ("settings", AnyView(SettingsView(model: sample, appearance: controller)), .init(width: 520, height: 720)),
                ("setup", AnyView(SettingsView(model: empty, appearance: controller)), .init(width: 520, height: 900)),
                ("connection", AnyView(ConnectionView(model: connected)), .init(width: 560, height: 650)),
                ("sources", AnyView(SourcesView(model: sample)), .init(width: 500, height: 650)),
                ("picker", AnyView(ConversationPicker(model: connected, close: {})), .init(width: 362, height: 432)),
                ("markdown", AnyView(MarkdownView(text: "## 讨论小结\n\n**粗体**、*斜体*、`行内代码` 和 [链接](https://example.com)。\n\n- 第一项\n  - 嵌套项\n\n> 引用与正文有清楚区分。\n\n| 功能 | 状态 |\n| --- | --- |\n| 群聊与私聊 | 都支持 |\n| 流式输出 | 逐段显示 |\n\n```swift\nlet greeting = \"你好，世界\"\nprint(greeting)\n```\n\n最后一段。").padding(20).frame(width: 420).background(AppTheme.surface).foregroundStyle(AppTheme.textPrimary)), .init(width: 420, height: 650))
            ]
            var windows: [(String, NSWindow)] = []
            for (name, view, size) in fixtures {
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = NSHostingView(rootView: view)
                window.setContentSize(size)
                windows.append((name, window))
            }
            for mode in [AppAppearanceMode.light, .dark] {
                controller.mode = mode
                try await Task.sleep(for: .milliseconds(250))
                checks["\(mode.rawValue)_applied_to_existing_windows"] = windows.allSatisfy { $0.1.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == mode.appKitAppearance?.name }
                checks["\(mode.rawValue)_preference_survives_controller_recreation"] = AppAppearanceController(defaults: defaults).mode == mode
                for (name, window) in windows {
                    window.contentView?.layoutSubtreeIfNeeded()
                    let url = directory.appendingPathComponent("\(name)-\(mode.rawValue).png")
                    render(window, url)
                    checks["\(name)_\(mode.rawValue)_rendered"] = (try? Data(contentsOf: url).count).map { $0 > 5_000 } ?? false
                }
                let nextWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                checks["\(mode.rawValue)_new_window_inherits"] = nextWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == mode.appKitAppearance?.name
            }
            controller.mode = .system
            checks["return_to_system_removes_override"] = NSApp.appearance == nil && windows.allSatisfy { $0.1.appearance == nil }
        } catch { checks["unexpected_error"] = false }
        let passed = !checks.isEmpty && checks.values.allSatisfy { $0 }
        let report: [String: Any] = ["checks": checks, "passed": passed, "syntheticOnly": true, "realChatRead": false, "remoteRequests": 0]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("appearance-checks.json")) }
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in savedPreferences { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        exit(passed ? 0 : 2)
    }
}
