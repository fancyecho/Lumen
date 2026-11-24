import AppKit
import Observation
import SwiftUI
import WebKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}

/// Composition root: owns every store and exposes the user-facing actions.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings()
    let library = LibraryStore()
    let system = SystemMonitor()
    let router = Router()
    let engine: WallpaperEngine
    let playlists: PlaylistStore
    let lockScreen: LockScreenManager
    let workshop = WorkshopLibrary()
    let steam: SteamWorkshop
    /// Steam Workshop browsing state; lives here so results survive switching tabs.
    let workshopBrowser = WorkshopBrowser()

    var isImporterPresented = false
    var isWebPageSheetPresented = false
    var isSteamPanelPresented = false
    var pendingDeletion: Wallpaper?
    private(set) var toast: Toast?

    @ObservationIgnored var launchedAsLoginItem = false
    @ObservationIgnored private var started = false

    private init() {
        engine = WallpaperEngine(settings: settings, library: library, system: system)
        playlists = PlaylistStore(library: library)
        lockScreen = LockScreenManager(settings: settings, library: library, engine: engine)
        steam = SteamWorkshop(library: library)
        playlists.applyHandler = { [weak self] wallpaper in
            self?.engine.apply(wallpaper, to: .allDisplays, animated: true)
            self?.lockScreen.wallpaperDidChange()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        AppPaths.prepare()
        library.load()
        system.start()
        engine.start()
        playlists.start()
        lockScreen.start()
        #if DEBUG
        openDebugRoute()
        #endif
    }

    #if DEBUG
    /// `-LumenDebugRoute wallpaper:<uuid>` (or `studio:`, `playlists`, `studio`) opens a page at launch,
    /// for screenshots and UI checks without clicking through.
    private func openDebugRoute() {
        // `-LumenDebugImport <folder,folder>` imports projects; `-LumenDebugApply <title>` then
        // shows one on every display without touching the lock screen. For testing only.
        if let folders = UserDefaults.standard.string(forKey: "LumenDebugImport") {
            let urls = folders.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            Task {
                _ = await library.importFiles(urls, source: "wallpapermachine")
                if let title = UserDefaults.standard.string(forKey: "LumenDebugApply"),
                   let wallpaper = library.items.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
                    engine.apply(wallpaper, to: .allDisplays)
                }
            }
        } else if let title = UserDefaults.standard.string(forKey: "LumenDebugApply"),
                  let wallpaper = library.items.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
            engine.apply(wallpaper, to: .allDisplays)
        }
        if UserDefaults.standard.bool(forKey: "LumenDebugSteam") { isSteamPanelPresented = true }
        // `-LumenDebugDelete <uuid>` removes a wallpaper a test added, through the normal delete path.
        if let id = UserDefaults.standard.string(forKey: "LumenDebugDelete").flatMap(UUID.init(uuidString:)),
           let wallpaper = library.wallpaper(id: id) {
            delete(wallpaper)
        }
        guard let raw = UserDefaults.standard.string(forKey: "LumenDebugRoute") else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let id = UUID(uuidString: parts[1]) {
            switch parts[0] {
            case "wallpaper": router.open(.wallpaper(id))
            case "studio": router.open(.studio(id))
            case "playlist": router.open(.playlist(id))
            default: break
            }
        } else if let tab = AppTab(rawValue: raw) {
            router.show(tab)
        }
    }
    #endif

    func shutdown() {
        engine.shutdown()
    }

    // MARK: Actions

    func setWallpaper(_ wallpaper: Wallpaper, on target: DisplayTarget) {
        playlists.stop()
        engine.apply(wallpaper, to: target)
        lockScreen.wallpaperDidChange()
        showToast(String(localized: "“\(wallpaper.title)” is on \(label(for: target))"), symbol: "checkmark.circle.fill")
    }

    func clearWallpaper(on target: DisplayTarget) {
        playlists.stop()
        engine.clear(target)
        lockScreen.wallpaperDidChange()
    }

    /// Moves/zooms a wallpaper everywhere it's shown, live.
    func setFraming(_ framing: WallpaperFraming, for wallpaperID: UUID) {
        library.setFraming(framing, for: wallpaperID)
        engine.updateFraming(wallpaperID: wallpaperID)
        lockScreen.wallpaperDidChange()
    }

    /// Changes a web or scene wallpaper's user property everywhere it's shown, live.
    func setProperty(_ value: PropertyValue?, key: String, for wallpaperID: UUID) {
        library.setPropertyValue(value, key: key, for: wallpaperID)
        engine.updateProperties(wallpaperID: wallpaperID)
    }

    func resetProperties(for wallpaperID: UUID) {
        library.resetProperties(for: wallpaperID)
        engine.updateProperties(wallpaperID: wallpaperID)
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await library.importFiles(urls)
            if let failure = result.failures.first, result.added.isEmpty {
                showToast("\(failure.name): \(failure.reason)", symbol: "exclamationmark.triangle.fill")
            } else if !result.added.isEmpty {
                let count = result.added.count
                var message = count == 1
                    ? String(localized: "Added “\(result.added[0].title)”")
                    : String(localized: "Added \(count) wallpapers")
                if !result.failures.isEmpty {
                    message += String(localized: " · \(result.failures.count) skipped")
                }
                showToast(message, symbol: "square.and.arrow.down.fill")
            }
        }
    }

    /// Adds Wallpaper Engine projects found by the Workshop page.
    func importWorkshop(_ projects: [DiscoveredProject]) {
        guard !projects.isEmpty else { return }
        Task {
            var added = 0
            var failures: [(name: String, reason: String)] = []
            for (kind, group) in Dictionary(grouping: projects, by: \.source) {
                let source = WorkshopSource(url: URL(fileURLWithPath: "/"), kind: kind).importSource
                let result = await library.importFiles(group.map(\.folder), source: source)
                added += result.added.count
                failures += result.failures
            }
            if added == 0, let failure = failures.first {
                showToast("\(failure.name): \(failure.reason)", symbol: "exclamationmark.triangle.fill")
            } else if added > 0 {
                var message = added == 1 ? String(localized: "Added 1 wallpaper") : String(localized: "Added \(added) wallpapers")
                if !failures.isEmpty { message += String(localized: " · \(failures.count) skipped") }
                showToast(message, symbol: "square.and.arrow.down.fill")
            }
        }
    }

    func addWebPage(_ url: URL, title: String?) {
        do {
            let wallpaper = try library.addWebPage(url, title: title)
            showToast(String(localized: "Added “\(wallpaper.title)”"), symbol: "globe")
        } catch {
            showToast(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
        }
    }

    func delete(_ wallpaper: Wallpaper) {
        guard !wallpaper.isBuiltin else { return }
        engine.forget(wallpaperID: wallpaper.id)
        playlists.removeWallpaper(wallpaper.id)
        ThumbnailCache.shared.invalidate(wallpaper)
        library.delete(wallpaper.id)
        if wallpaper.kind == .web {
            // Each web wallpaper had its own cookies and storage; remove them with it.
            WKWebsiteDataStore.remove(forIdentifier: wallpaper.id) { _ in }
        }
        if router.route == .wallpaper(wallpaper.id) || router.route == .studio(wallpaper.id) { router.back() }
        showToast(String(localized: "Deleted “\(wallpaper.title)”"), symbol: "trash.fill")
    }

    func optimize(_ wallpaper: Wallpaper) {
        let maxWidth = NSScreen.screens.map { Int($0.pixelSize.width) }.max() ?? 3840
        Task {
            do {
                switch try await library.optimize(wallpaper.id, maxDisplayWidth: maxWidth) {
                case .optimized(let saved):
                    ThumbnailCache.shared.invalidate(wallpaper)
                    engine.reload(wallpaperID: wallpaper.id)
                    lockScreen.wallpaperDidChange()
                    showToast(String(localized: "Optimized “\(wallpaper.title)” · saved \(Format.bytes(saved))"), symbol: "bolt.fill")
                case .keptOriginal:
                    showToast(String(localized: "“\(wallpaper.title)” is already compact, so Lumen kept the original"), symbol: "checkmark.seal.fill")
                case .notNeeded:
                    break
                }
            } catch {
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    func revealInFinder(_ wallpaper: Wallpaper) {
        guard let url = library.sourceURL(for: wallpaper) ?? library.packageFolder(for: wallpaper) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func label(for target: DisplayTarget) -> String {
        switch target {
        case .allDisplays:
            return engine.displays.count > 1 ? String(localized: "all displays") : String(localized: "your desktop")
        case .display(let id):
            return engine.displays.first { $0.id == id }?.name ?? String(localized: "that display")
        }
    }

    func showToast(_ message: String, symbol: String) {
        let toast = Toast(message: message, symbol: symbol)
        withAnimation(.snappy) { self.toast = toast }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.8))
            if self.toast?.id == toast.id {
                withAnimation(.smooth) { self.toast = nil }
            }
        }
    }
}
