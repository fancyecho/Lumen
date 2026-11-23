import AppKit
import Foundation
import ImageIO
import Observation

enum LockScreenStatus: Equatable {
    case off
    case waitingForWallpaper
    case preparing(Double)
    case installing
    case active(title: String)
    /// The followed scene or web page can't be recorded (missing files or assets); the previous Lock Screen stays.
    case keepingPrevious(title: String?)
    case failed(String)
}

/// Keeps the macOS Lock Screen (and screen saver) playing a Lumen wallpaper.
///
/// The prepared movie is installed as a custom Aerial, so it keeps playing on the
/// Lock Screen even when Lumen isn't running. Lumen re-checks the installation on
/// launch, after waking and periodically, because macOS replaces its Aerial
/// manifest when it downloads catalog updates.
@MainActor
@Observable
final class LockScreenManager {
    private(set) var status: LockScreenStatus = .off

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let engine: WallpaperEngine
    @ObservationIgnored private var state = InstalledState.load()
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false

    var isSupported: Bool { AerialSystem.isSupported }

    /// The wallpaper the Lock Screen should show: the chosen one, or the main display's.
    var sourceWallpaper: Wallpaper? {
        if let id = settings.lockScreenWallpaperID, let chosen = library.wallpaper(id: id) { return chosen }
        return engine.primaryDisplay?.wallpaperID.flatMap { library.wallpaper(id: $0) }
    }

    init(settings: AppSettings, library: LibraryStore, engine: WallpaperEngine) {
        self.settings = settings
        self.library = library
        self.engine = engine
    }

    func start() {
        guard !started else { return }
        started = true
        settings.observe { [weak self] change in
            if change == .lockScreen { self?.settingsChanged() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh(after: .seconds(5)) }
        }
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if settings.lockScreenEnabled {
            scheduleRefresh(after: .seconds(2))
        } else if state != nil {
            // Turned off while Lumen wasn't running cleanly: make sure nothing is left behind.
            disable()
        }
    }

    // MARK: Triggers

    /// The desktop wallpaper or a wallpaper's content (framing, file) changed.
    func wallpaperDidChange() {
        guard settings.lockScreenEnabled else { return }
        scheduleRefresh(after: .seconds(3))
    }

    /// Rebuilds and reinstalls even if nothing seems to have changed.
    func rebuild() {
        state?.cacheKey = ""
        refresh()
    }

    private func settingsChanged() {
        if settings.lockScreenEnabled {
            refresh()
        } else {
            disable()
        }
    }

    private func scheduleRefresh(after delay: Duration) {
        debounce?.cancel()
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Install / remove

    /// Brings the system in line with the settings: builds, installs and selects as needed.
    func refresh() {
        guard settings.lockScreenEnabled else {
            status = .off
            return
        }
        guard AerialSystem.isSupported else {
            status = .failed(AerialSystem.Failure.unsupported.localizedDescription)
            return
        }
        guard let wallpaper = sourceWallpaper else {
            status = .waitingForWallpaper
            return
        }
        guard let request = makeRequest(for: wallpaper) else {
            // A scene or page whose files are gone (or scenes without Wallpaper Engine's
            // assets): leave whatever the Lock Screen shows now rather than tearing it down.
            job?.cancel()
            status = .keepingPrevious(title: state?.title)
            return
        }
        let title = wallpaper.title

        job?.cancel()
        job = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if var current = self.state, current.cacheKey == request.cacheKey,
                   FileManager.default.fileExists(atPath: AerialSystem.videoURL(for: current.assetID).path) {
                    try await self.repairIfNeeded(&current, title: title)
                    self.state = current
                    self.status = .active(title: title)
                    return
                }

                self.status = .preparing(0)
                let movie = try await LockScreenVideoBuilder.movie(for: request) { [weak self] value in
                    Task { @MainActor in
                        guard let self, case .preparing = self.status else { return }
                        self.status = .preparing(value)
                    }
                }
                try Task.checkCancellation()

                self.status = .installing
                let thumbnail = await self.thumbnail(for: wallpaper)
                let existingBackup = self.state?.backup ?? [:]
                let previous = self.state?.assetID ?? AerialSystem.installedAssetID()
                let result = try await Task.detached(priority: .userInitiated) { () -> (String, [String: Data]) in
                    var backup = existingBackup
                    let id = try AerialSystem.install(video: movie, thumbnail: thumbnail, title: title, previousAssetID: previous)
                    try AerialSystem.select(assetID: id, backup: &backup)
                    AerialSystem.restartWallpaperAgent()
                    return (id, backup)
                }.value
                var installed = InstalledState(assetID: result.0, cacheKey: request.cacheKey, title: title, backup: result.1)
                installed.save()
                self.state = installed
                try await self.confirmSelection(&installed)
                self.status = .active(title: title)
            } catch is CancellationError {
                return
            } catch {
                Log.engine.error("Lock Screen install failed: \(error.localizedDescription, privacy: .public)")
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Puts back the user's previous Lock Screen and removes Lumen's Aerial.
    func disable() {
        job?.cancel()
        debounce?.cancel()
        let backup = state?.backup ?? [:]
        state = nil
        InstalledState.clear()
        status = .off
        Task.detached(priority: .utility) {
            try? AerialSystem.restoreSelection(from: backup)
            AerialSystem.removeFromCatalog()
            AerialSystem.restartWallpaperAgent()
        }
    }

    // MARK: Verification

    /// macOS may drop Lumen's manifest entry on catalog updates, or the user may pick
    /// another screen saver; restore what's missing without re-encoding.
    private func repairIfNeeded(_ current: inout InstalledState, title: String) async throws {
        let assetID = current.assetID
        let existingBackup = current.backup
        let changed = try await Task.detached(priority: .utility) { () -> (Bool, [String: Data]) in
            var backup = existingBackup
            var changed = false
            if AerialSystem.installedAssetID() != assetID {
                try AerialSystem.repairManifest(assetID: assetID, title: title)
                changed = true
            }
            let selected = AerialSystem.selectedIdleAssetIDs()
            if selected.isEmpty || selected.contains(where: { $0 != assetID }) {
                try AerialSystem.select(assetID: assetID, backup: &backup)
                changed = true
            }
            if changed { AerialSystem.restartWallpaperAgent() }
            return (changed, backup)
        }.value
        if changed.0 {
            current.backup = changed.1
            current.save()
            Log.engine.info("Lock Screen Aerial repaired")
        }
    }

    /// WallpaperAgent can rewrite its store while restarting; check once and reapply if needed.
    private func confirmSelection(_ installed: inout InstalledState) async throws {
        try await Task.sleep(for: .seconds(2))
        let assetID = installed.assetID
        let existingBackup = installed.backup
        let stillOurs = await Task.detached { AerialSystem.selectedIdleAssetIDs().allSatisfy { $0 == assetID } }.value
        guard !stillOurs else { return }
        let backup = try await Task.detached(priority: .userInitiated) { () -> [String: Data] in
            var backup = existingBackup
            try AerialSystem.select(assetID: assetID, backup: &backup)
            AerialSystem.restartWallpaperAgent()
            return backup
        }.value
        installed.backup = backup
        installed.save()
    }

    // MARK: Helpers

    private func makeRequest(for wallpaper: Wallpaper) -> LockScreenVideoBuilder.Request? {
        let display = NSScreen.screens.first?.pixelSize ?? CGSize(width: 3840, height: 2160)
        var scene: SceneLoopRecorder.Source?
        var web: LockScreenVideoBuilder.WebSource?
        switch wallpaper.kind {
        case .scene:
            guard let package = wallpaper.package, let folder = library.packageFolder(for: wallpaper),
                  let assets = settings.sceneAssets else { return nil }
            scene = SceneLoopRecorder.Source(folder: folder, entry: package.entry, assets: assets, values: package.resolvedValues)
        case .web:
            guard let package = wallpaper.package else { return nil }
            let source: WebRenderer.Source
            if let remote = package.remoteURL.flatMap(URL.init(string:)) {
                source = .remote(remote, id: wallpaper.id)
            } else if let folder = library.packageFolder(for: wallpaper) {
                source = .folder(folder, entry: package.entry, id: wallpaper.id)
            } else {
                return nil
            }
            web = LockScreenVideoBuilder.WebSource(source: source, properties: package.properties, values: package.resolvedValues)
        case .video, .shader:
            break
        }
        return LockScreenVideoBuilder.Request(
            wallpaperID: wallpaper.id,
            kind: wallpaper.kind,
            sourceURL: library.playbackURL(for: wallpaper),
            sourceCodec: wallpaper.video.map { $0.optimized != nil ? "HEVC" : $0.codec },
            sourceSize: wallpaper.video.map { video in
                video.optimized.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: video.width, height: video.height)
            } ?? .zero,
            shader: wallpaper.shader,
            scene: scene,
            web: web,
            framing: wallpaper.resolvedFraming,
            scaling: settings.videoScaling,
            displaySize: display
        )
    }

    private func thumbnail(for wallpaper: Wallpaper) async -> CGImage? {
        let image = await ThumbnailCache.shared.thumbnail(for: wallpaper, library: library)
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// What Lumen installed, so it can be repaired or removed later (even after a relaunch).
private struct InstalledState: Codable, Equatable {
    var assetID: String
    var cacheKey: String
    var title: String
    /// Original Lock Screen choices, keyed by their path in the wallpaper store.
    var backup: [String: Data]

    private static let key = "lockScreenInstallation"

    static func load() -> InstalledState? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(InstalledState.self, from: data)
    }

    func save() {
        if let data = try? PropertyListEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
