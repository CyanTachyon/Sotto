import Foundation
import CoreGraphics

/// Pure placement geometry in AppKit screen coordinates (positive y points up).
/// The full bubble stays inside its host and the selected screen's visible area.
public struct BubblePlacement {
    public static let margin: CGFloat = 4
    public static let topReserved: CGFloat = 44

    public let bubbleSize: CGSize
    /// Legal bottom-left origins. Either dimension may be zero for an exact fit.
    public let allowedOriginRect: CGRect
    public let defaultAnchor: CGPoint

    public init?(hostFrame: CGRect, screenVisibleFrame: CGRect,
                 bubbleSize: CGSize = CGSize(width: 48, height: 48)) {
        guard Self.valid(hostFrame), Self.valid(screenVisibleFrame),
              bubbleSize.width.isFinite, bubbleSize.height.isFinite,
              bubbleSize.width > 0, bubbleSize.height > 0 else { return nil }
        let hostContent = CGRect(x: hostFrame.minX + Self.margin,
                                 y: hostFrame.minY + Self.margin,
                                 width: hostFrame.width - 2 * Self.margin,
                                 height: hostFrame.height - Self.margin - Self.topReserved)
        let screenContent = screenVisibleFrame.insetBy(dx: Self.margin, dy: Self.margin)
        guard Self.valid(hostContent), Self.valid(screenContent) else { return nil }
        let content = hostContent.intersection(screenContent)
        guard Self.valid(content), content.width >= bubbleSize.width,
              content.height >= bubbleSize.height else { return nil }
        let origins = CGRect(x: content.minX, y: content.minY,
                             width: content.width - bubbleSize.width,
                             height: content.height - bubbleSize.height)
        self.bubbleSize = bubbleSize
        allowedOriginRect = origins
        // Preserve the former right-side position, 170 points below the visible
        // host top, whenever the new containment/title-bar limits permit it.
        let area = hostFrame.intersection(screenVisibleFrame)
        let oldOrigin = CGPoint(x: area.maxX - bubbleSize.width - Self.margin,
                                y: max(area.minY + 100, area.maxY - 170))
        defaultAnchor = Self.anchor(for: oldOrigin, in: origins)
    }

    /// Reapplies a saved relative position after the host moves or resizes.
    /// Finite out-of-range anchor components are clamped to 0...1.
    public func frame(anchor: CGPoint? = nil) -> CGRect? {
        let anchor = anchor ?? defaultAnchor
        guard Self.valid(anchor) else { return nil }
        let origin = CGPoint(x: allowedOriginRect.minX + Self.unit(anchor.x) * allowedOriginRect.width,
                             y: allowedOriginRect.minY + Self.unit(anchor.y) * allowedOriginRect.height)
        return CGRect(origin: origin, size: bubbleSize)
    }

    /// `dragOrigin` is the proposed bubble bottom-left origin in screen space,
    /// after the caller applies the pointer's displacement from drag start.
    public func clampedFrame(for dragOrigin: CGPoint) -> CGRect? {
        guard Self.valid(dragOrigin) else { return nil }
        return CGRect(origin: Self.clamp(dragOrigin, in: allowedOriginRect), size: bubbleSize)
    }

    /// Saves a clamped drag position relative to the currently legal movement
    /// range. An axis without movement uses the neutral anchor 0.5.
    public func normalizedAnchor(for dragOrigin: CGPoint) -> CGPoint? {
        guard Self.valid(dragOrigin) else { return nil }
        return Self.anchor(for: dragOrigin, in: allowedOriginRect)
    }

    private static func valid(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && valid(rect.origin) && rect.size.width.isFinite && rect.size.height.isFinite &&
            rect.size.width > 0 && rect.size.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
    }

    private static func unit(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    private static func clamp(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY))
    }

    private static func anchor(for point: CGPoint, in rect: CGRect) -> CGPoint {
        let point = clamp(point, in: rect)
        return CGPoint(x: rect.width > 0 ? unit((point.x - rect.minX) / rect.width) : 0.5,
                       y: rect.height > 0 ? unit((point.y - rect.minY) / rect.height) : 0.5)
    }
}
