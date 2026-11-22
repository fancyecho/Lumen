import AVFoundation
import SwiftUI

/// Static thumbnail for any wallpaper, filling its frame.
struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var image: NSImage?

    var body: some View {
        Color.white.opacity(0.04)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .clipped()
            .task(id: ThumbnailCache.shared.cacheKey(for: wallpaper)) {
                let loaded = await ThumbnailCache.shared.thumbnail(for: wallpaper, library: model.library)
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            }
    }
}

/// Pre-blurred version of a wallpaper used as soft light behind hero artwork.
struct AmbientGlow: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                }
            }
            .task(id: ThumbnailCache.shared.cacheKey(for: wallpaper)) {
                let loaded = await ThumbnailCache.shared.backdrop(for: wallpaper, library: model.library)
                withAnimation(.easeInOut(duration: 0.6)) { image = loaded }
            }
    }
}

/// Live, looping preview of any wallpaper (video decode or shader render).
struct LiveWallpaperPreview: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    var shaderSettings: ShaderRenderSettings = .preview

    var body: some View {
        switch wallpaper.kind {
        case .video:
            if let url = model.library.playbackURL(for: wallpaper) {
                VideoPreview(url: url)
            }
        case .shader:
            if let config = wallpaper.shader {
                ShaderPreview(config: config, settings: shaderSettings)
            }
        }
    }
}

struct VideoPreview: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerLayerView {
        let layer = AVPlayerLayer()
        layer.videoGravity = gravity
        let view = PlayerLayerView(playerLayer: layer)
        context.coordinator.load(url, into: layer)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.load(url, into: view.playerLayer)
        }
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.stop()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        private(set) var url: URL?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        func load(_ url: URL, into layer: AVPlayerLayer) {
            stop()
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            layer.player = player
            player.play()
            self.player = player
        }

        func stop() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
        }
    }
}

struct ShaderPreview: NSViewRepresentable {
    let config: ShaderConfig
    var settings: ShaderRenderSettings = .preview
    var isActive = true
    var framing: WallpaperFraming = .centered

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.build(config, settings: settings, framing: framing, in: container)
        context.coordinator.renderer?.setActive(isActive)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.renderer == nil {
            coordinator.build(config, settings: settings, framing: framing, in: container)
        } else if coordinator.config != config {
            try? coordinator.renderer?.update(config: config)
            coordinator.config = config
        }
        coordinator.renderer?.update(settings: settings)
        coordinator.renderer?.setFraming(framing)
        coordinator.renderer?.setActive(isActive)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.renderer?.tearDown()
        coordinator.renderer = nil
    }

    @MainActor
    final class Coordinator {
        var renderer: ShaderRenderer?
        var config: ShaderConfig?

        func build(_ config: ShaderConfig, settings: ShaderRenderSettings, framing: WallpaperFraming, in container: NSView) {
            guard let renderer = try? ShaderRenderer(config: config, settings: settings, framing: framing) else { return }
            renderer.view.frame = container.bounds
            renderer.view.autoresizingMask = [.width, .height]
            container.addSubview(renderer.view)
            self.renderer = renderer
            self.config = config
        }
    }
}
