import Foundation

/// Human-readable facts about a wallpaper, shared by cards, the list view, the detail page, Home and
/// the menu bar so every surface describes a wallpaper with the same words in the same order.
enum WallpaperDescriptor {
    static func kindLabel(_ wallpaper: Wallpaper) -> String {
        switch wallpaper.kind {
        case .video: String(localized: "Video")
        case .scene: String(localized: "Scene")
        case .web: String(localized: "Web")
        case .shader: wallpaper.isBuiltin ? String(localized: "Rendered Live") : String(localized: "Your Shader")
        }
    }

    static func kindSymbol(_ kind: WallpaperKind) -> String {
        switch kind {
        case .video: "film"
        case .scene: "square.3.layers.3d"
        case .web: "globe"
        case .shader: "sparkles"
        }
    }

    /// "Scene · Anime", "Video · Nature · 0:56" — the second line under a card title.
    static func subtitle(for wallpaper: Wallpaper) -> String {
        var parts = [kindLabel(wallpaper), WallpaperCategories.displayName(wallpaper.category)]
        if let video = wallpaper.video { parts.append(Format.duration(video.duration)) }
        if wallpaper.kind == .web, let host = remoteHost(wallpaper) { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    /// Technical facts on one line: "3840×2160 · HEVC · 60 fps · 0:56".
    static func specLine(for wallpaper: Wallpaper) -> String {
        var parts: [String] = []
        if let video = wallpaper.video {
            parts = [Format.resolution(video.width, video.height), video.codec, Format.frameRate(video.frameRate), Format.duration(video.duration)]
        } else {
            parts.append(kindLabel(wallpaper))
            if let resolution = resolution(for: wallpaper) { parts.append(resolution) }
            if let host = remoteHost(wallpaper) { parts.append(host) }
        }
        return parts.joined(separator: " · ")
    }

    static func resolution(for wallpaper: Wallpaper) -> String? {
        if let video = wallpaper.video { return Format.resolution(video.width, video.height) }
        if let width = wallpaper.package?.width, let height = wallpaper.package?.height, width > 0, height > 0 {
            return Format.resolution(width, height)
        }
        return nil
    }

    static func length(for wallpaper: Wallpaper) -> String? {
        wallpaper.video.map { Format.duration($0.duration) }
    }

    static func byteCount(for wallpaper: Wallpaper) -> Int64? {
        if let video = wallpaper.video { return video.fileSize }
        if let bytes = wallpaper.package?.byteCount, bytes > 0 { return bytes }
        return nil
    }

    /// Where the wallpaper came from, for the About panel.
    static func source(for wallpaper: Wallpaper) -> String? {
        if wallpaper.isBuiltin { return "Lumen" }
        if let video = wallpaper.video { return video.originalName }
        guard let package = wallpaper.package else { return nil }
        if let host = remoteHost(wallpaper) { return host }
        switch package.source {
        case "steam": return String(localized: "Steam Workshop")
        case "wallpapermachine": return "WallpaperMachine"
        case "folder": return String(localized: "Folder")
        default: return package.workshopID == nil ? nil : String(localized: "Steam Workshop")
        }
    }

    static func remoteHost(_ wallpaper: Wallpaper) -> String? {
        wallpaper.package?.remoteURL.flatMap { URL(string: $0)?.host() }
    }
}
