import AppKit
import ApplicationServices
import SottoCore

/// Reads only focused-window/header/selected-conversation metadata. Chat content is never read here.
@MainActor enum CurrentWeChat {
    struct Detection {
        let group: DBGroup?
        let state: String
        let visited: Int
        let evidenceCount: Int
        let roleCounts: [String: Int]
        let focusedWindow: FocusedWeChatWindow.Snapshot?
        init(group: DBGroup?, state: String, visited: Int, evidenceCount: Int, roleCounts: [String: Int],
             focusedWindow: FocusedWeChatWindow.Snapshot? = nil) {
            self.group = group; self.state = state; self.visited = visited
            self.evidenceCount = evidenceCount; self.roleCounts = roleCounts
            self.focusedWindow = focusedWindow
        }
        var message: String {
            switch state {
            case "confirmed":
                return focusedWindow != nil
                    ? "已跟随微信窗口标题 · 无需截图"
                    : "已跟随微信当前会话 · 点击助手后仍保留微信目标"
            case "permissionRequired": return "尚未授予 Sotto 辅助功能权限，无法识别当前会话"
            case "notRunning": return "微信未运行，当前会话读取已暂停"
            case "noWindow": return "没有可确认的微信当前窗口，请在微信打开目标会话"
            case "unsupportedWindow": return "当前窗口未确认为聊天窗口，已暂停跟随；请返回微信聊天窗口"
            case "ambiguous": return "存在同名会话，无法唯一确认；请选择当前会话"
            case "conflicting": return "微信标题与选中会话尚不一致，已暂停等待切换完成"
            case "incomplete": return "微信会话信息暂未读取完整，已暂停等待下一次确认"
            case "unmatched": return "当前会话未匹配到已连接的会话；数据库可能尚未同步"
            default: return "微信未提供可确认的会话元数据；请选择当前会话"
            }
        }
    }
    static var trusted: Bool { AXIsProcessTrusted() }
    private static var queryFailed = false
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !trusted {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
    }
    private static func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(node, name as CFString, &value)
        if [.cannotComplete, .apiDisabled, .invalidUIElement].contains(status) { queryFailed = true }
        return status == .success ? value : nil
    }
    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(node, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func frame(_ node: AXUIElement) -> CGRect? {
        guard let p = attribute(node, kAXPositionAttribute), let s = attribute(node, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private static func children(_ node: AXUIElement) -> [AXUIElement] { attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func focusedWindowMetadata() -> FocusedWeChatWindow.Snapshot? { FocusedWeChatWindow.capture() }
    static func detect(from groups: [DBGroup]) -> Detection {
        func empty(_ state: String) -> Detection { Detection(group: nil, state: state, visited: 0, evidenceCount: 0, roleCounts: [:]) }
        guard trusted else { return empty("permissionRequired") }
        guard let snapshot = focusedWindowMetadata() else {
            return empty(NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.xinWeChat").isEmpty ? "notRunning" : "noWindow")
        }
        let candidates = groups.map { TitleCandidate(id: $0.id, aliases: [$0.name] + $0.aliases) }
        guard WeChatWindowEligibility.classify(title: snapshot.title, metadata: snapshot.metadata,
                                               candidates: candidates) != .unsupported else {
            return Detection(group: nil, state: "unsupportedWindow", visited: 0, evidenceCount: 0,
                             roleCounts: [:])
        }
        let exact = FocusedTitleIdentity.resolve(snapshot.title, candidates: candidates)
        if exact.state != .noMetadata {
            // Independent chat windows expose a complete AXTitle. Never scan another
            // window or reinterpret an unmatched/ambiguous exact title.
            guard FocusedWeChatWindow.isCurrent(snapshot) else {
                return Detection(group: nil, state: "incomplete", visited: 0, evidenceCount: 1,
                                 roleCounts: [:])
            }
            return Detection(group: exact.id.flatMap { id in groups.first { $0.id == id } }, state: exact.state.rawValue,
                             visited: 0, evidenceCount: 1, roleCounts: [:], focusedWindow: snapshot)
        }
        queryFailed = false
        // Preserve header/selected-row support for a generic main-window title, but
        // only within this same real focused window; never substitute AXMainWindow.
        let window = snapshot.window
        let bounds = snapshot.bounds
        var evidence: [ConversationEvidence] = []
        if let title = snapshot.title { evidence.append(ConversationEvidence(title, kind: .windowTitle)) }
        if let label = element(window, kAXTitleUIElementAttribute) {
            for name in [kAXTitleAttribute, kAXValueAttribute] {
                if let title = attribute(label, name) as? String { evidence.append(ConversationEvidence(title, kind: .header)) }
            }
        }
        struct Node { let node: AXUIElement; let role: String; let rect: CGRect?; let toolbar: Bool; let selectedRow: Bool }
        var nodes: [Node] = []; var complete = true
        let deadline = Date().addingTimeInterval(0.35)
        func walk(_ node: AXUIElement, depth: Int, inToolbar: Bool = false, inSelectedRow: Bool = false) {
            if nodes.contains(where: { CFEqual($0.node, node) }) { return }
            guard depth < 22, nodes.count < 1400, Date() < deadline else { complete = false; return }
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            let rect = frame(node)
            let selected = (role == kAXRowRole || role == "AXCell") && (attribute(node, kAXSelectedAttribute) as? Bool) == true
            let toolbar = inToolbar || role == kAXToolbarRole
            nodes.append(Node(node: node, role: role, rect: rect, toolbar: toolbar, selectedRow: inSelectedRow || selected))
            // Do not descend message lists/text bodies. Selected sidebar rows are inspected separately.
            if role == kAXTextAreaRole || (role == kAXRowRole && !selected && !inSelectedRow) { return }
            if role == kAXScrollAreaRole, let rect, rect.minX > bounds.minX + bounds.width * 0.34, rect.minY > bounds.minY + 110 { return }
            if [kAXTableRole as String, kAXOutlineRole as String, "AXList"].contains(role), let rect, rect.maxX < bounds.minX + bounds.width * 0.65 {
                let selection = (attribute(node, "AXSelectedRows") as? [AXUIElement]) ?? (attribute(node, kAXSelectedChildrenAttribute) as? [AXUIElement])
                if let selection {
                    for child in selection { walk(child, depth: depth + 1, inToolbar: toolbar, inSelectedRow: true) }
                    return
                }
            }
            for child in children(node) { walk(child, depth: depth + 1, inToolbar: toolbar, inSelectedRow: inSelectedRow || selected) }
        }
        walk(window, depth: 0)
        // Supported WeChat builds expose semantic labels even when their header geometry changes.
        // Read only the conversation-name value, never editor or body text.
        for node in nodes where (attribute(node.node, kAXIdentifierAttribute) as? String) == "current_chat_name_label" {
            if let name = attribute(node.node, kAXValueAttribute) as? String, !name.isEmpty {
                evidence.append(ConversationEvidence(name, kind: .header))
            }
        }
        // Derive the conversation column from split panes or the bottom compose field, rather than a fixed sidebar width.
        let compose = nodes.filter { n in
            guard [kAXTextAreaRole as String, kAXTextFieldRole as String].contains(n.role), let r = n.rect else { return false }
            return r.minY > bounds.midY && r.width > bounds.width * 0.3
        }.compactMap(\.rect)
        let paneLeft = compose.map(\.minX).min() ?? nodes.filter { $0.role == kAXSplitGroupRole }.compactMap(\.rect).flatMap { _ in
            nodes.filter { $0.role == kAXGroupRole }.compactMap(\.rect).filter { $0.height > bounds.height * 0.65 && $0.minX > bounds.minX + bounds.width * 0.15 && $0.width > bounds.width * 0.35 }.map(\.minX)
        }.max() ?? (bounds.minX + bounds.width * 0.34)
        let selectedRows = nodes.filter { $0.selectedRow && [kAXRowRole as String, "AXCell", kAXGroupRole as String].contains($0.role) && ($0.rect?.maxX ?? .infinity) <= paneLeft + 20 }
        for row in selectedRows {
            
            // Only first/top label of the selected row, not last-message previews or other rows.
            let labels = nodes.filter { $0.selectedRow && $0.role == kAXStaticTextRole && ($0.rect?.intersects(row.rect ?? .zero) ?? false) }
                .sorted { ($0.rect?.minY ?? 0, $0.rect?.minX ?? 0) < ($1.rect?.minY ?? 0, $1.rect?.minX ?? 0) }
            if let label = labels.first {
                for key in [kAXTitleAttribute, kAXValueAttribute] { if let text = attribute(label.node, key) as? String, !text.isEmpty { evidence.append(ConversationEvidence(text, kind: .selectedRow)); break } }
            } else if let title = attribute(row.node, kAXTitleAttribute) as? String { evidence.append(ConversationEvidence(title, kind: .selectedRow)) }
        }
        // Header labels only. The body starts below this title band; no message values or editor values are read.
        for node in nodes where node.role == kAXStaticTextRole || node.role == kAXButtonRole {
            guard let r = node.rect, r.minX >= paneLeft - 12, r.maxY <= bounds.minY + 100, r.minY >= bounds.minY, r.height <= 48 else { continue }
            for key in [kAXTitleAttribute, kAXValueAttribute] {
                if let text = attribute(node.node, key) as? String { evidence.append(ConversationEvidence(text, kind: .header)) }
            }
        }
        let roles = Dictionary(nodes.map { ($0.role, 1) }, uniquingKeysWith: +)
        guard FocusedWeChatWindow.isCurrent(snapshot) else {
            return Detection(group: nil, state: "incomplete", visited: nodes.count, evidenceCount: evidence.count,
                             roleCounts: roles)
        }
        let result = TitleIdentity.resolve(evidence, candidates: candidates, complete: complete && !queryFailed)
        return Detection(group: result.id.flatMap { id in groups.first { $0.id == id } }, state: result.state.rawValue,
                         visited: nodes.count, evidenceCount: evidence.count, roleCounts: roles, focusedWindow: snapshot)
    }
}
