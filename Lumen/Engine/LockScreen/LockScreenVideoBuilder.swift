import AVFoundation
import CoreVideo
import Foundation
import Metal

/// Produces the HEVC movie macOS plays on the Lock Screen.
///
/// The Lock Screen plays an Aerial once from start to end, so a short wallpaper loop is
/// repeated to an hour with an edit list: the movie references the same samples again
/// and again, so the file stays the size of a single loop.
enum LockScreenVideoBuilder {
    static let targetDuration: Double = 3600
    static let cacheFolder = AppPaths.root.appending(path: "LockScreen", directoryHint: .isDirectory)

    struct Request: Sendable {
        let wallpaperID: UUID
        let kind: WallpaperKind
        let sourceURL: URL?
        let sourceCodec: String?
        let sourceSize: CGSize
        let shader: ShaderConfig?
        let framing: WallpaperFraming
        let scaling: VideoScaling
        /// Pixel size of the main display; the movie is rendered at (or under) this size.
        let displaySize: CGSize

        var cacheKey: String {
            let parts: [String] = [
                wallpaperID.uuidString, kind.rawValue, sourceURL?.lastPathComponent ?? "",
                shader.map { StableHash.hex(of: $0) } ?? "",
                "\(framing.horizontal),\(framing.vertical),\(framing.zoom)", scaling.rawValue,
                "\(Int(displaySize.width))x\(Int(displaySize.height))",
            ]
            return StableHash.hex(Data(parts.joined(separator: "|").utf8))
        }
    }

    enum Failure: LocalizedError {
        case noVideoTrack
        case exportFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: String(localized: "The wallpaper has no video track.")
            case .exportFailed(let reason): String(localized: "Converting for the Lock Screen failed: \(reason)")
            case .writerFailed(let reason): String(localized: "Rendering for the Lock Screen failed: \(reason)")
            }
        }
    }

    /// Returns a cached movie for `request`, building it first if needed.
    static func movie(for request: Request, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        let output = cacheFolder.appending(path: "\(request.cacheKey).mov")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let workFolder = cacheFolder.appending(path: "work-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workFolder) }

        let loop: URL
        switch request.kind {
        case .video:
            guard let source = request.sourceURL else { throw Failure.noVideoTrack }
            if needsReencode(request) {
                loop = workFolder.appending(path: "loop.mov")
                try await reencode(source, request: request, to: loop) { progress($0 * 0.9) }
            } else {
                loop = source
            }
        case .shader:
            guard let shader = request.shader else { throw Failure.noVideoTrack }
            loop = workFolder.appending(path: "loop.mov")
            try await Task.detached(priority: .userInitiated) {
                try renderShaderLoop(shader, framing: request.framing, size: shaderSize(for: request.displaySize), to: loop) { progress($0 * 0.9) }
            }.value
        }

        let partial = workFolder.appending(path: "movie.mov")
        try await extend(loop, to: partial, duration: targetDuration)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        pruneCache(keeping: output)
        progress(1)
        return output
    }

    // MARK: Video

    /// HEVC at display size or below plays as-is; anything else is converted once.
    private static func needsReencode(_ request: Request) -> Bool {
        request.sourceCodec != "HEVC"
            || !request.framing.isCentered
            || request.scaling != .fill
            || request.sourceSize.width > 3840 || request.sourceSize.height > 2160
    }

    /// Converts one loop to HEVC at display size, placing the picture with the wallpaper's framing.
    private static func reencode(_ source: URL, request: Request, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let renderSize = evenSize(fitting: request.displaySize, max: CGSize(width: 3840, height: 2160))
        let track = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first
        let frameRate = try await track?.load(.nominalFrameRate) ?? 30
        do {
            try await HEVCTranscoder.transcode(source, to: destination, options: HEVCTranscoder.Options(
                renderSize: renderSize,
                bitRate: HEVCTranscoder.bitRate(for: renderSize, frameRate: Double(frameRate), sourceBitRate: nil),
                framing: request.framing,
                scaling: request.scaling,
                includeAudio: false, // the Lock Screen is silent
                fileType: .mov
            ), progress: progress)
        } catch {
            throw Failure.exportFailed(error.localizedDescription)
        }
    }

    /// Repeats the whole loop to `duration` by reference, without copying samples again.
    private static func extend(_ loop: URL, to destination: URL, duration: Double) async throws {
        let asset = AVURLAsset(url: loop, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let range = try await sourceTrack.load(.timeRange)
        guard range.duration.seconds > 0.1 else { throw Failure.noVideoTrack }

        try? FileManager.default.removeItem(at: destination)
        let movie = AVMutableMovie()
        movie.timescale = 600
        movie.defaultMediaDataStorage = AVMediaDataStorage(url: destination, options: nil)
        guard let track = movie.addMutableTrack(withMediaType: .video, copySettingsFrom: sourceTrack, options: nil) else {
            throw Failure.writerFailed("couldn't create a movie track")
        }
        try track.insertTimeRange(range, of: sourceTrack, at: .zero, copySampleData: true)
        guard let media = track.segments.first?.timeMapping.source else { throw Failure.writerFailed("empty track") }

        let target = CMTime(seconds: duration, preferredTimescale: 600)
        var cursor = range.duration
        while cursor < target {
            guard track.insertMediaTimeRange(media, into: CMTimeRange(start: cursor, duration: range.duration)) else { break }
            cursor = cursor + range.duration
        }
        try movie.writeHeader(to: destination, fileType: .mov, options: .addMovieHeaderToDestination)
    }

    // MARK: Shaders

    private static let shaderLoopSeconds = 30.0
    private static let shaderFrameRate = 30
    private static let crossfadeSeconds = 1.5

    private static func shaderSize(for display: CGSize) -> CGSize {
        // About 4 MP is plenty for soft generative scenes and keeps rendering quick.
        let budget = 4_200_000.0
        let scale = min(1, sqrt(budget / max(display.width * display.height, 1)))
        return evenSize(fitting: CGSize(width: display.width * scale, height: display.height * scale), max: CGSize(width: 3840, height: 2160))
    }

    /// Renders a seamless loop: the last 1.5 s cross-fade into the first frame.
    private static func renderShaderLoop(
        _ config: ShaderConfig,
        framing: WallpaperFraming,
        size: CGSize,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let source = config.resolvedSource
        else { throw Failure.writerFailed("Metal unavailable") }
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library = try device.makeLibrary(source: ShaderSources.header + "\n" + source, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "lumen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lumen_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let opaque = try device.makeRenderPipelineState(descriptor: descriptor)
        // Second pass blends the loop's opening frames over its ending ones.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .blendAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusBlendAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero
        let blended = try device.makeRenderPipelineState(descriptor: descriptor)

        let width = Int(size.width), height = Int(size.height)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { throw Failure.writerFailed("no texture") }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let bitRate = max(6_000_000, Int(Double(width * height * shaderFrameRate) * 0.09))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writerFailed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        var uniforms = ShaderUniforms(params: config.params)
        uniforms.resolution = SIMD2(Float(width), Float(height))
        uniforms.framing = framing.shaderVector
        let frames = Int(shaderLoopSeconds * Double(shaderFrameRate))
        let fadeStart = shaderLoopSeconds - crossfadeSeconds
        // Match the desktop renderer, whose clock starts at 12 shader-seconds.
        func shaderTime(_ seconds: Double) -> Float { Float(12 + seconds * config.params.speed) }

        for frame in 0..<frames {
            let seconds = Double(frame) / Double(shaderFrameRate)
            guard let buffer = queue.makeCommandBuffer() else { throw Failure.writerFailed("no command buffer") }
            encodePass(buffer, texture: texture, pipeline: opaque, uniforms: &uniforms, time: shaderTime(seconds), clear: true, blend: 0)
            if seconds > fadeStart {
                let weight = Float((seconds - fadeStart) / crossfadeSeconds)
                encodePass(buffer, texture: texture, pipeline: blended, uniforms: &uniforms, time: shaderTime(seconds - shaderLoopSeconds), clear: false, blend: weight)
            }
            buffer.commit()
            buffer.waitUntilCompleted()

            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writerFailed("no pixel buffer pool") }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let pixelBuffer else { throw Failure.writerFailed("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                texture.getBytes(base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(shaderFrameRate)))
            if frame % 15 == 0 { progress(Double(frame) / Double(frames)) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw Failure.writerFailed(writer.error?.localizedDescription ?? "unfinished") }
    }

    private static func encodePass(
        _ buffer: MTLCommandBuffer,
        texture: MTLTexture,
        pipeline: MTLRenderPipelineState,
        uniforms: inout ShaderUniforms,
        time: Float,
        clear: Bool,
        blend: Float
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = clear ? .clear : .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        uniforms.time = time
        encoder.setRenderPipelineState(pipeline)
        encoder.setBlendColor(red: 0, green: 0, blue: 0, alpha: blend)
        withUnsafeBytes(of: &uniforms) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    // MARK: Helpers

    private static func evenSize(fitting size: CGSize, max limit: CGSize) -> CGSize {
        let scale = min(1, limit.width / max(size.width, 1), limit.height / max(size.height, 1))
        let width = Int((size.width * scale / 2).rounded()) * 2
        let height = Int((size.height * scale / 2).rounded()) * 2
        return CGSize(width: Swift.max(2, width), height: Swift.max(2, height))
    }

    /// Keeps only the newest few movies.
    private static func pruneCache(keeping current: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: keys) else { return }
        let movies = files.filter { $0.pathExtension == "mov" }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for file in movies.dropFirst(4) where file != current {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
