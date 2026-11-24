import AppKit
import AVFoundation
import CoreVideo
import Foundation
import Metal

/// Writes BGRA Metal frames into an HEVC movie for the Lock Screen.
final class LoopVideoWriter {
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(url: URL, width: Int, height: Int, frameRate: Int) throws {
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let bitRate = max(6_000_000, Int(Double(width * height * frameRate) * 0.09))
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw LockScreenVideoBuilder.Failure.writerFailed(writer.error?.localizedDescription ?? "writer")
        }
        writer.startSession(atSourceTime: .zero)
    }

    /// Appends a finished frame from a CPU-readable BGRA texture of the writer's size.
    func append(_ texture: MTLTexture, at time: CMTime) throws {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        guard let pool = adaptor.pixelBufferPool else { throw LockScreenVideoBuilder.Failure.writerFailed("no pixel buffer pool") }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw LockScreenVideoBuilder.Failure.writerFailed("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            texture.getBytes(base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    /// Appends a picture, optionally dissolving `overlay` over it by `overlayAlpha`.
    func append(_ image: CGImage, overlay: CGImage? = nil, overlayAlpha: CGFloat = 0, at time: CMTime) throws {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        guard let pool = adaptor.pixelBufferPool else { throw LockScreenVideoBuilder.Failure.writerFailed("no pixel buffer pool") }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw LockScreenVideoBuilder.Failure.writerFailed("no pixel buffer") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw LockScreenVideoBuilder.Failure.writerFailed("no drawing context") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        if let overlay, overlayAlpha > 0 {
            context.setAlpha(overlayAlpha)
            context.draw(overlay, in: rect)
        }
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    func finish() throws {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw LockScreenVideoBuilder.Failure.writerFailed(writer.error?.localizedDescription ?? "unfinished")
        }
    }
}

/// Records a Wallpaper Engine scene offscreen into a seamless loop for the Lock Screen.
enum SceneLoopRecorder {
    struct Source: Sendable {
        let folder: URL
        let entry: String
        let assets: URL?
        let values: [String: PropertyValue]
    }

    static let loopSeconds = 30.0
    static let frameRate = 30
    /// Intros, particle systems and scripts settle before recording starts.
    static let warmUpSeconds = 3.0
    /// The loop's end dissolves into its first frame, so the hour-long repeat has no jump.
    static let crossfadeSeconds = 1.5

    static func record(
        _ source: Source,
        framing: WallpaperFraming,
        scaling: VideoScaling,
        size: CGSize,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw LockScreenVideoBuilder.Failure.writerFailed("Metal unavailable")
        }
        let width = Int(size.width), height = Int(size.height)
        let instance = try SceneLoader.load(SceneLoader.Request(
            folder: source.folder, entry: source.entry, assets: source.assets, values: source.values,
            displaySize: SIMD2(Float(width), Float(height)), pixelBudget: Double(width * height),
            device: device, queue: queue
        ))
        let utility = try SceneUtilityPipelines.shared(device: device)
        let fade = try fadePipeline(device: device)

        let target = try makeTexture(device, width, height, usage: [.renderTarget, .shaderRead], shared: true)
        let firstFrame = try makeTexture(device, width, height, usage: [.renderTarget, .shaderRead], shared: false)

        // Place the scene as the desktop does (framing and scaling).
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let placed = framing.rect(for: CGSize(width: CGFloat(instance.canvas.x), height: CGFloat(instance.canvas.y)), in: bounds, scaling: scaling)
        var presentRect = SIMD4<Float>(
            Float(placed.minX / bounds.width * 2 - 1), Float(placed.minY / bounds.height * 2 - 1),
            Float(placed.width / bounds.width * 2), Float(placed.height / bounds.height * 2)
        )
        let upscaling = Float(placed.width) > Float(instance.outputTexture.width) * 1.04
        let present = upscaling ? utility.presentSharp : utility.present
        let sampler = instance.textures.samplers.state(nearest: false, clamp: true)

        // Video textures follow the wall clock, so their scenes are recorded in real time;
        // everything else renders as fast as the GPU allows. Sounds stay silent.
        let videos = instance.textures.videoTextures
        videos.forEach { $0.setPlaying(true) }
        defer { videos.forEach { $0.setPlaying(false) } }
        let realTime = !videos.isEmpty

        let writer = try LoopVideoWriter(url: destination, width: width, height: height, frameRate: frameRate)
        let delta = 1 / Float(frameRate)
        let warmUpFrames = Int(warmUpSeconds * Double(frameRate))
        let loopFrames = Int(loopSeconds * Double(frameRate))
        let fadeStart = loopFrames - Int(crossfadeSeconds * Double(frameRate))
        let started = Date()
        let daytime: Float = {
            let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
            return Float((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) * 60 + (parts.second ?? 0)) / 86400
        }()

        for frame in 0..<(warmUpFrames + loopFrames) {
            try Task.checkCancellation()
            if realTime {
                let due = started.addingTimeInterval(Double(frame) / Double(frameRate))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            guard let buffer = queue.makeCommandBuffer() else { throw LockScreenVideoBuilder.Failure.writerFailed("no command buffer") }
            instance.encode(into: buffer, frame: SceneInstance.Frame(
                time: Float(frame) * delta, delta: delta, pointerCanvas: nil, daytime: daytime,
                pointer: SIMD2(0.5, 0.5), pointerLast: SIMD2(0.5, 0.5), cameraOffset: .zero, parallax: SIMD2(0.5, 0.5)
            ))
            let recorded = frame - warmUpFrames
            guard recorded >= 0 else {
                buffer.commit()
                continue
            }
            draw(instance.outputTexture, into: target, pipeline: present, rect: &presentRect, sampler: sampler, buffer: buffer, clear: true, alpha: 1)
            if recorded == 0, let blit = buffer.makeBlitCommandEncoder() {
                blit.copy(from: target, to: firstFrame)
                blit.endEncoding()
            } else if recorded >= fadeStart {
                var full = SIMD4<Float>(-1, -1, 2, 2)
                let weight = Float(recorded - fadeStart + 1) / Float(loopFrames - fadeStart)
                draw(firstFrame, into: target, pipeline: fade, rect: &full, sampler: sampler, buffer: buffer, clear: false, alpha: weight)
            }
            buffer.commit()
            buffer.waitUntilCompleted()
            try writer.append(target, at: CMTime(value: CMTimeValue(recorded), timescale: CMTimeScale(frameRate)))
            if recorded % 15 == 0 { progress(Double(recorded) / Double(loopFrames)) }
        }
        try writer.finish()
    }

    static func draw(_ texture: MTLTexture, into target: MTLTexture, pipeline: MTLRenderPipelineState, rect: inout SIMD4<Float>,
                             sampler: MTLSamplerState, buffer: MTLCommandBuffer, clear: Bool, alpha: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setBlendColor(red: 0, green: 0, blue: 0, alpha: alpha)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// The present pass with constant-alpha blending, for dissolving into the first frame.
    static func fadePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: SceneUtilityPipelines.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "lumen_scene_present_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lumen_scene_present_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .blendAlpha
        attachment.destinationRGBBlendFactor = .oneMinusBlendAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .zero
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeTexture(_ device: MTLDevice, _ width: Int, _ height: Int, usage: MTLTextureUsage, shared: Bool) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = shared ? .shared : .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LockScreenVideoBuilder.Failure.writerFailed("no texture") }
        return texture
    }
}

/// Records a web wallpaper for the Lock Screen by snapshotting the page in real time.
/// WebKit draws in another process, so frames come from snapshots (often 10–30 a second);
/// each is stamped with when it was taken, so motion keeps its speed.
@MainActor
enum WebLoopRecorder {
    static let loopSeconds = 12.0
    static let warmUpSeconds = 3.0
    static let crossfadeSeconds = 1.0

    static func record(
        _ source: WebRenderer.Source,
        properties: [WEProperty],
        values: [String: PropertyValue],
        size: CGSize,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let width = Int(size.width), height = Int(size.height)
        let renderer = WebRenderer(source: source, properties: properties, values: values,
                                   settings: WebRenderSettings(frameRate: 30, muted: true, volume: 0, audioReactive: false))
        // Window sizes are in points; snapshots come back at the screen's backing scale.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: CGFloat(width) / scale, height: CGFloat(height) / scale),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = renderer.view
        renderer.keepRenderingWhenOccluded()
        window.orderBack(nil)
        defer {
            renderer.tearDown()
            window.orderOut(nil)
            window.contentView = nil
        }
        await withCheckedContinuation { continuation in
            renderer.whenReady { continuation.resume() }
        }
        renderer.setActive(true)
        try await Task.sleep(for: .seconds(warmUpSeconds))

        let writer = try LoopVideoWriter(url: destination, width: width, height: height, frameRate: 30)
        let start = Date()
        var first: CGImage?
        var frames = 0
        while true {
            try Task.checkCancellation()
            let elapsed = Date().timeIntervalSince(start)
            guard elapsed < loopSeconds else { break }
            guard let image = await renderer.snapshot() else {
                try await Task.sleep(for: .milliseconds(30))
                continue
            }
            if first == nil { first = image }
            let fade = max(0, (elapsed - (loopSeconds - crossfadeSeconds)) / crossfadeSeconds)
            try writer.append(image, overlay: first, overlayAlpha: CGFloat(min(fade, 1)), at: CMTime(seconds: elapsed, preferredTimescale: 600))
            frames += 1
            progress(elapsed / loopSeconds)
            // At most ~30 snapshots a second.
            let next = start.addingTimeInterval(Double(frames) / 30)
            if next.timeIntervalSinceNow > 0 { try await Task.sleep(for: .seconds(next.timeIntervalSinceNow)) }
        }
        // End the loop on its first frame so the repeat is seamless.
        if let first { try writer.append(first, at: CMTime(seconds: loopSeconds, preferredTimescale: 600)) }
        try writer.finish()
        Log.engine.info("Recorded web loop: \(frames) frames in \(Int(loopSeconds)) s")
    }
}
