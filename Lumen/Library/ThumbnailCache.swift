import AppKit
import CoreImage
import Foundation

/// Decoded thumbnails and pre-blurred backdrops, cached in memory and on disk.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let thumbnails = NSCache<NSString, NSImage>()
    private let backdrops = NSCache<NSString, NSImage>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func cacheKey(for wallpaper: Wallpaper) -> String {
        switch wallpaper.kind {
        case .video: "video-\(wallpaper.id.uuidString)"
        case .shader: "shader-\(StableHash.hex(of: wallpaper.shader))"
        }
    }

    func thumbnail(for wallpaper: Wallpaper, library: LibraryStore) async -> NSImage? {
        let key = cacheKey(for: wallpaper) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }

        var cgImage: CGImage?
        switch wallpaper.kind {
        case .video:
            guard let url = library.thumbnailURL(for: wallpaper) else { return nil }
            cgImage = await Task.detached(priority: .utility) { MediaInspector.loadImage(at: url) }.value
        case .shader:
            let file = AppPaths.thumbnails.appending(path: "\(key).jpg")
            if FileManager.default.fileExists(atPath: file.path) {
                cgImage = await Task.detached(priority: .utility) { MediaInspector.loadImage(at: file) }.value
            } else if let config = wallpaper.shader,
                      let rendered = try? MetalContext.shared.snapshot(of: config, size: CGSize(width: 960, height: 540), time: 20) {
                try? MediaInspector.writeJPEG(rendered, to: file, quality: 0.88)
                cgImage = rendered
            }
        }
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnails.setObject(image, forKey: key)
        return image
    }

    /// A small, heavily blurred and saturated version of the thumbnail used as ambient light.
    func backdrop(for wallpaper: Wallpaper, library: LibraryStore) async -> NSImage? {
        let key = cacheKey(for: wallpaper) as NSString
        if let cached = backdrops.object(forKey: key) { return cached }
        guard let thumbnail = await thumbnail(for: wallpaper, library: library),
              let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let input = CIImage(cgImage: cgImage)
        let scale = 320 / max(input.extent.width, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 22)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35,
                kCIInputBrightnessKey: -0.04,
            ])
            .cropped(to: small.extent)
        guard let output = ciContext.createCGImage(blurred, from: small.extent) else { return nil }
        let image = NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
        backdrops.setObject(image, forKey: key)
        return image
    }

    func invalidate(_ wallpaper: Wallpaper) {
        let key = cacheKey(for: wallpaper) as NSString
        thumbnails.removeObject(forKey: key)
        backdrops.removeObject(forKey: key)
    }
}
