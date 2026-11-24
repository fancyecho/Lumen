import AVFoundation
import SwiftUI

/// Static thumbnail for any wallpaper, filling its frame.
struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper
    @State private var image: NSImage?

    var body: some View {
        Theme.Surface.mediaFill
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
                if reduceMotion {
                    image = loaded
                } else {
                    withAnimation(Theme.Motion.smooth) { image = loaded }
                }
            }
    }
}

/// Pre-blurred version of a wallpaper used as soft light behind hero artwork.
struct AmbientGlow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                if reduceMotion {
                    image = loaded
                } else {
                    withAnimation(Theme.Motion.backdrop) { image = loaded }
                }
            }
    }
}

/// Live, looping preview of any wallpaper (video decode or shader render).
struct LiveWallpaperPreview: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    var shaderSettings: ShaderRenderSettings = .preview
    /// Web and scene wallpapers show their animated preview unless asked to run for real.
    var rendersLive = false

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
        case .web, .scene, .native:
            if rendersLive {
                PackagePreview(wallpaper: wallpaper)
            } else if let url = model.library.previewURL(for: wallpaper) {
                AnimatedImagePreview(url: url)
            }
        }
    }
}

/// Plays a project's preview GIF (or shows its still) without decoding anything heavier.
/// Fills its frame like the thumbnail underneath, so square Workshop GIFs don't letterbox inside 16:9 cards.
struct AnimatedImagePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AspectFillImageView {
        AspectFillImageView(image: NSImage(contentsOf: url))
    }

    func updateNSView(_ view: AspectFillImageView, context: Context) {}
}

/// Plays a remote (Workshop) preview, animated GIFs included, filling its frame. Loads off the main thread.
struct RemoteAnimatedImage: NSViewRepresentable {
    let url: URL
    /// Fill (crop) by default; `false` fits the whole image inside the frame.
    var fills = true

    func makeNSView(context: Context) -> AspectFillImageView {
        let view = AspectFillImageView(image: nil, fills: fills)
        load(into: view)
        return view
    }

    func updateNSView(_ view: AspectFillImageView, context: Context) {}

    private func load(into view: AspectFillImageView) {
        Task { @MainActor [weak view] in
            guard let data = await WorkshopPreviews.data(for: url) else { return }
            view?.setImage(NSImage(data: data))
        }
    }
}

final class AspectFillImageView: NSView {
    private let imageView = NSImageView()
    private let fills: Bool

    init(image: NSImage?, fills: Bool = true) {
        self.fills = fills
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        imageView.image = image
        imageView.animates = true
        imageView.imageScaling = .scaleAxesIndependently
        addSubview(imageView)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: NSImage?) {
        imageView.image = image
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else {
            imageView.frame = bounds
            return
        }
        let scale = fills
            ? max(bounds.width / size.width, bounds.height / size.height)
            : min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

/// A live web or scene renderer in a view, for the details page.
struct PackagePreview: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.build(wallpaper, model: model, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.update(wallpaper, model: model)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.renderer?.tearDown()
        coordinator.renderer = nil
    }

    @MainActor
    final class Coordinator {
        var renderer: WallpaperRenderer?
        private var values: [String: PropertyValue] = [:]

        func build(_ wallpaper: Wallpaper, model: AppModel, in container: NSView) {
            guard let renderer = model.engine.makePreviewRenderer(for: wallpaper) else { return }
            renderer.view.frame = container.bounds
            renderer.view.autoresizingMask = [.width, .height]
            container.addSubview(renderer.view)
            renderer.setActive(true)
            values = wallpaper.package?.resolvedValues ?? [:]
            self.renderer = renderer
        }

        func update(_ wallpaper: Wallpaper, model: AppModel) {
            let newValues = wallpaper.package?.resolvedValues ?? [:]
            guard newValues != values else { return }
            values = newValues
            (renderer as? PropertyAwareRenderer)?.update(values: newValues)
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
