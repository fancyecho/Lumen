import AppKit
import Foundation
import ServiceManagement
import os

// MARK: - Paths

enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Lumen", directoryHint: .isDirectory)
    }()
    static let items = root.appending(path: "Items", directoryHint: .isDirectory)
    static let stills = root.appending(path: "Stills", directoryHint: .isDirectory)
    static let thumbnails = root.appending(path: "Thumbnails", directoryHint: .isDirectory)
    static let libraryFile = root.appending(path: "library.json")
    static let playlistsFile = root.appending(path: "playlists.json")

    static func prepare() {
        for directory in [root, items, stills, thumbnails] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func folder(for id: UUID) -> URL {
        items.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}

// MARK: - Logging

enum Log {
    static let engine = Logger(subsystem: "app.lumen.Lumen", category: "engine")
    static let policy = Logger(subsystem: "app.lumen.Lumen", category: "policy")
    static let library = Logger(subsystem: "app.lumen.Lumen", category: "library")
}

// MARK: - Stable hashing (Swift's Hasher is seeded per launch)

enum StableHash {
    static func hex(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func hex<T: Encodable>(of value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return hex((try? encoder.encode(value)) ?? Data())
    }
}

// MARK: - Formatting

enum Format {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "–" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func resolution(_ width: Int, _ height: Int) -> String { "\(width)×\(height)" }

    static func resolutionClass(_ width: Int, _ height: Int) -> String? {
        switch max(width, height) {
        case 7680...: "8K"
        case 5120...: "5K"
        case 3840...: "4K"
        case 2560...: "QHD"
        case 1920...: "HD"
        default: nil
        }
    }

    static func frameRate(_ fps: Double) -> String {
        fps > 0 ? "\(Int(fps.rounded())) fps" : "–"
    }

    static func greeting(for date: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }

    static func interval(minutes: Int) -> String {
        if minutes >= 60, minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? String(localized: "every hour") : String(localized: "every \(hours) hours")
        }
        return String(localized: "every \(minutes) min")
    }
}

// MARK: - Displays

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Survives reconnects and reboots, unlike `CGDirectDisplayID`.
    var displayUUID: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    var pixelSize: CGSize {
        CGSize(width: frame.width * backingScaleFactor, height: frame.height * backingScaleFactor)
    }

    var isBuiltin: Bool { CGDisplayIsBuiltin(displayID) != 0 }

    static func screen(withUUID uuid: String) -> NSScreen? {
        screens.first { $0.displayUUID == uuid }
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
