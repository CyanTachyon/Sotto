import AppKit
import SwiftUI

/// Shared semantic colors. Dynamic AppKit colors follow each window's effective
/// appearance, including native controls and popovers hosted outside FloatView.
enum AppTheme {
    static let canvas = color("canvas", light: 0xF5F5F5, dark: 0x202020)
    static let toolbar = color("toolbar", light: 0xEDEDED, dark: 0x282828)
    static let surface = color("surface", light: 0xFFFFFF, dark: 0x2C2C2C)
    static let input = color("input", light: 0xFFFFFF, dark: 0x1E1E1E)
    static let hoverSurface = color("hoverSurface", light: 0xE9E9E9, dark: 0x383838)
    static let textPrimary = color("textPrimary", light: 0x202020, dark: 0xE9E9E9)
    static let textSecondary = color("textSecondary", light: 0x656565, dark: 0xB2B2B2)
    static let separator = color("separator", light: 0xDFDFDF, dark: 0x3E3E3E)
    static let border = color("border", light: 0xD2D2D2, dark: 0x4A4A4A)

    static let accent = color("accent", light: 0x078842, dark: 0x49CB7D)
    // macOS segmented controls use white selected text even in dark appearance.
    static let nativeSelectionAccent = color("nativeSelectionAccent", light: 0x078842, dark: 0x078842)
    static let accentSoft = color("accentSoft", light: 0xE6F4EA, dark: 0x243D2D)
    static let onAccent = color("onAccent", light: 0xFFFFFF, dark: 0x102719)
    static let questionBubble = color("questionBubble", light: 0x95EC69, dark: 0x2F583B)
    static let questionText = color("questionText", light: 0x1E3016, dark: 0xE9F5EB)

    static let codeBackground = color("codeBackground", light: 0xF0F1F2, dark: 0x232527)
    static let inlineCodeBackground = color("inlineCodeBackground", light: 0xE8EAEC, dark: 0x3A3D40)
    static let quoteBar = color("quoteBar", light: 0xB7B7B7, dark: 0x626262)
    static let link = color("link", light: 0x076F3B, dark: 0x72DFA0)
    static let success = color("success", light: 0x187947, dark: 0x6BD897)
    static let warning = color("warning", light: 0x976000, dark: 0xE3B35D)
    static let error = color("error", light: 0xB7352C, dark: 0xFF968D)
    static let errorBackground = color("errorBackground", light: 0xFDECE9, dark: 0x462B2B)

    private static func color(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("cn.local.ChatFloat.theme." + name)) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                           green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        })
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Creating a controller only reads its injected defaults. The production
/// singleton begins applying appearances when AppDelegate calls start().
@MainActor final class AppAppearanceController: ObservableObject {
    static let shared = AppAppearanceController()
    static let defaultsKey = "appAppearanceV1"
    @Published var mode: AppAppearanceMode {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.defaultsKey)
            if started { apply() }
        }
    }
    private let defaults: UserDefaults
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = AppAppearanceMode(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .system
    }

    func start() {
        started = true
        apply()
    }

    private func apply() {
        guard let app = NSApp else { return }
        app.appearance = mode.appKitAppearance
        for window in app.windows {
            // Nil inherits the application setting and continues to track the
            // system when that setting is nil. New windows inherit automatically.
            window.appearance = nil
            window.contentView?.needsDisplay = true
        }
    }
}
