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
        case .user: "Paused"
        case .systemSleep: "Mac is asleep"
        case .displayAsleep: "Display is asleep"
        case .locked: "Screen locked"
        case .screenSaver: "Screen saver running"
        case .sessionInactive: "Another user is active"
        case .lowPower: "Low Power Mode"
        case .battery: "On battery"
        case .thermal: "Cooling down"
        case .covered: "Covered by windows"
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
