import Foundation

/// Finds Wallpaper Engine's shared `assets` folder (shaders, materials, effects), which scenes
/// rely on but which isn't part of any Workshop item. Lumen only reads it.
enum SceneAssetsLocator {
    /// Places a copy may already exist on this Mac.
    static var candidates: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var urls = [
            support.appending(path: "Lumen/SceneAssets"),
            support.appending(path: "WallpaperMachine/SceneAssets"),
            support.appending(path: "Steam/steamapps/common/wallpaper_engine/assets"),
        ]
        for library in SteamLibrary.libraryFolders() {
            urls.append(library.appending(path: "steamapps/common/wallpaper_engine/assets"))
        }
        return urls
    }

    /// The configured folder if valid, otherwise the first copy found.
    static func resolve(configured path: String) -> URL? {
        if !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            if isAssetsFolder(url) { return url }
            let nested = url.appending(path: "assets")
            if isAssetsFolder(nested) { return nested }
        }
        return candidates.first(where: isAssetsFolder)
    }

    /// A real assets folder has the core image shader and the common include.
    static func isAssetsFolder(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: url.appending(path: "shaders/genericimage2.frag").path)
            && manager.fileExists(atPath: url.appending(path: "shaders/common.h").path)
    }
}

/// Steam's library folders on this Mac, read from `libraryfolders.vdf`.
enum SteamLibrary {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Steam")
    }

    static func libraryFolders() -> [URL] {
        var folders = [root]
        let file = root.appending(path: "steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for match in text.matches(of: /"path"\s+"([^"]+)"/) {
                let url = URL(fileURLWithPath: String(match.1).replacingOccurrences(of: "\\\\", with: "/"))
                if !folders.contains(url) { folders.append(url) }
            }
        }
        return folders
    }

    /// Wallpaper Engine's Workshop download folders (app 431960).
    static func workshopFolders() -> [URL] {
        libraryFolders()
            .map { $0.appending(path: "steamapps/workshop/content/431960", directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
