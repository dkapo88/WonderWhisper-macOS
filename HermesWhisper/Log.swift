import Foundation
import OSLog

enum AppLog {
    static let dictation = Logger(subsystem: AppConfig.bundleIdentifier, category: "Dictation")
    static let network = Logger(subsystem: AppConfig.bundleIdentifier, category: "Network")
    static let insertion = Logger(subsystem: AppConfig.bundleIdentifier, category: "Insertion")
    static let screen = Logger(subsystem: AppConfig.bundleIdentifier, category: "ScreenCapture")
    static let hotkeys = Logger(subsystem: AppConfig.bundleIdentifier, category: "Hotkeys")
}
