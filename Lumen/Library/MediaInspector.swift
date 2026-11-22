import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum MediaError: LocalizedError {
    case notPlayable(String)
    case noVideoTrack
    case writeFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notPlayable(let ext):
            ext == "WEBM"
                ? "WebM isn't supported by macOS's video engine. Convert it to MP4 (HEVC or H.264)."
                : "This \(ext.isEmpty ? "file" : ext + " file") can't be played by macOS."
        case .noVideoTrack: "The file has no video track."
        case .writeFailed: "Couldn't write the image."
        case .exportFailed(let reason): "Optimization failed: \(reason)"
        }
    }
}

struct MediaMetadata: Sendable {
    var width: Int
    var height: Int
    var duration: Double
    var frameRate: Double
    var codec: String
    var isHDR: Bool
    var hasAudio: Bool
    var fileSize: Int64
}

enum MediaInspector {
    static let supportedTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]

    static func isVideoFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func inspect(_ url: URL) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw MediaError.notPlayable(url.pathExtension.uppercased())
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        let (size, transform, fps, formats, characteristics) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .mediaCharacteristics
        )
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let oriented = CGRect(origin: .zero, size: size).applying(transform)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0

        return MediaMetadata(
            width: Int(abs(oriented.width).rounded()),
            height: Int(abs(oriented.height).rounded()),
            duration: duration.seconds.isFinite ? duration.seconds : 0,
            frameRate: Double(fps),
            codec: formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) } ?? "Unknown",
            isHDR: characteristics.contains(.containsHDRVideo),
            hasAudio: !audioTracks.isEmpty,
            fileSize: Int64(fileSize)
        )
    }

    static func codecName(_ code: FourCharCode) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let fourCC = String(chars)
        switch fourCC {
        case "hvc1", "hev1": return "HEVC"
        case "avc1", "avc3": return "H.264"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": return "ProRes"
        default: return fourCC.trimmingCharacters(in: .whitespaces).uppercased()
        }
    }

    /// Decodes one frame. `fraction` is a position in 0...1 across the clip.
    static func frame(of url: URL, maxPixelSize: CGSize?, at fraction: Double, exact: Bool = false) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixelSize { generator.maximumSize = maxPixelSize }
        if exact {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds.isFinite ? duration.seconds * min(max(fraction, 0), 1) : 0
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw MediaError.writeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.writeFailed }
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Re-encodes a video to HEVC at the largest connected display's size.
/// HEVC decodes on the media engine at a fraction of the power of high-bitrate
/// H.264 or oversized sources, and the files are usually much smaller.
enum VideoOptimizer {
    struct Plan {
        let preset: String
        let label: String
    }

    static func plan(for video: VideoAsset, maxDisplayWidth: Int) -> Plan? {
        let alreadyEfficient = video.codec == "HEVC" && video.width <= max(maxDisplayWidth, 1920)
        guard !alreadyEfficient, video.optimized == nil else { return nil }
        let target = min(video.width, maxDisplayWidth)
        if target <= 1920 { return Plan(preset: AVAssetExportPresetHEVC1920x1080, label: "HEVC 1080p") }
        if target <= 3840 { return Plan(preset: AVAssetExportPresetHEVC3840x2160, label: "HEVC 4K") }
        return Plan(preset: AVAssetExportPresetHEVCHighestQuality, label: "HEVC")
    }

    static func export(_ source: URL, to destination: URL, preset: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaError.exportFailed("preset unavailable")
        }
        session.shouldOptimizeForNetworkUse = false
        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            throw MediaError.exportFailed(error.localizedDescription)
        }
    }
}
