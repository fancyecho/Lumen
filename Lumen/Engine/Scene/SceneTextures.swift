import Foundation
import Metal
import simd

/// A texture on the GPU with what shaders need to know about it.
final class SceneTexture {
    let images: [MTLTexture]
    let format: WETexture.Format
    let flags: WETexture.Flags
    let textureSize: SIMD2<Float>
    let imageSize: SIMD2<Float>
    let frames: [WETexture.Frame]
    let sampler: MTLSamplerState
    /// Set for video and text textures; `images` then holds a placeholder until it's ready.
    let video: DynamicTexture?

    init(images: [MTLTexture], decoded: WETexture, sampler: MTLSamplerState, video: DynamicTexture? = nil) {
        self.images = images
        self.video = video
        format = decoded.format
        flags = decoded.flags
        textureSize = SIMD2(Float(decoded.textureSize.x), Float(decoded.textureSize.y))
        imageSize = SIMD2(Float(decoded.imageSize.x), Float(decoded.imageSize.y))
        frames = decoded.frames
        self.sampler = sampler
    }

    init(texture: MTLTexture, sampler: MTLSamplerState, dynamic: DynamicTexture? = nil) {
        images = [texture]
        video = dynamic
        format = .rgba8888
        flags = []
        textureSize = SIMD2(Float(texture.width), Float(texture.height))
        imageSize = textureSize
        frames = []
        self.sampler = sampler
    }

    var texture: MTLTexture { video?.texture() ?? images[0] }
    var resolution: SIMD4<Float> { SIMD4(lowHalf: textureSize, highHalf: imageSize) }
    /// Share of the texture the picture covers (textures are padded to block sizes).
    var imageExtent: SIMD2<Float> { imageSize / max(textureSize, SIMD2(1, 1)) }
    var isAnimated: Bool { frames.count > 1 }

    /// The sprite-sheet frame at `time`, looping.
    func frame(at time: Float) -> WETexture.Frame? {
        guard isAnimated else { return frames.first }
        let total = frames.reduce(Float(0)) { $0 + max($1.duration, 0.001) }
        var t = time.truncatingRemainder(dividingBy: max(total, 0.001))
        for frame in frames {
            t -= max(frame.duration, 0.001)
            if t <= 0 { return frame }
        }
        return frames.last
    }
}

/// Loads `.tex` files once per scene and uploads them to private GPU memory.
final class SceneTextureCache: @unchecked Sendable {
    let device: MTLDevice
    let files: SceneFileSystem
    let maxDimension: Int
    /// Share of full texture resolution worth keeping (see `WETexture.decode`).
    let detail: Float
    let samplers: SceneSamplers
    private var cache: [String: SceneTexture?] = [:]
    private var pending: [String: DispatchGroup] = [:]
    private let lock = NSLock()
    private var uploads: [(MTLBuffer, MTLTexture, Int, Int, Int, Int)] = []
    private var needsMipmaps: [MTLTexture] = []

    /// Every video texture the scene loaded, for pausing them with the scene.
    var videoTextures: [DynamicTexture] {
        lock.lock()
        defer { lock.unlock() }
        return cache.values.compactMap { $0?.video }
    }

    lazy var white: SceneTexture = solid(SIMD4(255, 255, 255, 255))
    lazy var black: SceneTexture = solid(SIMD4(0, 0, 0, 255))
    lazy var clear: SceneTexture = solid(SIMD4(0, 0, 0, 0))

    init(device: MTLDevice, files: SceneFileSystem, maxDimension: Int = 8192, detail: Float = 1) {
        self.device = device
        self.files = files
        self.maxDimension = maxDimension
        self.detail = detail
        samplers = SceneSamplers(device: device)
    }

    /// `name` as materials write it ("masks/foo", "util/black"), without `materials/` or `.tex`.
    func texture(named name: String) -> SceneTexture? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        if let loading = pending[name] {
            lock.unlock()
            loading.wait()
            return texture(named: name)
        }
        let group = DispatchGroup()
        group.enter()
        pending[name] = group
        lock.unlock()
        let loaded = load(name)
        lock.lock()
        cache[name] = loaded
        pending[name] = nil
        lock.unlock()
        group.leave()
        return loaded
    }

    private func load(_ name: String) -> SceneTexture? {
        var candidates = ["materials/\(name).tex"]
        if name.hasSuffix(".tex") { candidates.insert(name, at: 0) }
        guard let data = candidates.lazy.compactMap({ self.files.data($0) }).first else {
            switch name {
            case "util/white": return white
            case "util/black": return black
            default:
                Log.engine.info("Scene texture missing: \(name, privacy: .public)")
                return nil
            }
        }
        do {
            let decoded = try WETexture.decode(data, maxDimension: maxDimension, detail: detail)
            if let movie = decoded.video {
                let size = SIMD2(max(decoded.textureSize.x, 1), max(decoded.textureSize.y, 1))
                guard let video = SceneVideoTexture(movie: movie, size: size, device: device) else { return nil }
                let sampler = samplers.state(nearest: false, clamp: decoded.flags.contains(.clampUVs))
                return SceneTexture(images: [clear.texture], decoded: decoded, sampler: sampler, video: video)
            }
            var images: [MTLTexture] = []
            for mips in decoded.images {
                guard let texture = upload(mips, format: decoded.format) else { return nil }
                images.append(texture)
            }
            guard !images.isEmpty else { return nil }
            let sampler = samplers.state(nearest: decoded.flags.contains(.noInterpolation), clamp: decoded.flags.contains(.clampUVs))
            return SceneTexture(images: images, decoded: decoded, sampler: sampler)
        } catch {
            Log.engine.error("Scene texture \(name, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func upload(_ mips: [WETexture.Mip], format: WETexture.Format) -> MTLTexture? {
        guard let first = mips.first else { return nil }
        let generate = mips.count == 1 && !format.isBlockCompressed && max(first.width, first.height) > 64
        let levelCount = generate ? Int(log2(Double(max(first.width, first.height)))) + 1 : mips.count
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format.pixelFormat, width: first.width, height: first.height, mipmapped: levelCount > 1
        )
        descriptor.mipmapLevelCount = levelCount
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        for (level, mip) in mips.enumerated() where level < levelCount {
            let bytes = format.byteCount(width: mip.width, height: mip.height)
            guard let buffer = mip.data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared) }) else { continue }
            lock.lock()
            uploads.append((buffer, texture, level, mip.width, mip.height, format.bytesPerRow(width: mip.width)))
            lock.unlock()
        }
        if generate {
            lock.lock()
            needsMipmaps.append(texture)
            lock.unlock()
        }
        return texture
    }

    private func solid(_ rgba: SIMD4<UInt8>) -> SceneTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        var pixel = rgba
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return SceneTexture(texture: texture, sampler: samplers.state(nearest: false, clamp: false))
    }

    /// Copies everything loaded so far to the GPU (and builds mipmaps) in one command buffer.
    func flushUploads(queue: MTLCommandQueue) {
        lock.lock()
        let pending = uploads
        let mipmaps = needsMipmaps
        uploads.removeAll()
        needsMipmaps.removeAll()
        lock.unlock()
        guard !pending.isEmpty || !mipmaps.isEmpty, let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return }
        for (source, texture, level, width, height, bytesPerRow) in pending {
            let blockRows = texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rg8Unorm || texture.pixelFormat == .r8Unorm
                ? height : max(1, (height + 3) / 4)
            blit.copy(
                from: source, sourceOffset: 0, sourceBytesPerRow: bytesPerRow, sourceBytesPerImage: bytesPerRow * blockRows,
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: texture, destinationSlice: 0, destinationLevel: level, destinationOrigin: MTLOrigin()
            )
        }
        for texture in mipmaps { blit.generateMipmaps(for: texture) }
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}

/// The four sampler states Wallpaper Engine textures need.
final class SceneSamplers: @unchecked Sendable {
    private let states: [MTLSamplerState]

    init(device: MTLDevice) {
        var states: [MTLSamplerState] = []
        for nearest in [false, true] {
            for clamp in [false, true] {
                let descriptor = MTLSamplerDescriptor()
                descriptor.minFilter = nearest ? .nearest : .linear
                descriptor.magFilter = nearest ? .nearest : .linear
                descriptor.mipFilter = nearest ? .notMipmapped : .linear
                descriptor.sAddressMode = clamp ? .clampToEdge : .repeat
                descriptor.tAddressMode = clamp ? .clampToEdge : .repeat
                descriptor.maxAnisotropy = nearest ? 1 : 4
                states.append(device.makeSamplerState(descriptor: descriptor)!)
            }
        }
        self.states = states
    }

    func state(nearest: Bool, clamp: Bool) -> MTLSamplerState {
        states[(nearest ? 2 : 0) + (clamp ? 1 : 0)]
    }
}
