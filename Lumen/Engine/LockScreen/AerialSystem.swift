import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Talks to the per-user Aerial catalog that macOS uses for the Lock Screen and screen saver.
///
/// macOS keeps its Aerial manifest (`entries.json`) and downloaded videos in the user's
/// Library, and records the chosen wallpaper/Lock Screen ("Desktop") and screen saver ("Idle")
/// choices in the wallpaper store (`Index.plist`). macOS 14+ plays the Desktop Aerial on the
/// Lock Screen and requires display overrides to carry both Desktop and Idle entries. Lumen adds
/// one asset under its own "Lumen" category, updates the store choices while backing up originals,
/// and restarts `WallpaperAgent` so the change takes effect without visiting System Settings.
/// No administrator rights are needed, and nothing outside Lumen's own IDs is touched.
enum AerialSystem {
    enum Slot: String, CaseIterable, Hashable {
        case desktop = "Desktop"
        case idle = "Idle"
    }

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
    private static let absentMarkerKey = "__lumenAbsent"
    private static let originalTypeKey = "originalType"
    private static let typeBackupSuffix = "__type"

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

    /// Points Desktop (Lock Screen) and optionally Idle (screen saver) choices at `assetID`
    /// across `SystemDefault`, `AllSpacesAndDisplays`, `Displays/<id>`, `Spaces/<id>/Default`,
    /// and `Spaces/<id>/Displays/<id>`.
    ///
    /// Displays in `excludedDesktopDisplayIDs` keep their Desktop choice (for secondary monitors
    /// managed by `StillFrameSync`). Every container carrying a Desktop choice is guaranteed to
    /// also carry an Idle choice, because macOS rejects partial display overrides.
    static func select(
        assetID: String,
        includeIdle: Bool = true,
        excludedDesktopDisplayIDs: Set<String> = [],
        backup: inout [String: Data]
    ) throws {
        let root = try readIndex()
        let updated = try applySelection(
            to: root,
            assetID: assetID,
            includeIdle: includeIdle,
            excludedDesktopDisplayIDs: excludedDesktopDisplayIDs,
            backup: &backup
        )
        try writeIndex(updated)
    }

    /// Puts back the original Desktop and Idle choices, only where Lumen's asset is still selected.
    static func restoreSelection(from backup: [String: Data], slots: Set<Slot> = [.desktop, .idle]) throws {
        let root = try readIndex()
        let restored = applyRestore(to: root, from: backup, slots: slots)
        try writeIndex(restored)
    }

    /// Whether every managed container in the wallpaper store currently matches Lumen's expected selection.
    static func isSelectionActive(
        assetID: String,
        includeIdle: Bool = true,
        excludedDesktopDisplayIDs: Set<String> = []
    ) -> Bool {
        guard let root = try? readIndex() else { return false }
        return isSelectionActive(
            in: root,
            assetID: assetID,
            includeIdle: includeIdle,
            excludedDesktopDisplayIDs: excludedDesktopDisplayIDs
        )
    }

    /// Pure store rewrite for `select`, exposed for unit tests.
    static func applySelection(
        to root: [String: Any],
        assetID: String,
        includeIdle: Bool = true,
        excludedDesktopDisplayIDs: Set<String> = [],
        backup: inout [String: Data],
        now: Date = Date()
    ) throws -> [String: Any] {
        let choice = try aerialChoice(assetID: assetID)
        let fallbackIdle = firstExistingSlot(.idle, in: root) ?? makeSlot(choice: choice, now: now)

        return mapContainers(in: root, ensureRoots: true) { path, displayID, container in
            var updated = container
            let originalType = updated["Type"] as? String
            let wantsDesktop = displayID.map { !excludedDesktopDisplayIDs.contains($0) } ?? true

            if wantsDesktop {
                recordBackupIfNeeded(for: .desktop, in: updated, path: path, originalType: originalType, backup: &backup)
                updated[Slot.desktop.rawValue] = updatedSlot(updated[Slot.desktop.rawValue], choice: choice, now: now)
            }

            if includeIdle {
                recordBackupIfNeeded(for: .idle, in: updated, path: path, originalType: originalType, backup: &backup)
                updated[Slot.idle.rawValue] = updatedSlot(updated[Slot.idle.rawValue], choice: choice, now: now)
            } else {
                // Turning off screen-saver mirroring restores any Idle slot Lumen previously took over.
                restoreSlot(.idle, in: &updated, path: path, from: backup, now: now)
                if updated[Slot.desktop.rawValue] != nil, updated[Slot.idle.rawValue] == nil {
                    // macOS requires display overrides to carry both Desktop and Idle.
                    updated[Slot.idle.rawValue] = fallbackIdle
                }
            }

            if updated[Slot.desktop.rawValue] != nil, updated[Slot.idle.rawValue] != nil {
                let desiredType: String
                if let originalType, originalType != "idle", (includeIdle || originalType != "linked") {
                    desiredType = originalType
                } else {
                    desiredType = "individual"
                }
                if desiredType != originalType {
                    recordTypeBackupIfNeeded(originalType, path: path, backup: &backup)
                    updated["Type"] = desiredType
                }
            } else if updated[Slot.idle.rawValue] != nil, updated["Type"] == nil {
                updated["Type"] = "idle"
            }

            return updated
        }
    }

    /// Pure store restore for `restoreSelection`, exposed for unit tests.
    static func applyRestore(
        to root: [String: Any],
        from backup: [String: Data],
        slots: Set<Slot> = [.desktop, .idle],
        now: Date = Date()
    ) -> [String: Any] {
        mapContainers(in: root, ensureRoots: false) { path, _, container in
            var updated = container
            for slot in Slot.allCases where slots.contains(slot) {
                restoreSlot(slot, in: &updated, path: path, from: backup, now: now)
            }
            let stillPointsAtLumen = Slot.allCases.contains { slot in
                guard let content = slotContent(slot, in: updated) else { return false }
                return contentPointsAtLumen(content)
            }
            if !stillPointsAtLumen, let savedType = savedTypeBackup(for: path, from: backup) {
                let hasDesktop = updated[Slot.desktop.rawValue] != nil
                let hasIdle = updated[Slot.idle.rawValue] != nil
                if (savedType == "idle" && !hasDesktop && hasIdle) || (savedType != "idle" && hasDesktop && hasIdle) {
                    updated["Type"] = savedType
                }
            }
            return updated
        }
    }

    /// Pure verification against an in-memory store plist, exposed for unit tests.
    static func isSelectionActive(
        in root: [String: Any],
        assetID: String,
        includeIdle: Bool = true,
        excludedDesktopDisplayIDs: Set<String> = []
    ) -> Bool {
        guard root["SystemDefault"] is [String: Any], root["AllSpacesAndDisplays"] is [String: Any] else {
            return false
        }
        var ok = true
        _ = mapContainers(in: root, ensureRoots: false) { _, displayID, container in
            let wantsDesktop = displayID.map { !excludedDesktopDisplayIDs.contains($0) } ?? true
            if wantsDesktop {
                guard let content = slotContent(.desktop, in: container),
                      contentPointsExactlyAt(content, assetID: assetID) else {
                    ok = false
                    return container
                }
            }
            if includeIdle {
                guard let content = slotContent(.idle, in: container),
                      contentPointsExactlyAt(content, assetID: assetID) else {
                    ok = false
                    return container
                }
            } else if let content = slotContent(.idle, in: container), contentPointsAtLumen(content) {
                ok = false
                return container
            }
            if container[Slot.desktop.rawValue] != nil, container[Slot.idle.rawValue] == nil {
                ok = false
            }
            return container
        }
        return ok
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

    private static func makeSlot(choice: [String: Any], now: Date) -> [String: Any] {
        [
            "Content": [
                "Choices": [choice],
                "EncodedOptionValues": "$null",
                "Shuffle": "$null",
            ] as [String: Any],
            "LastSet": now,
            "LastUse": now,
        ]
    }

    private static func updatedSlot(_ existing: Any?, choice: [String: Any], now: Date) -> [String: Any] {
        guard var slot = existing as? [String: Any],
              var content = slot["Content"] as? [String: Any] else {
            return makeSlot(choice: choice, now: now)
        }
        content["Choices"] = [choice]
        slot["Content"] = content
        slot["LastSet"] = now
        return slot
    }

    private static func slotContent(_ slot: Slot, in container: [String: Any]) -> [String: Any]? {
        (container[slot.rawValue] as? [String: Any])?["Content"] as? [String: Any]
    }

    private static func firstExistingSlot(_ slot: Slot, in root: [String: Any]) -> [String: Any]? {
        for key in ["SystemDefault", "AllSpacesAndDisplays"] {
            if let container = root[key] as? [String: Any],
               let existing = container[slot.rawValue] as? [String: Any] {
                return existing
            }
        }
        return nil
    }

    private static func backupKey(path: [String], slot: Slot) -> String {
        (path + [slot.rawValue]).joined(separator: "/")
    }

    private static func typeBackupKey(path: [String]) -> String {
        (path + [typeBackupSuffix]).joined(separator: "/")
    }

    private static func recordBackupIfNeeded(
        for slot: Slot,
        in container: [String: Any],
        path: [String],
        originalType: String?,
        backup: inout [String: Data]
    ) {
        let key = backupKey(path: path, slot: slot)
        guard backup[key] == nil else { return }
        if let content = slotContent(slot, in: container) {
            guard !contentPointsAtLumen(content),
                  let data = try? PropertyListSerialization.data(fromPropertyList: content, format: .binary, options: 0)
            else { return }
            backup[key] = data
        } else {
            var marker: [String: Any] = [absentMarkerKey: true]
            if let originalType { marker[originalTypeKey] = originalType }
            if let data = try? PropertyListSerialization.data(fromPropertyList: marker, format: .binary, options: 0) {
                backup[key] = data
            }
        }
    }

    private static func recordTypeBackupIfNeeded(_ originalType: String?, path: [String], backup: inout [String: Data]) {
        guard let originalType else { return }
        let key = typeBackupKey(path: path)
        guard backup[key] == nil else { return }
        backup[key] = Data(originalType.utf8)
    }

    private static func savedTypeBackup(for path: [String], from backup: [String: Data]) -> String? {
        guard let data = backup[typeBackupKey(path: path)] else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeBackup(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func isAbsentMarker(_ dict: [String: Any]) -> Bool {
        dict[absentMarkerKey] as? Bool == true
    }

    private static func fallbackContent(for slot: Slot, from backup: [String: Data]) -> [String: Any]? {
        let preferred = "SystemDefault/\(slot.rawValue)"
        if let data = backup[preferred], let dict = decodeBackup(data), !isAbsentMarker(dict) {
            return dict
        }
        let suffix = "/\(slot.rawValue)"
        for key in backup.keys.sorted() where key.hasSuffix(suffix) {
            if let data = backup[key], let dict = decodeBackup(data), !isAbsentMarker(dict) {
                return dict
            }
        }
        return nil
    }

    private static func restoreSlot(
        _ slot: Slot,
        in container: inout [String: Any],
        path: [String],
        from backup: [String: Data],
        now: Date
    ) {
        guard var slotDict = container[slot.rawValue] as? [String: Any],
              let content = slotDict["Content"] as? [String: Any],
              contentPointsAtLumen(content) else { return }

        let key = backupKey(path: path, slot: slot)
        if let data = backup[key], let saved = decodeBackup(data) {
            if isAbsentMarker(saved) {
                container.removeValue(forKey: slot.rawValue)
                if let originalType = saved[originalTypeKey] as? String {
                    container["Type"] = originalType
                }
                return
            }
            slotDict["Content"] = saved
            slotDict["LastSet"] = now
            container[slot.rawValue] = slotDict
            return
        }

        // Slots created after Lumen took over (e.g. a new Space) borrow a same-kind original.
        if let borrowed = fallbackContent(for: slot, from: backup) {
            slotDict["Content"] = borrowed
            slotDict["LastSet"] = now
            container[slot.rawValue] = slotDict
            return
        }

        // AllSpacesAndDisplays normally has only Idle unless a Desktop backup existed.
        if path == ["AllSpacesAndDisplays"], slot == .desktop, container[Slot.idle.rawValue] != nil {
            container.removeValue(forKey: Slot.desktop.rawValue)
            container["Type"] = "idle"
            return
        }

        var cleared = content
        cleared["Choices"] = [Any]()
        slotDict["Content"] = cleared
        slotDict["LastSet"] = now
        container[slot.rawValue] = slotDict
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

    private static func contentPointsExactlyAt(_ content: [String: Any], assetID: String) -> Bool {
        let choices = content["Choices"] as? [[String: Any]] ?? []
        guard !choices.isEmpty else { return false }
        let ids = assetIDs(in: content)
        return ids.count == choices.count && ids.allSatisfy { $0 == assetID }
    }

    /// Visits every wallpaper container in `Index.plist`:
    /// `SystemDefault`, `AllSpacesAndDisplays`, `Displays/<id>`, `Spaces/<id>/Default`,
    /// and `Spaces/<id>/Displays/<id>`.
    private static func mapContainers(
        in root: [String: Any],
        ensureRoots: Bool,
        transform: (_ path: [String], _ displayID: String?, _ container: [String: Any]) -> [String: Any]
    ) -> [String: Any] {
        var result = root

        for key in ["SystemDefault", "AllSpacesAndDisplays"] {
            if let existing = result[key] as? [String: Any] {
                result[key] = transform([key], nil, existing)
            } else if ensureRoots {
                result[key] = transform([key], nil, [:])
            }
        }

        if var displays = result["Displays"] as? [String: Any] {
            for (displayID, value) in displays {
                guard let container = value as? [String: Any] else { continue }
                displays[displayID] = transform(["Displays", displayID], displayID, container)
            }
            result["Displays"] = displays
        }

        if var spaces = result["Spaces"] as? [String: Any] {
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any] else { continue }
                if let def = space["Default"] as? [String: Any] {
                    space["Default"] = transform(["Spaces", spaceID, "Default"], nil, def)
                } else if ensureRoots {
                    space["Default"] = transform(["Spaces", spaceID, "Default"], nil, [:])
                }
                if var spaceDisplays = space["Displays"] as? [String: Any] {
                    for (displayID, displayValue) in spaceDisplays {
                        guard let container = displayValue as? [String: Any] else { continue }
                        spaceDisplays[displayID] = transform(["Spaces", spaceID, "Displays", displayID], displayID, container)
                    }
                    space["Displays"] = spaceDisplays
                }
                spaces[spaceID] = space
            }
            result["Spaces"] = spaces
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
