import AppKit
import ApplicationServices
import SottoCore

/// A fresh observation of WeChat's actual AX focused window. No main-window or
/// previously observed window is substituted when the focus is unavailable.
@MainActor enum FocusedWeChatWindow {
    struct Snapshot {
        let pid: pid_t
        let processLaunchDate: Date
        let bounds: CGRect // AX and CG window metadata both use top-origin coordinates.
        let title: String?
        let root: AXUIElement
        let window: AXUIElement
        let metadata: WeChatWindowMetadata?

        init(pid: pid_t, processLaunchDate: Date, bounds: CGRect, title: String?,
             root: AXUIElement, window: AXUIElement, metadata: WeChatWindowMetadata? = nil) {
            self.pid = pid; self.processLaunchDate = processLaunchDate; self.bounds = bounds
            self.title = title; self.root = root; self.window = window; self.metadata = metadata
        }

        func isSameWindow(as other: Snapshot) -> Bool {
            pid == other.pid && processLaunchDate == other.processLaunchDate && CFEqual(window, other.window)
        }
    }

    private static func application() -> NSRunningApplication? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat")
            .filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first, !app.isHidden else { return nil }
        return app
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func focused(_ root: AXUIElement) -> AXUIElement? {
        guard let result = value(root, kAXFocusedWindowAttribute), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func windowMetadata(_ window: AXUIElement) -> WeChatWindowMetadata {
        let role = value(window, kAXRoleAttribute) as? String
        let subrole = value(window, kAXSubroleAttribute) as? String
        let modal = value(window, kAXModalAttribute) as? Bool
        var document: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document)
        let present: Bool?
        if status == .success { present = document != nil }
        else if status == .attributeUnsupported || status == .noValue { present = false }
        else { present = nil }
        // The value is neither interpreted nor retained: document URLs are not
        // needed to decide whether a window is a document/preview surface.
        return .init(role: role, subrole: subrole, isModal: modal, hasDocument: present)
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position = value(window, kAXPositionAttribute), let size = value(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 320, dimensions.height > 250 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func capture() -> Snapshot? {
        guard AXIsProcessTrusted(), let app = application(), let launchDate = app.launchDate else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.12)
        guard let window = focused(root) else { return nil }
        AXUIElementSetMessagingTimeout(window, 0.12)
        guard (value(window, kAXMinimizedAttribute) as? Bool) != true, let bounds = frame(window) else { return nil }
        let snapshot = Snapshot(pid: app.processIdentifier, processLaunchDate: launchDate, bounds: bounds,
                                title: value(window, kAXTitleAttribute) as? String, root: root, window: window,
                                metadata: windowMetadata(window))
        return isCurrent(snapshot) ? snapshot : nil
    }

    /// Validate after using the observation, including a second focused-window read
    /// after title/geometry queries so a mid-read focus change fails closed.
    static func isCurrent(_ snapshot: Snapshot, requireSameTitle: Bool = true) -> Bool {
        guard AXIsProcessTrusted(), let app = application(), app.processIdentifier == snapshot.pid,
              app.launchDate == snapshot.processLaunchDate,
              let before = focused(snapshot.root), CFEqual(before, snapshot.window),
              (value(snapshot.window, kAXMinimizedAttribute) as? Bool) != true,
              frame(snapshot.window) == snapshot.bounds else { return false }
        if requireSameTitle, (value(snapshot.window, kAXTitleAttribute) as? String) != snapshot.title { return false }
        if let metadata = snapshot.metadata, windowMetadata(snapshot.window) != metadata { return false }
        guard let after = focused(snapshot.root), CFEqual(after, snapshot.window),
              let current = application(), current.processIdentifier == snapshot.pid,
              current.launchDate == snapshot.processLaunchDate else { return false }
        return true
    }
}
