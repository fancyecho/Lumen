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
            if ext == "WEBM" {
                String(localized: "WebM isn't supported by macOS's video engine. Convert it to MP4 (HEVC or H.264).")
            } else if ext.isEmpty {
                String(localized: "macOS can't play this file.")
            } else {
                String(localized: "macOS can't play this \(ext) file.")
            }
        case .noVideoTrack: String(localized: "The file has no video track.")
        case .writeFailed: String(localized: "Couldn't write the image.")
        case .exportFailed(let reason): String(localized: "Optimization failed: \(reason)")
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

/// Plans and runs "Optimize for this Mac": an HEVC copy at the largest display's size.
/// Smaller frames and a sensible bitrate mean less work for the media engine and a smaller
/// file. A copy that doesn't come out clearly smaller is thrown away.
enum VideoOptimizer {
    struct Plan {
        let renderSize: CGSize
        let bitRate: Int
        let label: String
    }

    /// The optimised copy must be at least this much smaller than the source to be kept.
    static let requiredSaving = 0.9

    static func plan(for video: VideoAsset, maxDisplayWidth: Int) -> Plan? {
        guard video.optimized == nil, video.optimizationDeclined != true, !video.isHDR,
              video.width > 0, video.height > 0
        else { return nil }
        let alreadyEfficient = video.codec == "HEVC" && video.width <= max(maxDisplayWidth, 1920)
        guard !alreadyEfficient else { return nil }

        let source = CGSize(width: video.width, height: video.height)
        let size = HEVCTranscoder.evenSize(source, fitting: CGSize(width: CGFloat(max(maxDisplayWidth, 1280)), height: .greatestFiniteMagnitude))
        let sourceBitRate = video.duration > 0 ? Double(video.fileSize) * 8 / video.duration : nil
        let bitRate = HEVCTranscoder.bitRate(for: size, frameRate: video.frameRate, sourceBitRate: sourceBitRate)
        return Plan(renderSize: size, bitRate: bitRate, label: "HEVC \(Int(size.width))×\(Int(size.height))")
    }

    static func export(_ source: URL, to destination: URL, plan: Plan, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await HEVCTranscoder.transcode(
            source, to: destination,
            options: HEVCTranscoder.Options(renderSize: plan.renderSize, bitRate: plan.bitRate, scaling: .fit),
            progress: progress
        )
    }
}
