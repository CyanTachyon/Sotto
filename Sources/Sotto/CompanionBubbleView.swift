import AppKit
import SwiftUI

private struct BubbleArtwork: View {
    var body: some View {
        Image(systemName: "bubble.left.and.text.bubble.right.fill")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(AppTheme.onAccent).frame(width: 38, height: 38)
            .background(AppTheme.accent, in: Circle())
            .overlay(Circle().stroke(AppTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .frame(width: 48, height: 48).accessibilityHidden(true)
    }
}

/// AppKit keeps the original mouse recipient while its window moves. One input
/// owner avoids a SwiftUI button firing when the user releases a drag.
@MainActor final class CompanionBubbleView: NSView {
    private let begin: (CGPoint) -> Bool
    private let drag: (CGPoint) -> Bool
    private let end: (CGPoint, Bool) -> Void
    private let cancel: () -> Void
    private let open: () -> Bool
    private var pressOrigin: CGPoint?
    private var dragging = false
    private var cursorPushed = false
    private var tracking: NSTrackingArea?
    private static let dragDistance: CGFloat = 6

    init(begin: @escaping (CGPoint) -> Bool, drag: @escaping (CGPoint) -> Bool,
         end: @escaping (CGPoint, Bool) -> Void, cancel: @escaping () -> Void,
         open: @escaping () -> Bool) {
        self.begin = begin; self.drag = drag; self.end = end; self.cancel = cancel; self.open = open
        super.init(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
        let artwork = NSHostingView(rootView: BubbleArtwork())
        artwork.frame = bounds; artwork.autoresizingMask = [.width, .height]
        addSubview(artwork)
        alphaValue = 0.82
        toolTip = "单击打开伴读面板，拖动调整气泡位置"
        setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("打开 Sotto")
        setAccessibilityHelp("单击打开伴读面板，拖动调整气泡位置")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseEntered(with event: NSEvent) { alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { if !dragging { alphaValue = 0.82 } }
    private func screenPoint(_ event: NSEvent) -> CGPoint? {
        guard let window else { return nil }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
    private func exceedsThreshold(_ point: CGPoint, from origin: CGPoint) -> Bool {
        hypot(point.x - origin.x, point.y - origin.y) >= Self.dragDistance
    }
    override func mouseDown(with event: NSEvent) {
        cancelInteraction()
        guard let point = screenPoint(event), begin(point) else { return }
        pressOrigin = point
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin, let point = screenPoint(event) else { return }
        guard dragging || exceedsThreshold(point, from: origin) else { return }
        if !dragging {
            dragging = true; alphaValue = 1
            NSCursor.closedHand.push(); cursorPushed = true
        }
        if !drag(point) { cancelInteraction() }
    }
    override func mouseUp(with event: NSEvent) {
        guard let origin = pressOrigin, let point = screenPoint(event) else { cancelInteraction(); cancel(); return }
        let moved = dragging || exceedsThreshold(point, from: origin)
        cancelInteraction()
        // The controller checks fresh window evidence before applying a final
        // displacement, including a fast release without intermediate events.
        end(point, moved)
    }
    override func mouseCancelled(with event: NSEvent) {
        cancelInteraction()
        cancel()
    }
    func cancelInteraction() {
        pressOrigin = nil; dragging = false
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        alphaValue = 0.82
    }
    override func accessibilityPerformPress() -> Bool { open() }
}
