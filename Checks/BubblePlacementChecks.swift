import Foundation
import CoreGraphics
import SottoCore

func checkBubblePlacement() throws {
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ChatError.invalid("Bubble placement: \(message)") }
    }
    func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw ChatError.invalid("Bubble placement: \(message)") }
        return value
    }
    func near(_ left: CGFloat, _ right: CGFloat) -> Bool { abs(left - right) < 0.000_001 }
    func same(_ left: CGPoint, _ right: CGPoint) -> Bool { near(left.x, right.x) && near(left.y, right.y) }
    func contained(_ frame: CGRect, host: CGRect, screen: CGRect) -> Bool {
        frame.width == 48 && frame.height == 48 &&
            frame.minX >= host.minX + 4 && frame.maxX <= host.maxX - 4 &&
            frame.minY >= host.minY + 4 && frame.maxY <= host.maxY - 44 &&
            frame.minX >= screen.minX + 4 && frame.maxX <= screen.maxX - 4 &&
            frame.minY >= screen.minY + 4 && frame.maxY <= screen.maxY - 4
    }
    let host = CGRect(x: 100, y: 100, width: 800, height: 600)
    let screen = CGRect(x: 0, y: 24, width: 1440, height: 850)
    let placement = try unwrap(BubblePlacement(hostFrame: host, screenVisibleFrame: screen), "ordinary host rejected")
    let initial = try unwrap(placement.frame(), "default frame missing")
    try expect(initial.origin == CGPoint(x: 848, y: 530), "default must preserve former position")
    try expect(placement.defaultAnchor.x == 1, "default must stay at right side")

    // Each edge and all corners must clamp the complete bubble, not its center.
    let origins = placement.allowedOriginRect
    let points = [CGPoint(x: -10_000, y: 400), CGPoint(x: 10_000, y: 400),
                  CGPoint(x: 400, y: -10_000), CGPoint(x: 400, y: 10_000),
                  CGPoint(x: -10_000, y: -10_000), CGPoint(x: -10_000, y: 10_000),
                  CGPoint(x: 10_000, y: -10_000), CGPoint(x: 10_000, y: 10_000)]
    for proposed in points {
        let frame = try unwrap(placement.clampedFrame(for: proposed), "finite drag rejected")
        try expect(contained(frame, host: host, screen: screen), "drag escaped host, title bar or visible screen")
        let anchor = try unwrap(placement.normalizedAnchor(for: proposed), "drag anchor missing")
        try expect((0...1).contains(anchor.x) && (0...1).contains(anchor.y), "anchor outside unit range")
        let restored = try unwrap(placement.frame(anchor: anchor), "saved anchor rejected")
        try expect(same(restored.origin, frame.origin), "drag-to-anchor round trip changed position")
    }
    try expect(placement.clampedFrame(for: CGPoint(x: -10_000, y: 400))?.minX == origins.minX, "left edge wrong")
    try expect(placement.clampedFrame(for: CGPoint(x: 10_000, y: 400))?.minX == origins.maxX, "right edge wrong")
    try expect(placement.clampedFrame(for: CGPoint(x: 400, y: -10_000))?.minY == origins.minY, "bottom edge wrong")
    try expect(placement.clampedFrame(for: CGPoint(x: 400, y: 10_000))?.minY == origins.maxY, "top edge wrong")

    let anchor = CGPoint(x: 0.25, y: 0.75)
    let original = try unwrap(placement.frame(anchor: anchor), "relative frame missing")
    let moved = try unwrap(BubblePlacement(hostFrame: host.offsetBy(dx: 150, dy: 75), screenVisibleFrame: screen), "moved host rejected")
    let movedFrame = try unwrap(moved.frame(anchor: anchor), "moved anchor rejected")
    try expect(same(movedFrame.origin, original.origin.applying(CGAffineTransform(translationX: 150, y: 75))), "host translation lost relative position")
    let resized = try unwrap(BubblePlacement(hostFrame: CGRect(x: 100, y: 100, width: 1100, height: 700), screenVisibleFrame: screen), "resized host rejected")
    let resizedFrame = try unwrap(resized.frame(anchor: anchor), "resized anchor rejected")
    let resizedAnchor = try unwrap(resized.normalizedAnchor(for: resizedFrame.origin), "resized round trip missing")
    try expect(same(resizedAnchor, anchor), "resize lost normalized anchor")

    // Windows can straddle an edge, with their title bar entirely offscreen.
    // Negative desktop coordinates also represent screens left/below the primary.
    let screens = [screen, CGRect(x: -1600, y: -900, width: 1600, height: 900)]
    let hosts = [[CGRect(x: -300, y: 100, width: 800, height: 600),
                  CGRect(x: 1200, y: 100, width: 800, height: 600),
                  CGRect(x: 100, y: -300, width: 800, height: 600),
                  CGRect(x: 100, y: 700, width: 800, height: 600)],
                 [CGRect(x: -1700, y: -1000, width: 800, height: 600),
                  CGRect(x: -900, y: -500, width: 1000, height: 700)]]
    for (index, display) in screens.enumerated() {
        for window in hosts[index] {
            let geometry = try unwrap(BubblePlacement(hostFrame: window, screenVisibleFrame: display), "partly visible host rejected")
            for relative in [CGPoint.zero, CGPoint(x: 1, y: 1), anchor] {
                let frame = try unwrap(geometry.frame(anchor: relative), "multiscreen anchor missing")
                try expect(contained(frame, host: window, screen: display), "partial/negative-screen bubble escaped")
            }
        }
    }

    let exact = try unwrap(BubblePlacement(hostFrame: CGRect(x: 100, y: 100, width: 56, height: 96), screenVisibleFrame: screen), "exact 48-point fit rejected")
    try expect(exact.allowedOriginRect.size == .zero, "exact fit must have no travel")
    try expect(exact.normalizedAnchor(for: .zero) == CGPoint(x: 0.5, y: 0.5), "exact fit must use neutral anchor")
    try expect(exact.frame(anchor: CGPoint(x: 1, y: 0))?.origin == CGPoint(x: 104, y: 104), "exact fit placement wrong")
    try expect(placement.frame(anchor: CGPoint(x: -4, y: 7))?.origin == CGPoint(x: origins.minX, y: origins.maxY), "finite anchors must clamp")

    let invalidHosts = [CGRect.zero, CGRect.null, CGRect.infinite,
                        CGRect(x: 0, y: 0, width: -800, height: 600),
                        CGRect(x: 0, y: 0, width: 55.99, height: 600),
                        CGRect(x: 0, y: 0, width: 800, height: 95.99),
                        CGRect(x: 0, y: 0, width: 48, height: 48),
                        CGRect(x: 2000, y: 100, width: 800, height: 600),
                        CGRect(x: 1400, y: 100, width: 800, height: 600),
                        CGRect(x: CGFloat.nan, y: 100, width: 800, height: 600)]
    for window in invalidHosts {
        try expect(BubblePlacement(hostFrame: window, screenVisibleFrame: screen) == nil, "invalid/insufficient host accepted")
    }
    for display in [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: 0, y: 0, width: 48, height: 48)] {
        try expect(BubblePlacement(hostFrame: host, screenVisibleFrame: display) == nil, "invalid/insufficient screen accepted")
    }
    for size in [CGSize.zero, CGSize(width: -48, height: 48), CGSize(width: CGFloat.infinity, height: 48), CGSize(width: 48, height: CGFloat.nan)] {
        try expect(BubblePlacement(hostFrame: host, screenVisibleFrame: screen, bubbleSize: size) == nil, "invalid bubble size accepted")
    }
    for point in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0, y: CGFloat.infinity)] {
        try expect(placement.frame(anchor: point) == nil, "invalid anchor accepted")
        try expect(placement.clampedFrame(for: point) == nil, "invalid drag accepted")
        try expect(placement.normalizedAnchor(for: point) == nil, "invalid drag normalized")
    }
}
