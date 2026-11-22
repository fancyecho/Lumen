import Foundation

struct ShaderPreset: Identifiable {
    let key: String
    let id: UUID
    let title: String
    let tagline: String
    let category: String
    let source: String
    let params: ShaderParams
    /// Multiplier on the render pixel budget: smooth fields need few pixels, line art needs more.
    let detail: Double

    var wallpaper: Wallpaper {
        Wallpaper(
            id: id,
            kind: .shader,
            title: title,
            category: category,
            author: "Lumen",
            addedAt: .distantPast,
            shader: ShaderConfig(presetKey: key, customSource: nil, params: params)
        )
    }
}

enum BuiltinShaders {
    static let all: [ShaderPreset] = [
        ShaderPreset(
            key: "silk", id: presetID(1), title: "Silk",
            tagline: "Folds of light drifting like satin", category: "Abstract",
            source: ShaderSources.silk,
            params: ShaderParams(colors: palette(0x0B1026, 0x4B36C9, 0xE0679F, 0xFFD2A6)), detail: 1.0
        ),
        ShaderPreset(
            key: "aurora", id: presetID(2), title: "Aurora",
            tagline: "Northern lights over a quiet ridge", category: "Nature",
            source: ShaderSources.aurora,
            params: ShaderParams(colors: palette(0x060B1A, 0x2BF5A0, 0x1FB5FF, 0xB04BFF)), detail: 1.0
        ),
        ShaderPreset(
            key: "nebula", id: presetID(3), title: "Nebula",
            tagline: "Slow gas clouds and distant stars", category: "Space",
            source: ShaderSources.nebula,
            params: ShaderParams(colors: palette(0x05030D, 0x6A2CB8, 0xE2458F, 0xFFE3B0)), detail: 1.0
        ),
        ShaderPreset(
            key: "bloom", id: presetID(4), title: "Bloom",
            tagline: "Soft pastel light, gently breathing", category: "Minimal",
            source: ShaderSources.bloom,
            params: ShaderParams(colors: palette(0xFF9A8B, 0xFF6A88, 0x8EC5FC, 0xE0C3FC)), detail: 0.6
        ),
        ShaderPreset(
            key: "contour", id: presetID(5), title: "Contour",
            tagline: "A living topographic map", category: "Minimal",
            source: ShaderSources.contour,
            params: ShaderParams(colors: palette(0x07090F, 0x14213D, 0x4CC9F0, 0xF72585)), detail: 1.8
        ),
        ShaderPreset(
            key: "lava", id: presetID(6), title: "Lava",
            tagline: "Warm wax rising and falling", category: "Abstract",
            source: ShaderSources.lava,
            params: ShaderParams(colors: palette(0x12001F, 0xFF4E50, 0xF9D423, 0xFC913A)), detail: 1.0
        ),
    ]

    static let ids: Set<UUID> = Set(all.map(\.id))
    static let wallpapers: [Wallpaper] = all.map(\.wallpaper)

    static func preset(key: String) -> ShaderPreset? { all.first { $0.key == key } }
    static func preset(id: UUID) -> ShaderPreset? { all.first { $0.id == id } }

    private static func presetID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "4C554D45-0000-4000-8000-%012d", index))!
    }

    private static func palette(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> [RGBAColor] {
        [a, b, c, d].map(RGBAColor.init(hex:))
    }
}
