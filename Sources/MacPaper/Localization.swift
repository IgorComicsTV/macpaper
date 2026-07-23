import Foundation
import MacPaperCore

enum L10n {
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: .main, value: key, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    static func title(for value: PlaylistOrder) -> String {
        text("playlist.\(value.rawValue)")
    }

    static func title(for value: WallpaperLayoutMode) -> String {
        text("layout.\(value.rawValue)")
    }

    static func title(for value: VideoContentMode) -> String {
        text("content.\(value.rawValue)")
    }

    static func title(for value: ForegroundBehavior) -> String {
        text("foreground.\(value.rawValue)")
    }

    static func timer(_ seconds: TimeInterval) -> String {
        switch Int(seconds) {
        case 900: return text("timer.15_minutes")
        case 1_800: return text("timer.30_minutes")
        case 3_600: return text("timer.1_hour")
        case 7_200: return text("timer.2_hours")
        case 21_600: return text("timer.6_hours")
        case 43_200: return text("timer.12_hours")
        case 86_400: return text("timer.24_hours")
        default:
            if seconds < 3_600 { return text("timer.minutes", Int(seconds / 60)) }
            return text("timer.hours", seconds / 3_600)
        }
    }
}
