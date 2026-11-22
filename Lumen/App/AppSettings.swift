import Foundation
import Observation

enum VideoScaling: String, CaseIterable, Identifiable {
    case fill, fit, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: String(localized: "Fill screen")
        case .fit: String(localized: "Fit inside")
        case .stretch: String(localized: "Stretch")
        }
    }
}

enum ShaderQuality: String, CaseIterable, Identifiable {
    case efficient, balanced, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .efficient: String(localized: "Efficient")
        case .balanced: String(localized: "Balanced")
        case .full: String(localized: "Native")
        }
    }
    var detail: String {
        switch self {
        case .efficient: String(localized: "Renders about 1 MP and upscales. Lowest GPU use.")
        case .balanced: String(localized: "Renders about 2 MP. Indistinguishable for smooth scenes.")
        case .full: String(localized: "Renders every pixel of the display. Highest GPU use.")
        }
    }
    var pixelBudget: Double {
        switch self {
        case .efficient: 1_000_000
        case .balanced: 2_100_000
        case .full: .infinity
        }
    }
}

enum DockIconMode: String, CaseIterable, Identifiable {
    case whileWindowOpen, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whileWindowOpen: String(localized: "Only while the window is open")
        case .always: String(localized: "Always")
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    enum Change {
        case policy, playback, scaling, shader, stillFrame, lockScreen
    }

    @ObservationIgnored private var observers: [(Change) -> Void] = []
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Registers a listener for setting changes (the engine, the lock-screen manager).
    func observe(_ handler: @escaping (Change) -> Void) {
        observers.append(handler)
    }

    var pauseWhenCovered: Bool { didSet { store(pauseWhenCovered, "pauseWhenCovered", .policy) } }
    /// Share of the desktop (0.5...1) that must be covered before "pause when covered" kicks in.
    var coverageThreshold: Double { didSet { store(coverageThreshold, "coverageThreshold", .policy) } }
    var pauseOnBattery: Bool { didSet { store(pauseOnBattery, "pauseOnBattery", .policy) } }
    var pauseOnLowPower: Bool { didSet { store(pauseOnLowPower, "pauseOnLowPower", .policy) } }
    var pauseOnThermalPressure: Bool { didSet { store(pauseOnThermalPressure, "pauseOnThermalPressure", .policy) } }

    var playbackRate: Double { didSet { store(playbackRate, "playbackRate", .playback) } }
    var audioEnabled: Bool { didSet { store(audioEnabled, "audioEnabled", .playback) } }
    var volume: Double { didSet { store(volume, "volume", .playback) } }
    var videoScaling: VideoScaling { didSet { store(videoScaling.rawValue, "videoScaling", .scaling) } }
    var crossfade: Bool { didSet { store(crossfade, "crossfade", nil) } }

    var shaderFrameRate: Int { didSet { store(shaderFrameRate, "shaderFrameRate", .shader) } }
    var shaderQuality: ShaderQuality { didSet { store(shaderQuality.rawValue, "shaderQuality", .shader) } }

    var syncStillFrame: Bool { didSet { store(syncStillFrame, "syncStillFrame", .stillFrame) } }
    var dockIconMode: DockIconMode { didSet { store(dockIconMode.rawValue, "dockIconMode", nil) } }

    var lockScreenEnabled: Bool { didSet { store(lockScreenEnabled, "lockScreenEnabled", .lockScreen) } }
    /// `nil` follows the main display's wallpaper; otherwise a specific wallpaper.
    var lockScreenWallpaperID: UUID? {
        didSet { store(lockScreenWallpaperID?.uuidString ?? "", "lockScreenWallpaperID", .lockScreen) }
    }

    var shaderRenderSettings: ShaderRenderSettings {
        ShaderRenderSettings(frameRate: shaderFrameRate, pixelBudget: shaderQuality.pixelBudget)
    }

    init() {
        defaults.register(defaults: [
            "pauseWhenCovered": true,
            "coverageThreshold": 0.95,
            "lockScreenEnabled": false,
            "lockScreenWallpaperID": "",
            "pauseOnBattery": false,
            "pauseOnLowPower": true,
            "pauseOnThermalPressure": true,
            "playbackRate": 1.0,
            "audioEnabled": false,
            "volume": 0.6,
            "videoScaling": VideoScaling.fill.rawValue,
            "crossfade": true,
            "shaderFrameRate": 30,
            "shaderQuality": ShaderQuality.balanced.rawValue,
            "syncStillFrame": true,
            "dockIconMode": DockIconMode.whileWindowOpen.rawValue,
        ])
        pauseWhenCovered = defaults.bool(forKey: "pauseWhenCovered")
        coverageThreshold = min(max(defaults.double(forKey: "coverageThreshold"), 0.5), 1)
        lockScreenEnabled = defaults.bool(forKey: "lockScreenEnabled")
        lockScreenWallpaperID = UUID(uuidString: defaults.string(forKey: "lockScreenWallpaperID") ?? "")
        pauseOnBattery = defaults.bool(forKey: "pauseOnBattery")
        pauseOnLowPower = defaults.bool(forKey: "pauseOnLowPower")
        pauseOnThermalPressure = defaults.bool(forKey: "pauseOnThermalPressure")
        playbackRate = defaults.double(forKey: "playbackRate")
        audioEnabled = defaults.bool(forKey: "audioEnabled")
        volume = defaults.double(forKey: "volume")
        videoScaling = VideoScaling(rawValue: defaults.string(forKey: "videoScaling") ?? "") ?? .fill
        crossfade = defaults.bool(forKey: "crossfade")
        shaderFrameRate = defaults.integer(forKey: "shaderFrameRate")
        shaderQuality = ShaderQuality(rawValue: defaults.string(forKey: "shaderQuality") ?? "") ?? .balanced
        syncStillFrame = defaults.bool(forKey: "syncStillFrame")
        dockIconMode = DockIconMode(rawValue: defaults.string(forKey: "dockIconMode") ?? "") ?? .whileWindowOpen
    }

    private func store(_ value: Any, _ key: String, _ change: Change?) {
        defaults.set(value, forKey: key)
        if let change { observers.forEach { $0(change) } }
    }
}
