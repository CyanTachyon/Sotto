import AppKit
import SwiftUI
private typealias ViewState<Value> = SwiftUI.State<Value>
import Combine
import SottoCore
import QuartzCore

private final class CompanionPanel: NSPanel {
    var collapse: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { collapse?() }
}

private struct CompanionBubble: View {
    let open: () -> Void
    @ViewState private var hovered = false
    var body: some View {
        Button(action: open) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill").font(.system(size: 19, weight: .medium))
                .foregroundStyle(AppTheme.onAccent).frame(width: 38, height: 38)
                .background(AppTheme.accent, in: Circle())
                .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .opacity(hovered ? 1 : 0.82)
        }.buttonStyle(.plain).help("打开当前微信会话的伴读面板")
            .accessibilityLabel("打开 Sotto")
            .onHover { hovered = $0 }.frame(width: 48, height: 48)
    }
}

/// A transient companion belongs to the visible WeChat context, never to every foreground app.
@MainActor final class CompanionController: NSObject, NSWindowDelegate {
    let model: AppModel
    let panel: NSPanel
    let bubble: NSPanel
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var lastTarget: WeChatWindow?
    private var candidate: WeChatWindow?
    private var candidateSince: TimeInterval = 0
    private var spaceSettlesAt: TimeInterval = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var focusObservers: [NSObjectProtocol] = []
    private let targetProvider: @MainActor () -> WeChatWindow?
    private let relevantForeground: () -> Bool
    private let now: () -> TimeInterval
    private let observeFocus: Bool
    private let reducedMotion: () -> Bool
    private let blurDelay: TimeInterval
    private let focusIsWithinCompanion: () -> Bool
    private var hostedSurface: NSView?
    private var animationTask: Task<Void, Never>?
    private var animationGeneration: UInt = 0
    private var surfaceScale: CGFloat = 1
    private var blurTask: Task<Void, Never>?
    private var blurGeneration: UInt = 0
    private var blurArmed = false
    private var conversationPickerPresented = false
    private var trackingMenus = Set<ObjectIdentifier>()
    private var activePopovers = Set<ObjectIdentifier>()
    private enum Presentation { case hidden, bubble, panel }
    private var presentation: Presentation = .hidden
    private struct TargetIdentity: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        init(_ target: WeChatWindow) { pid = target.pid; windowID = target.id }
    }
    // Keep the anchor while focus is temporarily unavailable or auxiliary UI hides
    // the panel. A restored Boolean must not expand a different native window.
    private var expandedTarget: TargetIdentity?
    private var auxiliaryFocusRestoreTarget: TargetIdentity?
    private weak var fixtureWindow: NSWindow?
    init(model: AppModel, fixtureWindow: NSWindow? = nil,
         targetProvider: (@MainActor () -> WeChatWindow?)? = nil,
         relevantForeground: @escaping () -> Bool = { WeChatWindow.isRelevantForeground },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         observeWorkspace: Bool = true,
         observeFocus: Bool = true,
         reducedMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         blurDelay: TimeInterval = 0.18,
         focusIsWithinCompanion: @escaping () -> Bool = { false }) {
        self.model = model
        self.fixtureWindow = fixtureWindow
        let chatProvider = WeChatWindowProvider()
        self.targetProvider = targetProvider ?? { [weak model] in
            guard let model else { return nil }
            let candidates = model.groups.map { TitleCandidate(id: $0.id, aliases: [$0.name] + $0.aliases) }
            return chatProvider.current { snapshot in
                WeChatWindowEligibility.classify(title: snapshot.title, metadata: snapshot.metadata,
                                                 candidates: candidates) != .unsupported
            }
        }
        self.relevantForeground = relevantForeground; self.now = now
        self.observeFocus = observeFocus; self.reducedMotion = reducedMotion
        self.blurDelay = max(0.01, blurDelay); self.focusIsWithinCompanion = focusIsWithinCompanion
        panel = CompanionPanel(contentRect: .init(x: 0, y: 0, width: 420, height: 640), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble = NSPanel(contentRect: .init(x: 0, y: 0, width: 48, height: 48), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        for window in [panel, bubble] {
            window.level = .floating
            // One instance in the current Space: all-Spaces windows are duplicated by the
            // system during desktop swipes and visibly flash over unrelated desktops.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications, .transient]
            window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = false
            window.animationBehavior = .none
        }
        panel.title = "Sotto"
        panel.minSize = NSSize(width: 360, height: 460); panel.delegate = self
        let wrapper = NSView(frame: CGRect(origin: .zero, size: panel.contentLayoutRect.size))
        wrapper.wantsLayer = true
        let hosting = NSHostingView(rootView: FloatView(model: model, onConversationPickerChange: { [weak self] visible in
            self?.conversationPickerPresented = visible
            if !visible { self?.scheduleBlurCheck() }
        }))
        hosting.frame = wrapper.bounds; hosting.autoresizingMask = [.width, .height]
        wrapper.addSubview(hosting); hostedSurface = wrapper
        panel.contentView = wrapper
        panel.isOpaque = false; panel.backgroundColor = .clear
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 14; hosting.layer?.masksToBounds = true
        (panel as? CompanionPanel)?.collapse = { [weak self] in self?.model.companionExpanded = false }
        bubble.isOpaque = false; bubble.backgroundColor = .clear; bubble.hasShadow = false
        bubble.contentView = NSHostingView(rootView: CompanionBubble { [weak self] in _ = self?.present() })
        model.$companionExpanded.removeDuplicates().dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }.store(in: &subscriptions)
        model.$companionEnabled.removeDuplicates().dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }.store(in: &subscriptions)
        if observeFocus { observeTransientInteractions() }
        if observeWorkspace {
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activeSpaceDidChange() }
            })
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.update() }
                })
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.update() } }
        }
        update()
    }
    deinit {
        timer?.invalidate()
        animationTask?.cancel(); blurTask?.cancel()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
    }
    @discardableResult func present() -> Bool {
        guard model.companionEnabled, relevantForeground(), now() >= spaceSettlesAt, let target = targetProvider() else { return false }
        collapseForDifferentTarget(target)
        guard position(target) else { return false }
        if fixtureWindow?.isVisible == true { fixtureWindow?.orderOut(nil) }
        candidate = target; candidateSince = now() - 1
        expandedTarget = TargetIdentity(target)
        auxiliaryFocusRestoreTarget = nil
        cancelBlurCheck(disarm: true)
        model.companionExpanded = true
        model.resumeAutomaticConnection()
        display(.panel, takeFocus: true)
        if observeFocus, panel.isKeyWindow { blurArmed = true }
        if model.autoFollow { model.followState = "checking"; model.identity = "正在确认微信当前会话…" }
        model.pollIdentity()
        return true
    }
    func hide() {
        auxiliaryFocusRestoreTarget = nil
        hideSurface()
    }
    private func hideSurface() {
        cancelBlurCheck(disarm: true)
        trackingMenus.removeAll(); activePopovers.removeAll()
        display(.hidden)
    }
    /// Only the user closing an auxiliary window requests one return of keyboard
    /// focus. Ordinary Space/visibility recovery must never take key automatically.
    func resumeAfterAuxiliary() {
        if model.companionExpanded, !model.showSettings, !model.showConnection,
           !model.showSources, let expandedTarget {
            auxiliaryFocusRestoreTarget = expandedTarget
        }
        update()
    }
    func activeSpaceDidChange() {
        // Wait for WindowServer's visible-window list to settle before placing the
        // companion. Keep the user's expansion choice and all conversation state.
        spaceSettlesAt = now() + 0.45
        candidate = nil
        hide()
    }
    func update() {
        guard model.companionEnabled, !model.showSettings, !model.showConnection, !model.showSources else {
            candidate = nil; hide(); return
        }
        // Let the resolver revoke retained focus when an unrelated app becomes
        // frontmost; the production provider does not query AX in that context.
        let observedTarget = targetProvider()
        guard relevantForeground(), let target = observedTarget else {
            // Workspace activation can precede didResignKey. Consume that genuine
            // departure before programmatic hide invalidates its delayed callback.
            if observeFocus, model.companionExpanded,
               (!relevantForeground() || (blurArmed && !panel.isKeyWindow && !hasTransientInteraction)) {
                model.companionExpanded = false
            }
            candidate = nil; hide(); return
        }
        // Hide the old panel before position() can move it. Geometry changes on
        // the same native window do not change the user's expansion choice.
        collapseForDifferentTarget(target)
        let instant = now()
        if candidate?.id != target.id || candidate?.pid != target.pid || (presentation == .hidden && candidate?.bounds != target.bounds) {
            candidate = target; candidateSince = instant
        }
        guard instant >= spaceSettlesAt, instant - candidateSince >= 0.20,
              position(target) else { hideSurface(); return }
        if fixtureWindow?.isVisible == true { fixtureWindow?.orderOut(nil) }
        let restoreKey = model.companionExpanded && auxiliaryFocusRestoreTarget == TargetIdentity(target) &&
            expandedTarget == TargetIdentity(target)
        display(model.companionExpanded ? .panel : .bubble, takeFocus: restoreKey)
        if restoreKey {
            auxiliaryFocusRestoreTarget = nil
            if observeFocus, panel.isKeyWindow { blurArmed = true }
        }
    }
    private func collapseForDifferentTarget(_ target: WeChatWindow) {
        guard expandedTarget != TargetIdentity(target) else { return }
        if model.companionExpanded || panel.isVisible {
            hide()
            model.companionExpanded = false
        }
        expandedTarget = nil
    }
    private func display(_ desired: Presentation, takeFocus: Bool = false) {
        // Polling cannot restart a transition. Hidden/target/Space changes cancel
        // immediately; no completion ever orders a window back onto the screen.
        if desired == presentation {
            if desired == .panel, takeFocus { panel.makeKeyAndOrderFront(nil) }
            return
        }
        let previous = presentation
        animationGeneration &+= 1; animationTask?.cancel(); animationTask = nil
        let startAlpha = panel.isVisible ? panel.alphaValue : 0
        let startScale = panel.isVisible ? surfaceScale : 0.96
        presentation = desired
        if desired == .hidden {
            panel.orderOut(nil); bubble.orderOut(nil)
            setSurface(alpha: 1, scale: 1); panel.ignoresMouseEvents = false
        } else if desired == .panel {
            panel.ignoresMouseEvents = false
            let animated = takeFocus && !reducedMotion()
            setSurface(alpha: animated ? startAlpha : 1, scale: animated ? startScale : 1)
            if takeFocus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFront(nil) }
            bubble.orderOut(nil)
            if animated { animateSurface(alpha: 1, scale: 1, hidingAtEnd: false) }
        } else {
            bubble.orderFront(nil)
            if previous == .panel, panel.isVisible, !reducedMotion() {
                panel.ignoresMouseEvents = true
                animateSurface(alpha: 0, scale: 0.96, hidingAtEnd: true)
            } else {
                panel.orderOut(nil); setSurface(alpha: 1, scale: 1); panel.ignoresMouseEvents = false
            }
        }
    }
    private func setSurface(alpha: CGFloat, scale: CGFloat) {
        panel.alphaValue = alpha; surfaceScale = scale
        guard let surface = hostedSurface, let layer = surface.layer else { return }
        // Transform the wrapper's sublayers, never AppKit's managed hosting layer
        // geometry or the window/SwiftUI layout. The wrapper is a fixed anchor.
        // Anchor near the bubble side, clamped inside the content bounds.
        let point = surface.convert(panel.convertPoint(fromScreen: CGPoint(x: bubble.frame.midX, y: bubble.frame.midY)), from: nil)
        let x = min(surface.bounds.maxX, max(surface.bounds.minX, point.x)) - surface.bounds.midX
        let y = min(surface.bounds.maxY, max(surface.bounds.minY, point.y)) - surface.bounds.midY
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.sublayerTransform = CATransform3DMakeAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                                                                    tx: x * (1 - scale), ty: y * (1 - scale)))
        CATransaction.commit()
    }
    private func animateSurface(alpha: CGFloat, scale: CGFloat, hidingAtEnd: Bool) {
        let generation = animationGeneration
        let fromAlpha = panel.alphaValue, fromScale = surfaceScale
        let started = ProcessInfo.processInfo.systemUptime
        animationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.animationGeneration == generation else { return }
                let fraction = self.reducedMotion() ? 1 : min(1, (ProcessInfo.processInfo.systemUptime - started) / 0.18)
                let eased = CGFloat(1 - pow(1 - fraction, 3))
                self.setSurface(alpha: fromAlpha + (alpha - fromAlpha) * eased,
                                scale: fromScale + (scale - fromScale) * eased)
                if fraction >= 1 {
                    if hidingAtEnd { self.panel.orderOut(nil); self.setSurface(alpha: 1, scale: 1) }
                    self.panel.ignoresMouseEvents = false; self.animationTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private var hasTransientInteraction: Bool {
        if model.showSettings || model.showConnection || model.showSources ||
            conversationPickerPresented || focusIsWithinCompanion() || !trackingMenus.isEmpty || !activePopovers.isEmpty ||
            NSApp.modalWindow != nil || panel.attachedSheet != nil { return true }
        if panel.childWindows?.contains(where: { $0.isVisible }) == true { return true }
        var related = NSApp.keyWindow?.parent
        while let window = related {
            if window === panel { return true }
            related = window.parent
        }
        return false
    }
    private func cancelBlurCheck(disarm: Bool = false) {
        blurGeneration &+= 1; blurTask?.cancel(); blurTask = nil
        if disarm { blurArmed = false }
    }
    private func scheduleBlurCheck() {
        guard observeFocus, blurArmed, model.companionExpanded, presentation == .panel,
              panel.isVisible, !panel.isKeyWindow else { return }
        cancelBlurCheck()
        let generation = blurGeneration
        blurTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.blurDelay else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.blurGeneration == generation,
                      self.blurArmed, self.model.companionExpanded, self.presentation == .panel,
                      self.panel.isVisible, !self.panel.isKeyWindow else { return }
                if self.hasTransientInteraction { continue }
                self.blurTask = nil; self.blurArmed = false
                self.model.companionExpanded = false
                self.update()
                return
            }
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard observeFocus, notification.object as? NSWindow === panel, presentation == .panel else { return }
        cancelBlurCheck(); blurArmed = true
    }
    func windowDidResignKey(_ notification: Notification) {
        guard observeFocus, notification.object as? NSWindow === panel else { return }
        scheduleBlurCheck()
    }
    private func observeTransientInteractions() {
        let center = NotificationCenter.default
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let menu = note.object as? NSMenu else { return }
                    let key = ObjectIdentifier(menu)
                    if name == NSMenu.didBeginTrackingNotification {
                        if self.presentation == .panel && (self.panel.isKeyWindow || self.blurArmed) { self.trackingMenus.insert(key) }
                    } else { self.trackingMenus.remove(key); self.scheduleBlurCheck() }
                }
            })
        }
        for name in [NSPopover.willShowNotification, NSPopover.didCloseNotification] {
            focusObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let popover = note.object as? NSPopover else { return }
                    let key = ObjectIdentifier(popover)
                    if name == NSPopover.willShowNotification {
                        if self.presentation == .panel && (self.panel.isKeyWindow || self.blurArmed) { self.activePopovers.insert(key) }
                    } else { self.activePopovers.remove(key); self.scheduleBlurCheck() }
                }
            })
        }
    }
    @discardableResult private func position(_ target: WeChatWindow) -> Bool {
        let rect = target.appKitFrame
        let screen = NSScreen.screens.max { a, b in a.frame.intersection(rect).width * a.frame.intersection(rect).height < b.frame.intersection(rect).width * b.frame.intersection(rect).height }
        let visible = screen?.visibleFrame ?? rect
        let area = rect.intersection(visible)
        guard !area.isNull, area.width >= 380, area.height >= 300 else { return false }
        if target != lastTarget {
            bubble.setFrameOrigin(.init(x: area.maxX - 52, y: max(area.minY + 100, area.maxY - 170)))
            let width = min(max(panel.frame.width, 360), min(480, area.width - 16))
            let height = min(max(panel.frame.height, 460), max(area.height - 28, min(460, visible.height - 28)))
            panel.setFrame(.init(x: area.maxX - width - 10, y: max(visible.minY + 10, area.maxY - height - 14), width: width, height: height), display: true)
            lastTarget = target
        }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.companionExpanded = false; return false }
}
