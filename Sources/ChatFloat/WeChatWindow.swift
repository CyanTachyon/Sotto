import AppKit
import CoreGraphics

struct WeChatWindow: Equatable {
    let id: CGWindowID
    let pid: pid_t
    /// WindowServer coordinates: origin at top-left of the primary display.
    let bounds: CGRect
    @MainActor private static let genericProvider = WeChatWindowProvider()

    /// General positioning remains independent of conversation availability.
    @MainActor static func current() -> WeChatWindow? { genericProvider.current() }
    @MainActor var appKitFrame: CGRect {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(x: bounds.minX, y: primaryTop - bounds.maxY, width: bounds.width, height: bounds.height)
    }
    static var isRelevantForeground: Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == "com.tencent.xinWeChat" || app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}

/// Each consumer owns its retention. General settings/status positioning cannot
/// seed or restore the companion's separately qualified chat target.
@MainActor final class WeChatWindowProvider {
    private var targetResolver = WeChatWindowTargetResolver()
    private var confirmedFocusedWindow: FocusedWeChatWindow.Snapshot?

    func current(accepts: (FocusedWeChatWindow.Snapshot) -> Bool = { _ in true }) -> WeChatWindow? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat")
        guard let app = apps.first(where: { $0.bundleURL?.path == "/Applications/WeChat.app" }) ?? (apps.count == 1 ? apps.first : nil),
              !app.isHidden, !app.isTerminated, let launchDate = app.launchDate else {
            targetResolver = .init(); confirmedFocusedWindow = nil; return nil
        }
        let process = WeChatWindowTargetResolver.Process(pid: app.processIdentifier, launchDate: launchDate)
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let foreground: WeChatWindowTargetResolver.Foreground = frontPID == app.processIdentifier ? .weChat :
            (frontPID == ProcessInfo.processInfo.processIdentifier ? .companion : .unrelated)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { row -> WeChatWindow? in
            guard (row[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                  (row[kCGWindowLayer as String] as? Int) == 0,
                  let id = row[kCGWindowNumber as String] as? UInt32,
                  let box = row[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: box as CFDictionary),
                  rect.width > 380, rect.height > 300 else { return nil }
            return WeChatWindow(id: id, pid: app.processIdentifier, bounds: rect)
        }
        let focused = foreground == .unrelated ? nil : FocusedWeChatWindow.capture()
        let validFocus = focused.flatMap { snapshot in
            snapshot.pid == app.processIdentifier && snapshot.processLaunchDate == launchDate ? snapshot : nil
        }
        let eligible = validFocus.map(accepts) ?? false
        let continuity = validFocus.flatMap { snapshot in confirmedFocusedWindow.map { snapshot.isSameWindow(as: $0) } } ?? false
        let target = targetResolver.resolve(process: process, foreground: foreground,
            focusedBounds: validFocus?.bounds, focusContinuityVerified: continuity,
            targetIsEligible: eligible, windows: windows)
        confirmedFocusedWindow = target == nil ? nil : validFocus
        return target
    }
}

/// Focus evidence chooses a window; WindowServer order only supplies liveness/geometry.
/// This value-only policy is exercised with two synthetic windows in WindowChecks.
struct WeChatWindowTargetResolver {
    struct Process: Equatable { let pid: pid_t; let launchDate: Date }
    enum Foreground { case weChat, companion, unrelated }
    private var process: Process?
    private(set) var confirmed: WeChatWindow?

    mutating func resolve(process observedProcess: Process?, foreground: Foreground,
                          focusedBounds: CGRect?, focusContinuityVerified: Bool = false,
                          targetIsEligible: Bool = true,
                          windows: [WeChatWindow]) -> WeChatWindow? {
        guard let observedProcess else { process = nil; confirmed = nil; return nil }
        if process != observedProcess { confirmed = nil; process = observedProcess }
        guard targetIsEligible else { confirmed = nil; return nil }
        guard foreground != .unrelated else { confirmed = nil; return nil }
        let live = windows.filter { $0.pid == observedProcess.pid && Self.usable($0.bounds) }
        guard let focusedBounds, Self.usable(focusedBounds) else { confirmed = nil; return nil }
        let matches = live.filter { Self.matches($0.bounds, focusedBounds) }
        guard matches.count == 1 else { confirmed = nil; return nil }
        if foreground == .weChat {
            confirmed = matches[0]
        } else {
            // The helper may be frontmost after the bubble is clicked. Do not select
            // another window. Fresh AX evidence must still name the same AX object
            // and map uniquely to the retained CG ID, guarding closed/ID-reused windows.
            guard focusContinuityVerified, let retained = confirmed,
                  matches[0].id == retained.id, matches[0].pid == retained.pid else { confirmed = nil; return nil }
            confirmed = matches[0]
        }
        return confirmed
    }
    private static func usable(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 380 && rect.height > 300
    }
    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 &&
        abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
    }
}
