import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Talks to the per-user Aerial catalog that macOS uses for the Lock Screen and screen saver.
///
/// macOS keeps its Aerial manifest (`entries.json`) and downloaded videos in the user's
/// Library, and records the chosen Lock Screen / screen saver Aerial in the wallpaper store
/// (`Index.plist`, the "Idle" choices). Lumen adds one asset under its own "Lumen" category,
/// points the Idle choices at it, and restarts `WallpaperAgent` so the change is picked up.
/// No administrator rights are needed, and nothing outside Lumen's own IDs is touched.
enum AerialSystem {
    static let wallpaperRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/com.apple.wallpaper", directoryHint: .isDirectory)
    static let aerialsRoot = wallpaperRoot.appending(path: "aerials", directoryHint: .isDirectory)
    static let manifestFile = aerialsRoot.appending(path: "manifest/entries.json")
    static let videosFolder = aerialsRoot.appending(path: "videos", directoryHint: .isDirectory)
    static let thumbnailsFolder = aerialsRoot.appending(path: "thumbnails", directoryHint: .isDirectory)
    static let storeIndex = wallpaperRoot.appending(path: "Store/Index.plist")

    static let idPrefix = "4C554D45-AE00-"
    static let categoryID = "4C554D45-AE00-4000-8000-000000000001"
    static let subcategoryID = "4C554D45-AE00-4000-8000-000000000002"
    /// Two alternating slots, so WallpaperAgent never reuses a cached decode of the previous video.
    static let assetSlots = ["4C554D45-AE00-4000-8000-0000000000A1", "4C554D45-AE00-4000-8000-0000000000A2"]

    private static let aerialProvider = "com.apple.wallpaper.choice.aerials"

    enum Failure: LocalizedError {
        case unsupported
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                String(localized: "This Mac has no Aerial catalog yet. Open System Settings › Wallpaper once, then try again.")
            case .unreadable(let what):
                String(localized: "Couldn't read \(what).")
            }
        }
    }

    static var isSupported: Bool {
        FileManager.default.fileExists(atPath: manifestFile.path) && FileManager.default.fileExists(atPath: storeIndex.path)
    }

    static func isLumenID(_ id: String?) -> Bool { id?.hasPrefix(idPrefix) ?? false }

    // MARK: Catalog

    /// Lumen's asset currently in the manifest, if any (macOS can replace the manifest on updates).
    static func installedAssetID() -> String? {
        guard let root = try? readManifest(),
              let assets = root["assets"] as? [[String: Any]]
        else { return nil }
        return assets.compactMap { $0["id"] as? String }.first(where: isLumenID)
    }

    static func videoURL(for assetID: String) -> URL { videosFolder.appending(path: "\(assetID).mov") }
    static func thumbnailURL(for assetID: String) -> URL { thumbnailsFolder.appending(path: "\(assetID).png") }

    /// Copies the video into the Aerial folder and registers it in the manifest. Returns the asset ID.
    static func install(video: URL, thumbnail: CGImage?, title: String, previousAssetID: String?) throws -> String {
        guard isSupported else { throw Failure.unsupported }
        let assetID = previousAssetID == assetSlots[0] ? assetSlots[1] : assetSlots[0]
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: videosFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsFolder, withIntermediateDirectories: true)

        let destination = videoURL(for: assetID)
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: video, to: destination)
        if let thumbnail { writePNG(thumbnail, to: thumbnailURL(for: assetID)) }

        try writeManifestEntry(assetID: assetID, title: title)
        for slot in assetSlots where slot != assetID {
            try? fileManager.removeItem(at: videoURL(for: slot))
            try? fileManager.removeItem(at: thumbnailURL(for: slot))
        }
        return assetID
    }

    /// Re-adds the manifest entry for an already-copied video (after macOS refreshed the manifest).
    static func repairManifest(assetID: String, title: String) throws {
        try writeManifestEntry(assetID: assetID, title: title)
    }

    static func removeFromCatalog() {
        if var root = try? readManifest() {
            root["assets"] = (root["assets"] as? [[String: Any]] ?? []).filter { !isLumenID($0["id"] as? String) }
            root["categories"] = (root["categories"] as? [[String: Any]] ?? []).filter { !isLumenID($0["id"] as? String) }
            try? writeManifest(root)
        }
        for slot in assetSlots {
            try? FileManager.default.removeItem(at: videoURL(for: slot))
            try? FileManager.default.removeItem(at: thumbnailURL(for: slot))
        }
    }

    private static func writeManifestEntry(assetID: String, title: String) throws {
        var root = try readManifest()
        var assets = (root["assets"] as? [[String: Any]] ?? []).filter { !isLumenID($0["id"] as? String) }
        var categories = (root["categories"] as? [[String: Any]] ?? []).filter { !isLumenID($0["id"] as? String) }
        let video = videoURL(for: assetID).absoluteString
        let preview = thumbnailURL(for: assetID).absoluteString

        assets.append([
            "id": assetID,
            "accessibilityLabel": title,
            "localizedNameKey": title,
            "shotID": "LUMEN_\(assetID.suffix(2))",
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "includeInShuffle": false,
            "showInTopLevel": true,
            "preferredOrder": 0,
            "pointsOfInterest": [String: String](),
            "previewImage": preview,
            "url-4K-SDR-240FPS": video,
        ])
        categories.append([
            "id": categoryID,
            "localizedNameKey": "Lumen",
            "localizedDescriptionKey": "Lumen",
            "preferredOrder": 0,
            "previewImage": preview,
            "representativeAssetID": assetID,
            "subcategories": [[
                "id": subcategoryID,
                "localizedNameKey": "Lumen",
                "localizedDescriptionKey": "Lumen",
                "preferredOrder": 0,
                "previewImage": preview,
                "representativeAssetID": assetID,
            ]],
        ])
        root["assets"] = assets
        root["categories"] = categories
        try writeManifest(root)
    }

    private static func readManifest() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: manifestFile),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.unreadable("the Aerial manifest") }
        return root
    }

    private static func writeManifest(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
        try data.write(to: manifestFile, options: .atomic)
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    // MARK: Selection

    /// Points every Lock Screen / screen saver ("Idle") choice at `assetID`.
    /// The first time a choice is replaced, its original content is added to `backup`.
    static func select(assetID: String, backup: inout [String: Data]) throws {
        var root = try readIndex()
        var touched = 0
        let choice = try aerialChoice(assetID: assetID)
        root = rewriteIdle(in: root, path: []) { path, content in
            let key = path.joined(separator: "/")
            if backup[key] == nil, !contentPointsAtLumen(content),
               let original = try? PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0) {
                backup[key] = original
            }
            var updated = content
            updated["Choices"] = [choice]
            touched += 1
            return updated
        }
        if touched == 0 {
            // No Idle choice yet (fresh account): create one for all Spaces and displays.
            var all = root["AllSpacesAndDisplays"] as? [String: Any] ?? ["Type": "idle"]
            all["Idle"] = [
                "Content": ["Choices": [choice], "EncodedOptionValues": "$null", "Shuffle": "$null"],
                "LastSet": Date(),
                "LastUse": Date(),
            ] as [String: Any]
            root["AllSpacesAndDisplays"] = all
        }
        try writeIndex(root)
    }

    /// Puts back the original Idle choices, but only where Lumen's asset is still selected.
    static func restoreSelection(from backup: [String: Data]) throws {
        var root = try readIndex()
        root = rewriteIdle(in: root, path: []) { path, content in
            guard contentPointsAtLumen(content) else { return nil }
            // Slots created after Lumen took over have no backup of their own; borrow any original.
            if let data = backup[path.joined(separator: "/")] ?? backup.values.first,
               let original = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                return original
            }
            var cleared = content
            cleared["Choices"] = [Any]()
            return cleared
        }
        try writeIndex(root)
    }

    /// Asset IDs currently selected for the Lock Screen / screen saver, across all Spaces and displays.
    static func selectedIdleAssetIDs() -> [String] {
        guard let root = try? readIndex() else { return [] }
        var ids: [String] = []
        _ = rewriteIdle(in: root, path: []) { _, content in
            ids.append(contentsOf: assetIDs(in: content))
            return nil
        }
        return ids
    }

    static func restartWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func aerialChoice(assetID: String) throws -> [String: Any] {
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        return ["Configuration": configuration, "Files": [Any](), "Provider": aerialProvider]
    }

    private static func assetIDs(in content: [String: Any]) -> [String] {
        let choices = content["Choices"] as? [[String: Any]] ?? []
        return choices.compactMap { choice in
            guard choice["Provider"] as? String == aerialProvider,
                  let data = choice["Configuration"] as? Data,
                  let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return configuration["assetID"] as? String
        }
    }

    private static func contentPointsAtLumen(_ content: [String: Any]) -> Bool {
        assetIDs(in: content).contains(where: isLumenID)
    }

    /// Walks the store and lets `transform` rewrite the `Content` of every "Idle" entry
    /// (returning nil leaves that entry untouched).
    private static func rewriteIdle(
        in node: [String: Any],
        path: [String],
        transform: ([String], [String: Any]) -> [String: Any]?
    ) -> [String: Any] {
        var result = node
        for (key, value) in node {
            guard var child = value as? [String: Any] else { continue }
            let childPath = path + [key]
            if key == "Idle", let content = child["Content"] as? [String: Any] {
                guard let updated = transform(childPath, content) else { continue }
                child["Content"] = updated
                child["LastSet"] = Date()
            } else {
                child = rewriteIdle(in: child, path: childPath, transform: transform)
            }
            result[key] = child
        }
        return result
    }

    private static func readIndex() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: storeIndex),
              let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Failure.unreadable("the wallpaper store") }
        return root
    }

    private static func writeIndex(_ root: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: storeIndex, options: .atomic)
    }
}
