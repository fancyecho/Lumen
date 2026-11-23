import AVFoundation
import CoreVideo
import Foundation
import Metal

/// A looping video used as a scene texture. Frames come from the media engine as IOSurface
/// pixel buffers and are wrapped as Metal textures without copying.
final class SceneVideoTexture: @unchecked Sendable {
    let size: SIMD2<Int>
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var loopObserver: NSObjectProtocol?
    private let textureCache: CVMetalTextureCache?
    private var current: MTLTexture?
    private var currentBuffer: CVMetalTexture?
    private let lock = NSLock()

    init?(movie: Data, size: SIMD2<Int>, device: MTLDevice) {
        guard let url = Self.cachedFile(for: movie) else { return nil }
        self.size = size
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        let item = AVPlayerItem(url: url)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
        // One item that seeks back to the start keeps the video output attached.
        loopObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: nil
        ) { [weak player] _ in
            player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    deinit {
        player.pause()
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }

    func setPlaying(_ playing: Bool) {
        playing ? player.play() : player.pause()
    }

    /// The newest decoded frame, or the previous one if nothing new arrived.
    func texture() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil),
           let textureCache {
            var wrapped: CVMetalTexture?
            let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &wrapped)
            if let wrapped, let texture = CVMetalTextureGetTexture(wrapped) {
                currentBuffer = wrapped
                current = texture
            }
        }
        return current
    }

    /// AVFoundation needs a file; the movie is written once per content hash.
    private static func cachedFile(for movie: Data) -> URL? {
        let defaultCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.lumen.Lumen/SceneVideos", directoryHint: .isDirectory)
        #if DEBUG
        let caches = ProcessInfo.processInfo.environment["LUMEN_SCENE_VIDEO_CACHE"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? defaultCache
        #else
        let caches = defaultCache
        #endif
        let prefix = movie.prefix(65_536) + movie.suffix(65_536)
        let name = StableHash.hex(prefix) + "-\(movie.count).mp4"
        let url = caches.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
            try movie.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
