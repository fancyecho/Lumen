import AVFoundation
import AppKit

/// One decoder per video file, shared by every display (and every renderer) showing it.
/// Playback runs while at least one attached renderer is active.
@MainActor
final class SharedVideoPlayer {
    let url: URL
    let player = AVQueuePlayer()
    var onUnused: (() -> Void)?

    private var looper: AVPlayerLooper?
    private var clients = Set<ObjectIdentifier>()
    private var activeClients = Set<ObjectIdentifier>()

    init(url: URL, rate: Float, muted: Bool, volume: Float) {
        self.url = url
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        player.isMuted = muted
        player.volume = volume
        // A wallpaper must never keep the display awake or wait to buffer a local file.
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.defaultRate = rate
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    var isHealthy: Bool {
        player.status != .failed
            && player.currentItem?.status != .failed
            && looper?.status != .failed
    }

    func configure(rate: Float, muted: Bool, volume: Float) {
        player.defaultRate = rate
        if player.rate != 0 { player.rate = rate }
        player.isMuted = muted
        player.volume = volume
    }

    func attach(_ client: AnyObject) {
        clients.insert(ObjectIdentifier(client))
    }

    func detach(_ client: AnyObject) {
        let id = ObjectIdentifier(client)
        clients.remove(id)
        activeClients.remove(id)
        if clients.isEmpty {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            onUnused?()
        } else {
            updatePlayback()
        }
    }

    func setActive(_ active: Bool, for client: AnyObject) {
        let id = ObjectIdentifier(client)
        if active { activeClients.insert(id) } else { activeClients.remove(id) }
        updatePlayback()
    }

    private func updatePlayback() {
        if activeClients.isEmpty {
            if player.rate != 0 { player.pause() }
        } else if player.rate == 0 {
            player.play()
        }
    }
}

/// Hosts an `AVPlayerLayer` without implicit animations.
///
/// With a known `contentSize` the layer is placed by `framing` (position and zoom) and clipped;
/// otherwise it simply fills the view and relies on the layer's video gravity.
final class PlayerLayerView: NSView {
    let playerLayer: AVPlayerLayer
    var contentSize: CGSize = .zero { didSet { needsLayout = true } }
    var scaling: VideoScaling = .fill { didSet { needsLayout = true } }
    var framing: WallpaperFraming = .centered { didSet { if framing != oldValue { applyLayout() } } }

    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        applyLayout()
    }

    private func applyLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if contentSize.width > 0, contentSize.height > 0 {
            playerLayer.videoGravity = .resize
            playerLayer.frame = framing.rect(for: contentSize, in: bounds, scaling: scaling)
        } else {
            playerLayer.frame = bounds
        }
        CATransaction.commit()
    }
}

@MainActor
final class VideoRenderer: WallpaperRenderer {
    var view: NSView { layerView }

    private let shared: SharedVideoPlayer
    private let layerView: PlayerLayerView
    private var readyObservation: NSKeyValueObservation?
    private var readyHandlers: [@MainActor () -> Void] = []
    private var isReady = false
    private var isTornDown = false

    init(player: SharedVideoPlayer, scaling: VideoScaling, isHDR: Bool, contentSize: CGSize = .zero, framing: WallpaperFraming = .centered) {
        shared = player
        let layer = AVPlayerLayer(player: player.player)
        layer.videoGravity = scaling.gravity
        layer.backgroundColor = NSColor.black.cgColor
        if isHDR {
            // Only HDR sources opt into extended range; SDR stays in the cheaper path.
            layer.preferredDynamicRange = .high
        }
        layerView = PlayerLayerView(playerLayer: layer)
        layerView.contentSize = contentSize
        layerView.scaling = scaling
        layerView.framing = framing
        shared.attach(self)

        readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor in self?.markReady() }
        }
        // Never leave a display waiting if the first frame is slow to arrive.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            self?.markReady()
        }
    }

    func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if isReady { handler() } else { readyHandlers.append(handler) }
    }

    func setActive(_ active: Bool) {
        guard !isTornDown else { return }
        shared.setActive(active, for: self)
    }

    func setScaling(_ scaling: VideoScaling) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerView.playerLayer.videoGravity = scaling.gravity
        CATransaction.commit()
        layerView.scaling = scaling
    }

    func setFraming(_ framing: WallpaperFraming) {
        layerView.framing = framing
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        readyObservation = nil
        readyHandlers.removeAll()
        shared.detach(self)
        layerView.playerLayer.player = nil
        layerView.removeFromSuperview()
    }

    private func markReady() {
        guard !isReady, !isTornDown else { return }
        isReady = true
        readyObservation = nil
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }
}

extension VideoScaling {
    var gravity: AVLayerVideoGravity {
        switch self {
        case .fill: .resizeAspectFill
        case .fit: .resizeAspect
        case .stretch: .resize
        }
    }
}
