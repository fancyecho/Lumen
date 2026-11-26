import Foundation

/// Finds Wallpaper Engine's shared `assets` folder (shaders, materials, effects), which scenes
/// rely on but which isn't part of any Workshop item.
///
/// Lumen keeps its own copy in `Application Support/Lumen/SceneAssets`, either downloaded from
/// Steam or copied from a folder it found, so removing another app never breaks scenes.
enum SceneAssetsLocator {
    static var ownFolder: URL { AppPaths.root.appending(path: "SceneAssets", directoryHint: .isDirectory) }

    /// Places a copy may already exist on this Mac, Lumen's own first.
    static var candidates: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var urls = [
            ownFolder,
            support.appending(path: "WallpaperMachine/SceneAssets"),
            support.appending(path: "Steam/steamapps/common/wallpaper_engine/assets"),
        ]
        for library in SteamLibrary.libraryFolders() {
            urls.append(library.appending(path: "steamapps/common/wallpaper_engine/assets"))
        }
        return urls
    }

    /// Lumen's own copy; until it exists, a configured folder or another copy found on this Mac.
    static func resolve(configured path: String) -> URL? {
        if isAssetsFolder(ownFolder) { return ownFolder }
        return configuredFolder(path) ?? candidates.first(where: isAssetsFolder)
    }

    private static func configuredFolder(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        if isAssetsFolder(url) { return url }
        let nested = url.appending(path: "assets")
        return isAssetsFolder(nested) ? nested : nil
    }

    /// A real assets folder has the core image shader and the common include.
    static func isAssetsFolder(_ url: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: url.appending(path: "shaders/genericimage2.frag").path)
            && manager.fileExists(atPath: url.appending(path: "shaders/common.h").path)
    }

    /// Copies assets found elsewhere into Lumen's own folder when it has none yet. On the same
    /// APFS volume the copy is a clone and takes no extra space. Returns true if it copied.
    /// Runs file I/O; call it off the main thread.
    @discardableResult
    static func adoptExternalCopy(configured path: String) -> Bool {
        guard !isAssetsFolder(ownFolder) else { return false }
        let others = candidates.dropFirst()
        guard let source = configuredFolder(path) ?? others.first(where: isAssetsFolder) else { return false }
        return (try? importCopy(from: source)) != nil
    }

    /// Copies a chosen assets folder (or a folder containing `assets`) into Lumen's own folder.
    static func importCopy(from folder: URL) throws {
        guard let source = configuredFolder(folder.path) else { throw CocoaError(.fileReadCorruptFile) }
        let staging = AppPaths.root.appending(path: "SceneAssets.copy-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: AppPaths.root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: staging)
            try install(staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Moves a verified folder into place as Lumen's copy, replacing any older one.
    static func install(_ folder: URL) throws {
        guard isAssetsFolder(folder) else { throw CocoaError(.fileReadCorruptFile) }
        let manager = FileManager.default
        if manager.fileExists(atPath: ownFolder.path) {
            _ = try manager.replaceItemAt(ownFolder, withItemAt: folder)
        } else {
            try manager.moveItem(at: folder, to: ownFolder)
        }
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
