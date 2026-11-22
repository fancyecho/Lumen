import AVFoundation
import VideoToolbox

/// Re-encodes a video to HEVC at an exact size and bitrate, optionally repositioning the picture.
///
/// Export-session presets pick their own (often very high) bitrate and fixed sizes, which can
/// make a "lighter" copy larger than the source. A reader/writer pipeline lets Lumen encode at
/// the display's size with a bitrate it chooses.
enum HEVCTranscoder {
    struct Options: Sendable {
        var renderSize: CGSize
        var bitRate: Int
        var framing: WallpaperFraming = .centered
        var scaling: VideoScaling = .fill
        var includeAudio = true
        var fileType: AVFileType = .mp4
    }

    /// Bitrate that keeps soft, slow wallpaper motion clean in HEVC, capped relative to the
    /// source so a re-encode never spends more bits than the original had.
    static func bitRate(for size: CGSize, frameRate: Double, sourceBitRate: Double?) -> Int {
        let fps = frameRate > 0 ? min(frameRate, 60) : 30
        var target = Double(size.width * size.height) * fps * 0.075
        target = min(target, 25_000_000)
        if let sourceBitRate, sourceBitRate > 0 { target = min(target, sourceBitRate * 0.6) }
        return Int(max(target, 2_000_000))
    }

    /// `size` scaled down (never up) to fit `limit`, with even dimensions as encoders require.
    static func evenSize(_ size: CGSize, fitting limit: CGSize) -> CGSize {
        let scale = min(1, limit.width / max(size.width, 1), limit.height / max(size.height, 1))
        let width = Int((size.width * scale / 2).rounded()) * 2
        let height = Int((size.height * scale / 2).rounded()) * 2
        return CGSize(width: max(2, width), height: max(2, height))
    }

    static func transcode(_ source: URL, to destination: URL, options: Options, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.noVideoTrack }
        let (naturalSize, transform, frameRate, timeRange) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .timeRange
        )
        let audioTrack = options.includeAudio ? try await asset.loadTracks(withMediaType: .audio).first : nil
        let audioFormat = try await audioTrack?.load(.formatDescriptions).first

        let renderSize = evenSize(options.renderSize, fitting: options.renderSize)
        let fps = Double(frameRate > 0 ? frameRate : 30)
        let composition = placementComposition(
            track: videoTrack, naturalSize: naturalSize, transform: transform, timeRange: timeRange,
            frameRate: fps, renderSize: renderSize, framing: options.framing, scaling: options.scaling
        )

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: destination, fileType: options.fileType)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: options.bitRate,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalKey: Int(fps.rounded()) * 2,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
            ] as [String: Any],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        // Audio is copied untouched when the container accepts it.
        var audioPair: (AVAssetReaderTrackOutput, AVAssetWriterInput)?
        if let audioTrack, let audioFormat {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audioPair = (output, input)
            }
        }

        guard reader.startReading() else {
            throw MediaError.exportFailed(reader.error?.localizedDescription ?? "reader")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MediaError.exportFailed(writer.error?.localizedDescription ?? "writer")
        }
        writer.startSession(atSourceTime: timeRange.start)

        let start = timeRange.start.seconds
        let duration = max(timeRange.duration.seconds, 0.001)
        let group = DispatchGroup()
        pump(videoOutput, into: videoInput, label: "video", group: group) { sample in
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            progress(min(1, max(0, (time - start) / duration)))
        }
        if let (output, input) = audioPair {
            pump(output, into: input, label: "audio", group: group) { _ in }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
        }

        if Task.isCancelled || reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw MediaError.exportFailed(reader.error?.localizedDescription ?? "read failed")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaError.exportFailed(writer.error?.localizedDescription ?? "write failed")
        }
        progress(1)
    }

    /// Composition that orients the source and places it in `renderSize` like the desktop does.
    static func placementComposition(
        track: AVAssetTrack,
        naturalSize: CGSize,
        transform: CGAffineTransform,
        timeRange: CMTimeRange,
        frameRate: Double,
        renderSize: CGSize,
        framing: WallpaperFraming,
        scaling: VideoScaling
    ) -> AVVideoComposition {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let upright = transform.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        // Video compositions use a top-left origin.
        let placement = framing.flippedRect(for: orientedSize, in: CGRect(origin: .zero, size: renderSize), scaling: scaling)
        let scale = CGAffineTransform(scaleX: placement.width / orientedSize.width, y: placement.height / orientedSize.height)
        let placed = upright.concatenating(scale).concatenating(CGAffineTransform(translationX: placement.minX, y: placement.minY))

        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(placed, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            backgroundColor: CGColor(gray: 0, alpha: 1),
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: timeRange.end)
        ))
        return AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, frameRate.rounded())))),
            instructions: [instruction],
            renderSize: renderSize
        ))
    }

    private final class Finished: @unchecked Sendable {
        var value = false
    }

    private static func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        label: String,
        group: DispatchGroup,
        onSample: @escaping @Sendable (CMSampleBuffer) -> Void
    ) {
        group.enter()
        let finished = Finished()
        let queue = DispatchQueue(label: "app.lumen.transcode.\(label)")
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData, !finished.value {
                guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                    finished.value = true
                    input.markAsFinished()
                    group.leave()
                    return
                }
                onSample(sample)
            }
        }
    }
}
