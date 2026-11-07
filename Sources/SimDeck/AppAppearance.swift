import SimDeckCore
import AppKit

/// 应用主题：默认跟随系统，可强制浅色/暗色。作用于 App 的所有窗口（面板/主界面/设置）。
enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = "appearance"

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil // nil = 跟随系统
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    var title: String {
        switch self {
        case .system: return AppLanguage.text("appearance.system")
        case .light: return AppLanguage.text("appearance.light")
        case .dark: return AppLanguage.text("appearance.dark")
        }
    }

    static func current() -> AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    static func apply(rawValue: String) {
        let appearance = AppAppearance(rawValue: rawValue) ?? .system
        NSApp.appearance = appearance.nsAppearance
    }

    static func applyCurrent() {
        apply(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
    }
}
