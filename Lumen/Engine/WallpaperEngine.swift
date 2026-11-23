import AppKit
import Foundation
import Observation

/// Owns the desktop windows, the renderers inside them, and the play/pause policy.
@MainActor
@Observable
final class WallpaperEngine {
    struct Display: Identifiable, Equatable {
        let id: String
        var name: String
        var pixelSize: CGSize
        var isBuiltin: Bool
        var isPrimary: Bool
        var wallpaperID: UUID?
        var pauseReason: PauseReason?
        /// Share of the usable desktop hidden by windows, while coverage is being watched.
        var coverage: Double?

        var isPlaying: Bool { wallpaperID != nil && pauseReason == nil }
    }

    private(set) var displays: [Display] = []
    private(set) var userPaused = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let system: SystemMonitor
    @ObservationIgnored private let occlusion = OcclusionMonitor()
    @ObservationIgnored private let stills = StillFrameSync()
    @ObservationIgnored private let pointer = DesktopPointerMonitor()
    @ObservationIgnored private var assignments = AssignmentStore.load()
    @ObservationIgnored private var hosts: [String: DesktopHost] = [:]
    @ObservationIgnored private var players: [URL: SharedVideoPlayer] = [:]
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var screenRebuildTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    init(settings: AppSettings, library: LibraryStore, system: SystemMonitor) {
        self.settings = settings
        self.library = library
        self.system = system
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        settings.observe { [weak self] change in self?.settingsChanged(change) }
        system.onChange = { [weak self] in self?.reconcile() }
        system.onWake = { [weak self] in self?.recoverAfterWake() }
        occlusion.onChange = { [weak self] in self?.reconcile() }
        pointer.onMove = { [weak self] displayID, point in
            (self?.hosts[displayID]?.renderer as? PointerAwareRenderer)?.pointerMoved(to: point)
        }
        pointer.onButton = { [weak self] displayID, isDown, point in
            (self?.hosts[displayID]?.renderer as? PointerAwareRenderer)?.pointerPressed(isDown, at: point)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleScreenRebuild() }
        }
        rebuild(animated: true)
    }

    func shutdown() {
        hosts.values.forEach { $0.setActive(false) }
    }

    // MARK: Queries

    var primaryDisplay: Display? { displays.first(where: \.isPrimary) ?? displays.first }
    var isAnyWallpaperSet: Bool { displays.contains { $0.wallpaperID != nil } }
    var isAnyPlaying: Bool { displays.contains(where: \.isPlaying) }

    /// Displays whose system Desktop entry is owned by Lock Screen's Aerial rather than `StillFrameSync`.
    func lockScreenManagedDisplayIDs() -> Set<String> {
        guard settings.lockScreenEnabled else { return [] }
        guard let primary = primaryDisplay?.id ?? NSScreen.screens.first?.displayUUID else { return [] }
        return [primary]
    }

    /// Secondary displays that currently mirror a still frame into the system Desktop entry.
    func stillFrameManagedDisplayIDs() -> Set<String> {
        guard settings.syncStillFrame else { return [] }
        return Set(hosts.keys).subtracting(lockScreenManagedDisplayIDs())
    }

    /// Reapplies still frames (or restores pre-Lumen originals) once Lock Screen finishes restoring `Index.plist`.
    func syncStillFramesAfterLockScreenDisabled() {
        guard !settings.lockScreenEnabled else { return }
        for screen in NSScreen.screens {
            let displayID = screen.displayUUID
            if settings.syncStillFrame, let id = hosts[displayID]?.wallpaperID, let wallpaper = library.wallpaper(id: id) {
                stills.sync(wallpaper, on: screen, library: library, scaling: settings.videoScaling)
            } else {
                stills.restoreOriginal(for: screen)
            }
        }
    }

    func displays(showing wallpaperID: UUID) -> [Display] {
        displays.filter { $0.wallpaperID == wallpaperID }
    }

    // MARK: Commands

    func apply(_ wallpaper: Wallpaper, to target: DisplayTarget, animated: Bool = true) {
        assignments.assign(wallpaper.id, to: target)
        assignments.save()
        rebuild(animated: animated)
    }

    func clear(_ target: DisplayTarget) {
        assignments.clear(target)
        assignments.save()
        rebuild(animated: true)
    }

    /// Call after a wallpaper's content changed (optimised file, shader edits).
    func reload(wallpaperID: UUID) {
        rebuild(animated: true, forceReload: [wallpaperID])
    }

    /// Moves/zooms every desktop showing this wallpaper, live, and refreshes its still frame.
    func updateFraming(wallpaperID: UUID) {
        guard let wallpaper = library.wallpaper(id: wallpaperID) else { return }
        let lockManaged = lockScreenManagedDisplayIDs()
        for (displayID, host) in hosts where host.wallpaperID == wallpaperID {
            host.renderer?.setFraming(wallpaper.resolvedFraming)
            if settings.syncStillFrame, !lockManaged.contains(displayID), let screen = NSScreen.screen(withUUID: displayID) {
                stills.sync(wallpaper, on: screen, library: library, scaling: settings.videoScaling, debounce: true)
            }
        }
    }

    /// Sends changed user properties to every desktop showing this wallpaper.
    func updateProperties(wallpaperID: UUID) {
        guard let values = library.wallpaper(id: wallpaperID)?.package?.resolvedValues else { return }
        for host in hosts.values where host.wallpaperID == wallpaperID {
            (host.renderer as? PropertyAwareRenderer)?.update(values: values)
        }
    }

    func forget(wallpaperID: UUID) {
        assignments.remove(wallpaperID: wallpaperID)
        assignments.save()
        rebuild(animated: true)
    }

    func toggleUserPause() {
        userPaused.toggle()
        reconcile()
    }

    // MARK: Hosts

    private func scheduleScreenRebuild() {
        screenRebuildTask?.cancel()
        screenRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.rebuild(animated: false)
        }
    }

    private func rebuild(animated: Bool, forceReload: Set<UUID> = []) {
        let screens = NSScreen.screens
        let lockManaged = lockScreenManagedDisplayIDs()
        var connected = Set<String>()

        for screen in screens {
            let displayID = screen.displayUUID
            connected.insert(displayID)
            let wallpaper = assignments.resolve(displayID).flatMap { library.wallpaper(id: $0) }

            guard let wallpaper else {
                if let host = hosts.removeValue(forKey: displayID) {
                    host.dismiss(animated: animated)
                    if !lockManaged.contains(displayID) {
                        stills.restoreOriginal(for: screen)
                    }
                }
                continue
            }

            let host = hosts[displayID] ?? {
                let created = DesktopHost(screen: screen, displayID: displayID)
                hosts[displayID] = created
                return created
            }()
            host.updateScreen(screen)

            let needsRenderer = host.renderer == nil
                || host.wallpaperID != wallpaper.id
                || forceReload.contains(wallpaper.id)
            guard needsRenderer else { continue }

            if let renderer = makeRenderer(for: wallpaper) {
                host.present(renderer, wallpaperID: wallpaper.id, animated: animated && settings.crossfade)
                if settings.syncStillFrame, !lockManaged.contains(displayID) {
                    stills.sync(wallpaper, on: screen, library: library, scaling: settings.videoScaling)
                }
            }
        }

        for (displayID, host) in hosts where !connected.contains(displayID) {
            host.dismiss(animated: false)
            hosts[displayID] = nil
        }
        reconcile()
    }

    private func makeRenderer(for wallpaper: Wallpaper) -> WallpaperRenderer? {
        switch wallpaper.kind {
        case .video:
            guard let url = library.playbackURL(for: wallpaper) else { return nil }
            let player = players[url] ?? makePlayer(for: url)
            let size = wallpaper.video.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            return VideoRenderer(
                player: player,
                scaling: settings.videoScaling,
                isHDR: wallpaper.video?.isHDR ?? false,
                contentSize: size,
                framing: wallpaper.resolvedFraming
            )
        case .shader:
            guard let config = wallpaper.shader else { return nil }
            do {
                return try ShaderRenderer(config: config, settings: settings.shaderRenderSettings, framing: wallpaper.resolvedFraming)
            } catch {
                Log.engine.error("Shader failed to build: \(error.localizedDescription, privacy: .public)")
                return nil
            }
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
            return WebRenderer(source: source, properties: package.properties, values: package.resolvedValues, settings: settings.webRenderSettings)
        case .scene:
            return makeSceneRenderer(for: wallpaper)
        }
    }

    /// A small, muted renderer for previews in the window.
    func makePreviewRenderer(for wallpaper: Wallpaper, framing: WallpaperFraming? = nil) -> WallpaperRenderer? {
        switch wallpaper.kind {
        case .web:
            guard let package = wallpaper.package else { return nil }
            var web = settings.webRenderSettings
            web.muted = true
            // Previews never start system audio capture (or its permission prompt).
            web.audioReactive = false
            let source: WebRenderer.Source
            if let remote = package.remoteURL.flatMap(URL.init(string:)) {
                source = .remote(remote, id: wallpaper.id)
            } else if let folder = library.packageFolder(for: wallpaper) {
                source = .folder(folder, entry: package.entry, id: wallpaper.id)
            } else {
                return nil
            }
            return WebRenderer(source: source, properties: package.properties, values: package.resolvedValues, settings: web)
        case .scene:
            guard let package = wallpaper.package, let folder = library.packageFolder(for: wallpaper) else { return nil }
            let source = SceneRenderer.Source(
                id: wallpaper.id, folder: folder, entry: package.entry,
                assets: settings.sceneAssets, preview: library.previewURL(for: wallpaper)
            )
            var preview = SceneRenderSettings.preview
            preview.scaling = settings.videoScaling
            return try? SceneRenderer(source: source, values: package.resolvedValues, settings: preview, framing: framing ?? wallpaper.resolvedFraming)
        default:
            return nil
        }
    }

    private func makeSceneRenderer(for wallpaper: Wallpaper) -> WallpaperRenderer? {
        guard let package = wallpaper.package, let folder = library.packageFolder(for: wallpaper) else { return nil }
        let source = SceneRenderer.Source(
            id: wallpaper.id, folder: folder, entry: package.entry,
            assets: settings.sceneAssets, preview: library.previewURL(for: wallpaper)
        )
        do {
            return try SceneRenderer(source: source, values: package.resolvedValues, settings: settings.sceneRenderSettings, framing: wallpaper.resolvedFraming)
        } catch {
            Log.engine.error("Scene renderer unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func makePlayer(for url: URL) -> SharedVideoPlayer {
        let player = SharedVideoPlayer(
            url: url,
            rate: Float(settings.playbackRate),
            muted: !settings.audioEnabled,
            volume: Float(settings.volume)
        )
        player.onUnused = { [weak self] in self?.players[url] = nil }
        players[url] = player
        return player
    }

    // MARK: Policy

    private func globalPauseReason() -> PauseReason? {
        if userPaused { return .user }
        if system.systemSleeping { return .systemSleep }
        if system.displaysAsleep { return .displayAsleep }
        if system.screenLocked { return .locked }
        if system.sessionInactive { return .sessionInactive }
        if system.screenSaverRunning { return .screenSaver }
        if settings.pauseOnLowPower && system.lowPowerMode { return .lowPower }
        if settings.pauseOnBattery && system.onBattery { return .battery }
        if settings.pauseOnThermalPressure && system.thermalPressureHigh { return .thermal }
        return nil
    }

    /// Single place that decides, per display, whether anything should be animating.
    func reconcile() {
        let global = globalPauseReason()
        occlusion.threshold = settings.coverageThreshold
        occlusion.isEnabled = settings.pauseWhenCovered && !hosts.isEmpty && global == nil

        let primaryID = NSScreen.screens.first?.displayUUID
        var updated: [Display] = []
        for screen in NSScreen.screens {
            let displayID = screen.displayUUID
            let host = hosts[displayID]
            var reason: PauseReason?
            if let host {
                reason = global
                if reason == nil, settings.pauseWhenCovered, occlusion.isCovered(displayID) {
                    reason = .covered
                }
                host.setActive(reason == nil)
            }
            updated.append(Display(
                id: displayID,
                name: screen.localizedName,
                pixelSize: screen.pixelSize,
                isBuiltin: screen.isBuiltin,
                isPrimary: displayID == primaryID,
                wallpaperID: host?.wallpaperID,
                pauseReason: reason,
                coverage: occlusion.isEnabled ? occlusion.coverage[displayID] : nil
            ))
        }
        if updated != displays { displays = updated }
        pointer.isEnabled = settings.interactiveWallpapers
            && hosts.values.contains { $0.renderer is PointerAwareRenderer }
            && updated.contains(where: \.isPlaying)
    }

    private func recoverAfterWake() {
        // Give displays a moment to come back before checking decoders.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            let broken = self.players.values.filter { !$0.isHealthy }.map(\.url)
            if !broken.isEmpty {
                Log.engine.info("Rebuilding \(broken.count) video players after wake")
                let ids = Set(self.hosts.values.compactMap(\.wallpaperID).filter { id in
                    self.library.wallpaper(id: id).flatMap { self.library.playbackURL(for: $0) }.map(broken.contains) ?? false
                })
                self.rebuild(animated: false, forceReload: ids)
            } else {
                self.reconcile()
            }
        }
    }

    private func settingsChanged(_ change: AppSettings.Change) {
        switch change {
        case .policy:
            reconcile()
        case .playback:
            for player in players.values {
                player.configure(rate: Float(settings.playbackRate), muted: !settings.audioEnabled, volume: Float(settings.volume))
            }
            let web = settings.webRenderSettings
            hosts.values.compactMap { $0.renderer as? WebRenderer }.forEach { $0.update(settings: web) }
            hosts.values.compactMap { $0.renderer as? SceneRenderer }.forEach { $0.update(settings: settings.sceneRenderSettings) }
        case .scaling:
            hosts.values.compactMap { $0.renderer as? VideoRenderer }.forEach { $0.setScaling(settings.videoScaling) }
            hosts.values.compactMap { $0.renderer as? SceneRenderer }.forEach { $0.update(settings: settings.sceneRenderSettings) }
        case .shader:
            let renderSettings = settings.shaderRenderSettings
            hosts.values.compactMap { $0.renderer as? ShaderRenderer }.forEach { $0.update(settings: renderSettings) }
            let web = settings.webRenderSettings
            hosts.values.compactMap { $0.renderer as? WebRenderer }.forEach { $0.update(settings: web) }
            hosts.values.compactMap { $0.renderer as? SceneRenderer }.forEach { $0.update(settings: settings.sceneRenderSettings) }
        case .stillFrame:
            let lockManaged = lockScreenManagedDisplayIDs()
            if settings.syncStillFrame {
                for screen in NSScreen.screens where !lockManaged.contains(screen.displayUUID) {
                    guard let id = hosts[screen.displayUUID]?.wallpaperID, let wallpaper = library.wallpaper(id: id) else { continue }
                    stills.sync(wallpaper, on: screen, library: library, scaling: settings.videoScaling)
                }
            } else {
                for screen in NSScreen.screens where !lockManaged.contains(screen.displayUUID) {
                    stills.restoreOriginal(for: screen)
                }
            }
        case .lockScreen:
            if settings.lockScreenEnabled {
                for displayID in lockScreenManagedDisplayIDs() {
                    stills.cancel(for: displayID)
                }
            }
        case .scene:
            let ids = Set(hosts.values.compactMap { host in
                host.wallpaperID.flatMap { library.wallpaper(id: $0) }.flatMap { $0.kind == .scene ? $0.id : nil }
            })
            if !ids.isEmpty { rebuild(animated: true, forceReload: ids) }
        }
    }
}
