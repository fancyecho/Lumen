import AppKit
import Foundation
import SwiftUI

enum WallpaperKind: String, Codable, Hashable {
    case video
    case shader
}

struct Wallpaper: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: WallpaperKind
    var title: String
    var category: String
    var author: String
    var addedAt: Date
    var isFavorite: Bool = false
    var video: VideoAsset?
    var shader: ShaderConfig?

    var isBuiltin: Bool { BuiltinShaders.ids.contains(id) }
}

struct VideoAsset: Codable, Hashable {
    var fileName: String
    var originalName: String
    var width: Int
    var height: Int
    var duration: Double
    var frameRate: Double
    var codec: String
    var fileSize: Int64
    var isHDR: Bool
    var hasAudio: Bool
    var optimized: OptimizedVideo?
}

struct OptimizedVideo: Codable, Hashable {
    var fileName: String
    var width: Int
    var height: Int
    var fileSize: Int64
}

struct ShaderConfig: Codable, Hashable {
    var presetKey: String?
    var customSource: String?
    var params: ShaderParams

    var resolvedSource: String? {
        customSource ?? presetKey.flatMap { BuiltinShaders.preset(key: $0)?.source }
    }

    /// Smooth presets render at a lower internal resolution without visible loss.
    var detail: Double {
        presetKey.flatMap { BuiltinShaders.preset(key: $0)?.detail } ?? 1
    }
}

struct ShaderParams: Codable, Hashable {
    var speed: Double = 1
    var intensity: Double = 1
    var scale: Double = 1
    var colors: [RGBAColor]
}

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = Double(resolved.redComponent)
        green = Double(resolved.greenComponent)
        blue = Double(resolved.blueComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    var vector: SIMD4<Float> { SIMD4(Float(red), Float(green), Float(blue), 1) }
}

struct Playlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var wallpaperIDs: [UUID] = []
    var intervalMinutes: Int = 30
    var shuffle: Bool = false
    var createdAt = Date()
}

enum DisplayTarget: Hashable {
    case allDisplays
    case display(String)
}

enum WallpaperCategories {
    static let all = ["Abstract", "Anime", "City", "Games", "Minimal", "Nature", "Space", "Sci-Fi", "Other"]

    /// Categories are stored as English keys; this is what the UI shows.
    static func displayName(_ key: String) -> String {
        switch key {
        case "Abstract": String(localized: "Abstract")
        case "Anime": String(localized: "Anime")
        case "City": String(localized: "City")
        case "Games": String(localized: "Games")
        case "Minimal": String(localized: "Minimal")
        case "Nature": String(localized: "Nature")
        case "Space": String(localized: "Space")
        case "Sci-Fi": String(localized: "Sci-Fi")
        case "Other": String(localized: "Other")
        default: key
        }
    }
}

extension ShaderUniforms {
    init(params: ShaderParams) {
        self.init()
        apply(params)
    }

    mutating func apply(_ params: ShaderParams) {
        speed = Float(params.speed)
        intensity = Float(params.intensity)
        scale = Float(params.scale)
        let padded = params.colors + Array(repeating: RGBAColor(hex: 0), count: max(0, 4 - params.colors.count))
        color0 = padded[0].vector
        color1 = padded[1].vector
        color2 = padded[2].vector
        color3 = padded[3].vector
    }
}
