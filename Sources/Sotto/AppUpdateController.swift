import AppKit
import Combine
import Sparkle
import SottoCore

// Sparkle's standard driver invokes its delegate on the UI thread, but its
// Objective-C protocol lacks the actor annotation present on SPUUpdaterDelegate.
@MainActor final class AppUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let feedURL = "https://github.com/CyanTachyon/Sotto/releases/latest/download/appcast.xml"
    // Views used by synthetic appearance checks never create an updater.
    static let disabled = AppUpdateController(model: nil, enabled: false)

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var status = "合成检查中不连接更新服务。"
    @Published private(set) var hasUpdateReminder = false
    private weak var model: AppModel?
    private let enabled: Bool
    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private var approvedInstallation = false

    init(model: AppModel?, enabled: Bool) {
        self.model = model
        self.enabled = enabled
        super.init()
        guard enabled else { return }
        guard Bundle.main.bundleIdentifier == "moe.tachyon.sotto",
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32,
              Bundle.main.object(forInfoDictionaryKey: "SURequireSignedFeed") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true,
              Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false else {
            status = "此构建未配置完整的安全更新，请从发布页下载。"
            return
        }
        let standard = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller = standard
        standard.updater.automaticallyDownloadsUpdates = false
        standard.updater.publisher(for: \.canCheckForUpdates).sink { [weak self] value in
            MainActor.assumeIsolated { self?.canCheckForUpdates = value }
        }.store(in: &observations)
        standard.updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] value in
            MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = value }
        }.store(in: &observations)
        status = "仅检查新版本；下载与重启安装均由你决定。"
        standard.startUpdater()
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(sender)
    }

    func setAutomaticallyChecksForUpdates(_ value: Bool) {
        guard enabled, let controller else { return }
        controller.updater.automaticallyChecksForUpdates = value
    }

    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    // Menu-bar apps have no Dock badge. Keep scheduled reminders in our own
    // menu/status item; an explicit click brings Sparkle's update alert forward.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated {
            hasUpdateReminder = true
            status = "发现新版本 \(update.displayVersionString)。点击「查看新版本…」了解详情并决定是否安装。"
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        hasUpdateReminder = false
        status = "更新窗口已打开；下载与重启安装均由你决定。"
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasUpdateReminder = false
        status = "仅检查新版本；下载与重启安装均由你决定。"
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard enabled, model?.initializing != true else {
            throw NSError(domain: "moe.tachyon.sotto.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请在首次连接初始化完成后再检查更新。"])
        }
    }

    // Sparkle 2.10 invokes this before advancing installation. Unlike the
    // postpone hook it can reject installation, and it must reply synchronously.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        approvedInstallation = false
        guard let model else { return false }
        switch UpdatePolicy.installationDecision(enabled: enabled, initializing: model.initializing,
                                                  busy: model.busy,
                                                  hasEphemeralContent: model.hasEphemeralConversationContent) {
        case .unavailable: return false
        case .initializing:
            explainDeferredInstallation("首次连接尚未完成", detail: "请等待初始化完成，再安装更新。")
            return false
        case .generatingAnswer:
            explainDeferredInstallation("正在生成回答", detail: "请等待回答完成，或先停止生成，再安装更新。")
            return false
        case .confirmContentLoss:
            let alert = NSAlert()
            alert.messageText = "保存需要的回答和草稿后再更新"
            alert.informativeText = "安装更新会退出并重新打开 Sotto，所有会话中的回答、草稿和参考快照都会清空。请先复制需要保留的内容。"
            alert.addButton(withTitle: "稍后更新")
            alert.addButton(withTitle: "已保存，重启安装")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            // Modal panels run the event loop; initialization/generation may
            // have started while the confirmation was visible.
            guard !model.initializing, !model.busy else { return false }
        case .allow: break
        }
        approvedInstallation = true
        return true
    }

    /// Recheck at actual termination in case work began after install approval.
    func allowsApplicationTermination() -> Bool {
        guard approvedInstallation, let model else { return true }
        guard !model.busy, !model.initializing else {
            approvedInstallation = false
            return false
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        approvedInstallation = false
    }

    private func explainDeferredInstallation(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
