import Foundation
import Observation

enum VideoScaling: String, CaseIterable, Identifiable {
    case fill, fit, stretch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fill: "Fill screen"
        case .fit: "Fit inside"
        case .stretch: "Stretch"
        }
    }
}

enum ShaderQuality: String, CaseIterable, Identifiable {
    case efficient, balanced, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .efficient: "Efficient"
        case .balanced: "Balanced"
        case .full: "Native"
        }
    }
    var detail: String {
        switch self {
        case .efficient: "Renders about 1 MP and upscales. Lowest GPU use."
        case .balanced: "Renders about 2 MP. Indistinguishable for smooth scenes."
        case .full: "Renders every pixel of the display. Highest GPU use."
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
        case .whileWindowOpen: "Only while the window is open"
        case .always: "Always"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
    enum Change {
        case policy, playback, scaling, shader, stillFrame
    }

    @ObservationIgnored var onChange: ((Change) -> Void)?
    @ObservationIgnored private let defaults = UserDefaults.standard

    var pauseWhenCovered: Bool { didSet { store(pauseWhenCovered, "pauseWhenCovered", .policy) } }
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

    var shaderRenderSettings: ShaderRenderSettings {
        ShaderRenderSettings(frameRate: shaderFrameRate, pixelBudget: shaderQuality.pixelBudget)
    }

    init() {
        defaults.register(defaults: [
            "pauseWhenCovered": true,
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
        if let change { onChange?(change) }
    }
}
