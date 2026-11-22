import AppKit
import Foundation

/// Mirrors the live wallpaper into the system desktop picture.
///
/// macOS briefly shows the real desktop picture during Mission Control, Space
/// switches and full-screen transitions, and uses it to tint the menu bar. Setting it
/// to a frame of the live wallpaper keeps all of those consistent. The user's
/// original picture is remembered per display and restored when a wallpaper is cleared.
@MainActor
final class StillFrameSync {
    private static let originalsKey = "originalDesktopPictures"
    private var originals: [String: String]
    private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        originals = UserDefaults.standard.dictionary(forKey: Self.originalsKey) as? [String: String] ?? [:]
    }

    func sync(_ wallpaper: Wallpaper, on screen: NSScreen, library: LibraryStore) {
        let displayID = screen.displayUUID
        tasks[displayID]?.cancel()
        tasks[displayID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await self.stillImage(for: wallpaper, pixelSize: screen.pixelSize, library: library)
                guard !Task.isCancelled, let screen = NSScreen.screen(withUUID: displayID) else { return }
                self.rememberOriginal(for: screen)
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                    .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                    .allowClipping: NSNumber(value: true),
                ])
            } catch {
                Log.engine.error("Still frame sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func restoreOriginal(for screen: NSScreen) {
        let displayID = screen.displayUUID
        tasks[displayID]?.cancel()
        tasks[displayID] = nil
        guard let path = originals.removeValue(forKey: displayID) else { return }
        persist()
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
    }

    func restoreAll() {
        for screen in NSScreen.screens { restoreOriginal(for: screen) }
    }

    private func rememberOriginal(for screen: NSScreen) {
        let displayID = screen.displayUUID
        guard originals[displayID] == nil,
              let current = NSWorkspace.shared.desktopImageURL(for: screen),
              !current.path.hasPrefix(AppPaths.stills.path)
        else { return }
        originals[displayID] = current.path
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(originals, forKey: Self.originalsKey)
    }

    private func stillImage(for wallpaper: Wallpaper, pixelSize: CGSize, library: LibraryStore) async throws -> URL {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        let tag: String
        switch wallpaper.kind {
        case .video:
            tag = "v-\(wallpaper.id.uuidString)-\(wallpaper.video?.optimized?.fileName ?? "source")"
        case .shader:
            tag = "s-\(StableHash.hex(of: wallpaper.shader))"
        }
        let url = AppPaths.stills.appending(path: "\(tag)-\(width)x\(height).jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let image: CGImage
        switch wallpaper.kind {
        case .video:
            guard let source = library.playbackURL(for: wallpaper) else { throw ShaderError.missingSource }
            image = try await MediaInspector.frame(of: source, maxPixelSize: pixelSize, at: 0, exact: true)
        case .shader:
            guard let config = wallpaper.shader else { throw ShaderError.missingSource }
            // The desktop renderer starts its clock at 12 shader-seconds; match that frame.
            let scale = min(1, 3840 / max(pixelSize.width, 1))
            let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
            image = try MetalContext.shared.snapshot(of: config, size: size, time: 12 / max(config.params.speed, 0.01))
        }
        try MediaInspector.writeJPEG(image, to: url, quality: 0.9)
        pruneStills(keeping: url)
        return url
    }

    /// Keeps the stills folder from growing forever.
    private func pruneStills(keeping current: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: AppPaths.stills, includingPropertiesForKeys: keys) else { return }
        let inUse = Set(originals.values)
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in sorted.dropFirst(16) where file != current && !inUse.contains(file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
