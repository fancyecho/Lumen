import Foundation

/// Why a display's wallpaper is not animating right now.
enum PauseReason: Equatable {
    case user
    case systemSleep
    case displayAsleep
    case locked
    case screenSaver
    case sessionInactive
    case lowPower
    case battery
    case thermal
    case covered

    var title: String {
        switch self {
        case .user: String(localized: "Paused")
        case .systemSleep: String(localized: "Mac is asleep")
        case .displayAsleep: String(localized: "Display is asleep")
        case .locked: String(localized: "Screen locked")
        case .screenSaver: String(localized: "Screen saver running")
        case .sessionInactive: String(localized: "Another user is active")
        case .lowPower: String(localized: "Low Power Mode")
        case .battery: String(localized: "On battery")
        case .thermal: String(localized: "Cooling down")
        case .covered: String(localized: "Covered by windows")
        }
    }

    var symbol: String {
        switch self {
        case .user: "pause.fill"
        case .systemSleep, .displayAsleep: "moon.fill"
        case .locked: "lock.fill"
        case .screenSaver: "sparkles"
        case .sessionInactive: "person.2.fill"
        case .lowPower: "leaf.fill"
        case .battery: "battery.50percent"
        case .thermal: "thermometer.medium"
        case .covered: "macwindow"
        }
    }

    /// Pauses that exist purely to save energy (shown with a leaf accent in the UI).
    var savesEnergy: Bool {
        switch self {
        case .lowPower, .battery, .thermal, .covered: true
        default: false
        }
    }
}
