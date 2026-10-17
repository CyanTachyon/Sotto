import AppKit
import SwiftUI
import Combine
import ChatCore
import Darwin

// Local read-chain check: stdin only, counts only; no stored credential or network access.
if CommandLine.arguments.contains("--reader-check") {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    Task { await ReaderAcceptance.run(input: input) }
    dispatchMain()
}

// Private IPC sink. Secrets arrive only on stdin and are saved in the local credential store.
if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--store-db-keys" {
    do {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        try CredentialStore.saveDatabase(String(decoding: input, as: UTF8.self), account: CommandLine.arguments[2])
        exit(0)
    } catch { exit(2) }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--credential-status" {
    var report: [String: Any] = ["storage": "local_file", "authenticationPrompts": false,
                               "modelCredential": "not_configured", "databaseCredential": "not_configured"]
    if let data = UserDefaults.standard.data(forKey: "modelConfig"), let config = try? JSONDecoder().decode(ModelConfig.self, from: data) {
        if !config.endpoint.isEmpty {
            do { report["modelCredential"] = try CredentialStore.read(endpoint: config.endpoint).isEmpty ? "missing" : "available" }
            catch { report["modelCredential"] = "unreadable" }
        }
    }
    if let root = UserDefaults.standard.string(forKey: "databaseRoot"), !root.isEmpty {
        do { report["databaseCredential"] = try CredentialStore.database(DatabaseBridge.account(root)).isEmpty ? "missing" : "available" }
        catch { report["databaseCredential"] = "unreadable" }
    }
    report["counts"] = CredentialStore.diagnosticCounts
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        exit(0)
    } catch { exit(2) }
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--control" {
    let command = CommandLine.arguments[2]
    guard ["status", "surface-status", "assist", "permissions", "connect", "focus", "hide", "quit", "follow-status", "accessibility"].contains(command) else { exit(2) }
    DistributedNotificationCenter.default().postNotificationName(.init("cn.local.ChatFloat.control"), object: nil, userInfo: ["command": command, "bundlePath": Bundle.main.bundleURL.path], deliverImmediately: true)
    exit(0)
}

/// Keep one GUI instance. Helper/check invocations stay reusable so tests and
/// `--control` can run while the menu-bar app is open. The lock file is advisory
/// only; it prevents accidental duplicate menu-bar apps and duplicate bubble panels.
private func acquireSingleInstanceLock() -> Int32? {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("cn.local.ChatFloat", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let path = directory.appendingPathComponent("app.lock").path
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return -1 }
    if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
    close(descriptor)
    return nil
}

let helperInvocation = CommandLine.arguments.contains { argument in
    ["--reader-check", "--store-db-keys", "--credential-status", "--control",
     "--companion-window-check", "--experience-check", "--appearance-check",
     "--ui-test", "--synthetic-model-check", "--appearance-preview"].contains(argument)
} || Bundle.main.bundleIdentifier == "cn.local.ChatFloat.ExperiencePreview"
if !helperInvocation, acquireSingleInstanceLock() == nil {
    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "cn.local.ChatFloat")
        .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        running.activate(options: [])
    }
    exit(0)
}

final class MainWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class AuxiliaryWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let onClose: () -> Void
    init(title: String, size: NSSize, root: AnyView, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let available = screen.visibleFrame
        let fitted = NSSize(width: min(size.width, available.width - 40), height: min(size.height, available.height - 90))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: fitted), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title; window.isReleasedWhenClosed = false; window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        window.animationBehavior = .none
        window.minSize = NSSize(width: min(440, fitted.width), height: min(400, fitted.height))
        window.contentView = NSHostingView(rootView: root)
        window.delegate = self; window.center()
        window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
    }
    func present() {
        window.level = .normal
        // The settings were previously ordered on their old desktop without
        // activating the application. Present beside the invoking WeChat window,
        // then explicitly give this independent window keyboard focus.
        let target = WeChatWindow.current()?.appKitFrame
        let screen = target.flatMap { frame in NSScreen.screens.max { a, b in
            a.frame.intersection(frame).width * a.frame.intersection(frame).height < b.frame.intersection(frame).width * b.frame.intersection(frame).height
        } } ?? NSScreen.main ?? NSScreen.screens[0]
        if !window.isVisible || window.screen !== screen {
            let area = screen.visibleFrame
            var frame = window.frame
            frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
            window.setFrame(window.constrainFrameRect(frame, to: screen), display: false)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    func hide() { window.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: MainWindow!
    var companion: CompanionController?
    var status: NSStatusItem!
    var controlObserver: NSObjectProtocol?
    var observations = Set<AnyCancellable>()
    var connectionWindow: AuxiliaryWindow?
    var settingsWindow: AuxiliaryWindow?
    var sourcesWindow: AuxiliaryWindow?
    let experiencePreview = Bundle.main.bundleIdentifier == "cn.local.ChatFloat.ExperiencePreview"
    let appearancePreview = CommandLine.arguments.contains("--appearance-preview")
    var testMode: Bool { experiencePreview || appearancePreview || CommandLine.arguments.contains("--companion-window-check") || CommandLine.arguments.contains("--experience-check") || CommandLine.arguments.contains("--appearance-check") || CommandLine.arguments.contains("--ui-test") || CommandLine.arguments.contains("--synthetic-model-check") }
    lazy var model = AppModel(testMode: testMode)
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The synthetic preview changes selection preferences, so require a
        // separately identified bundle before constructing its model.
        if appearancePreview {
            guard let identifier = Bundle.main.bundleIdentifier,
                  identifier != "cn.local.ChatFloat" else { exit(2) }
        }
        if experiencePreview || appearancePreview { try? model.loadExperiencePreview() }
        if appearancePreview {
            model.companionEnabled = false
            model.config = ModelConfig()
            model.identity = "外观预览 · 全部为虚构内容"
        }
        // A production launch is a regular application with a main window,
        // Dock icon and Command-Tab entry. Test/preview modes stay accessory so
        // their synthetic fixtures do not appear as a second app. The companion
        // is still a floating panel and the status item remains available.
        // NOTE: the 0.5.2 input-method Space behavior was fixed with an
        // accessory-only app; making the production app regular requires real
        // Chinese IME/desktop retesting before calling that regression closed.
        NSApp.setActivationPolicy(testMode || appearancePreview ? .accessory : .regular)
        NSApp.mainMenu = AppMenus.makeMainMenu()
        if let windowsMenu = NSApp.mainMenu?.items.last?.submenu { NSApp.windowsMenu = windowsMenu }
        AppAppearanceController.shared.start()
        if !appearancePreview { createMainWindow() }
        model.$showConnection.removeDuplicates().sink { [weak self] visible in self?.showConnection(visible) }.store(in: &observations)
        model.$showSettings.removeDuplicates().sink { [weak self] visible in self?.showSettings(visible) }.store(in: &observations)
        model.$showSources.removeDuplicates().sink { [weak self] visible in self?.showSources(visible) }.store(in: &observations)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: "群聊伴读")
        let menu = NSMenu()
        menu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "打开微信旁的伴读", action: #selector(showPanel), keyEquivalent: "")
        menu.addItem(withTitle: "连接设置…", action: #selector(connection), keyEquivalent: "")
        menu.addItem(withTitle: "外观与设置…", action: #selector(settings), keyEquivalent: ",")
        menu.addItem(.separator()); menu.addItem(withTitle: "退出群聊伴读", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }; status.menu = menu
        controlObserver = DistributedNotificationCenter.default().addObserver(forName: .init("cn.local.ChatFloat.control"), object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                if let target = notification.userInfo?["bundlePath"] as? String, target != Bundle.main.bundleURL.path { return }
                if let command = notification.userInfo?["command"] as? String { self?.handleControl(command) }
            }
        }
        if !appearancePreview && (!testMode || experiencePreview) {
            companion = CompanionController(model: model, fixtureWindow: panel)
        }
        if testMode {
            model.$companionEnabled.dropFirst().sink { [weak self] enabled in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if enabled { self.panel?.orderOut(nil); self.companion?.update() }
                    else { self.companion?.hide(); self.showPanel() }
                }
            }.store(in: &observations)
        }
        if !CommandLine.arguments.contains("--background") {
            if testMode {
                showPanel()
            } else if !CommandLine.arguments.contains("--connect") && !CommandLine.arguments.contains("--assist-setup") {
                showMainWindow()
            }
        }
        if appearancePreview { return }
        if let i = CommandLine.arguments.firstIndex(of: "--companion-window-check"), CommandLine.arguments.count > i + 1 { runCompanionWindowChecks(output: URL(fileURLWithPath: CommandLine.arguments[i+1])) }
        else if let i = CommandLine.arguments.firstIndex(of: "--experience-check"), CommandLine.arguments.count > i + 1 { runExperienceChecks(output: URL(fileURLWithPath: CommandLine.arguments[i+1])) }
        else if let i = CommandLine.arguments.firstIndex(of: "--appearance-check"), CommandLine.arguments.count > i + 1 { Task { await runAppearanceChecks(output: CommandLine.arguments[i+1]) } }
        else if CommandLine.arguments.contains("--ui-test") { runUITest() }
        else if CommandLine.arguments.contains("--synthetic-model-check") { runSyntheticModelCheck() }
        else if CommandLine.arguments.contains("--assist-setup") {
            model.showConnection = true
            model.assistSetup(openPermissions: false)
        } else if CommandLine.arguments.contains("--connect") { model.showConnection = true }
        if !testMode { model.writeConnectionStatus(); if !model.root.isEmpty && !CommandLine.arguments.contains("--assist-setup") { model.assistSetup(openPermissions: false) } }
    }
    /// The production main window is a regular AppKit window hosting the same
    /// conversation UI as the companion. Test modes reuse it as a synthetic
    /// fixture, with a different title/size and no persisted frame.
    private func createMainWindow() {
        let fixture = testMode
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let available = screen.visibleFrame
        let desired = fixture ? NSSize(width: min(400, available.width - 32), height: min(600, available.height - 80))
                             : NSSize(width: min(460, available.width - 40), height: min(720, available.height - 90))
        panel = MainWindow(contentRect: NSRect(origin: .zero, size: desired), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = fixture ? "群聊伴读 · 合成检查" : "群聊伴读"
        panel.titleVisibility = fixture ? .hidden : .visible
        panel.titlebarAppearsTransparent = fixture
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.collectionBehavior = []
        panel.minSize = NSSize(width: min(fixture ? 360 : 420, desired.width), height: min(fixture ? 480 : 560, desired.height))
        panel.contentView = NSHostingView(rootView: FloatView(model: model,
            onConversationPickerChange: { _ in },
            showsCollapseControl: fixture))
        if !fixture { _ = panel.setFrameAutosaveName("ChatFloatMainWindow") }
        panel.center()
        panel.setFrame(panel.constrainFrameRect(panel.frame, to: screen), display: false)
        model.isStandaloneConversationVisible = { [weak self] in
            guard let panel = self?.panel else { return false }
            return panel.isVisible && !panel.isMiniaturized
        }
    }
    func handleControl(_ command: String) {
        switch command {
        case "status": model.writeConnectionStatus()
        case "surface-status": writeSurfaceStatus()
        case "follow-status": Task { _ = await model.inspectFollow(); model.writeConnectionStatus() }
        case "accessibility": CurrentWeChat.requestPermission()
        case "assist": model.assistSetup(openPermissions: false)
        case "permissions": model.openDataPermissionSettings()
        case "connect": model.connect(userInitiated: false)
        case "focus": connection()
        case "hide": companion?.hide(); model.companionExpanded = false; panel?.orderOut(nil); connectionWindow?.hide(); settingsWindow?.hide(); sourcesWindow?.hide()
        case "quit": quit()
        default: break
        }
    }
    func showConnection(_ visible: Bool) {
        if visible {
            companion?.hide()
            if connectionWindow == nil {
                connectionWindow = AuxiliaryWindow(title: "连接微信 · 群聊伴读", size: NSSize(width: 560, height: 580), root: AnyView(ConnectionView(model: model))) { [weak self] in self?.model.showConnection = false }
            }
            connectionWindow?.present()
        } else { connectionWindow?.hide(); resumeCompanionAfterAuxiliary() }
    }
    func showSettings(_ visible: Bool) {
        if visible {
            companion?.hide()
            if settingsWindow == nil {
                settingsWindow = AuxiliaryWindow(title: "外观与设置 · 群聊伴读", size: NSSize(width: 520, height: 620), root: AnyView(SettingsView(model: model))) { [weak self] in self?.model.showSettings = false }
            }
            settingsWindow?.present()
        } else { settingsWindow?.hide(); resumeCompanionAfterAuxiliary() }
    }
    func showSources(_ visible: Bool) {
        if visible {
            companion?.hide()
            if sourcesWindow == nil {
                sourcesWindow = AuxiliaryWindow(title: "原消息 · 群聊伴读", size: NSSize(width: 500, height: 540), root: AnyView(SourcesView(model: model))) { [weak self] in self?.model.showSources = false }
            }
            sourcesWindow?.present()
        } else { sourcesWindow?.hide(); resumeCompanionAfterAuxiliary() }
    }
    private func resumeCompanionAfterAuxiliary() {
        // Published values reach subscribers before the stored property changes.
        DispatchQueue.main.async { [weak self] in self?.companion?.resumeAfterAuxiliary() }
    }
    @objc func showPanel() {
        if model.companionEnabled, companion?.present() == true { panel?.orderOut(nil); return }
        showMainWindow()
    }
    @objc func showMainWindow() {
        if !testMode { NSApp.setActivationPolicy(.regular) }
        guard let panel else { return }
        companion?.hide()
        model.companionExpanded = false
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    @objc func connection() { if model.showConnection { showConnection(true) } else { model.showConnection = true } }
    @objc func settings() { if model.showSettings { showSettings(true) } else { model.showSettings = true } }
    @objc func quit() {
        guard !model.initializing else { NSSound.beep(); return }
        model.showConnection = false; model.showSettings = false; model.showSources = false
        NSApp.terminate(nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.initializing { NSSound.beep(); return .terminateCancel }
        model.cancel(); return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func runSyntheticModelCheck() {
        guard let index = CommandLine.arguments.firstIndex(of: "--synthetic-model-check"), CommandLine.arguments.count > index + 1 else { exit(2) }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        Task { await SyntheticAcceptance.run(config: model.config, output: output) }
    }

    func runUITest() {
        // No desktop screenshot, WeChat read, or model request. Render only our own running views.
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-test"), CommandLine.arguments.count > index + 1 else { NSApp.terminate(nil); return }
        let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            var checks: [(String, Bool)] = []
            checks.append(("default main window normal", panel.level == .normal && !panel.styleMask.contains(.nonactivatingPanel)))
            checks.append(("default 30 minutes and seven day preset", model.range == 1800 && AppModel.timePresets.contains(where: { $0.0 == 604800 })))
            checks.append(("small default content size", panel.contentLayoutRect.width <= 400 && panel.contentLayoutRect.height <= 600))
            checks.append(("main resizable and minimizable", panel.styleMask.contains([.resizable, .miniaturizable])))
            model.showConnection = true; model.showSettings = true; model.showSources = true
            for (name, controller) in [("connection", connectionWindow), ("settings", settingsWindow), ("sources", sourcesWindow)] {
                let window = controller!.window
                checks.append((name + " normal independent", window.level == .normal && window.parent == nil && window.sheetParent == nil))
                checks.append((name + " resizable minimizable", window.styleMask.contains([.resizable, .miniaturizable])))
                let frame = (window.screen ?? NSScreen.main!).visibleFrame
                checks.append((name + " fits screen", window.frame.width <= frame.width && window.frame.height <= frame.height))
            }
            let keyWindow = NSApp.keyWindow
            let visibility = [panel.isVisible, connectionWindow!.window.isVisible, settingsWindow!.window.isVisible]
            handleControl("status")
            checks.append(("background status preserves focus and visibility", NSApp.keyWindow === keyWindow && visibility == [panel.isVisible, connectionWindow!.window.isVisible, settingsWindow!.window.isVisible]))
            model.showConnection = false; model.showSettings = false; model.showSources = false
            render(panel, output.appendingPathComponent("05-small-main.png"))
            model.showConnection = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                render(connectionWindow!.window, output.appendingPathComponent("06-normal-connection.png"))
                model.showConnection = false; model.showSettings = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    render(settingsWindow!.window, output.appendingPathComponent("07-normal-settings.png"))
                    let report = checks.map { ($0.1 ? "PASS " : "FAIL ") + $0.0 }.joined(separator: "\n") + "\nNo real chat, database read, screenshot of other apps, or model request.\n"
                    try? report.write(to: output.appendingPathComponent("window-interaction-checks.txt"), atomically: true, encoding: .utf8)
                    if checks.contains(where: { !$0.1 }) { exit(2) }
                    model.showSettings = false
                    try? model.loadSyntheticPreview()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                        func scroll(_ view: NSView) {
                            if let view = view as? NSScrollView { view.documentView?.scroll(.init(x: 0, y: view.documentView?.bounds.maxY ?? 0)) }
                            for child in view.subviews { scroll(child) }
                        }
                        if let content = panel.contentView { scroll(content) }
                        render(panel, output.appendingPathComponent("08-synthetic-narrative.png"))
                        checkWindowOrdering(output: output)
                    }
                }
            }
        }
    }
    func render(_ window: NSWindow, _ url: URL) {
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
