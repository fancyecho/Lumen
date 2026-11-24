import AppKit
import CoreImage
import Foundation

/// Decoded thumbnails and pre-blurred backdrops, cached in memory and on disk.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let thumbnails = NSCache<NSString, NSImage>()
    private let backdrops = NSCache<NSString, NSImage>()
    private let atmospheres = NSCache<NSString, NSImage>()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func cacheKey(for wallpaper: Wallpaper) -> String {
        switch wallpaper.kind {
        case .video: "video-\(wallpaper.id.uuidString)"
        case .shader: "shader-\(StableHash.hex(of: wallpaper.shader))"
        case .web, .scene, .native: "package-\(wallpaper.id.uuidString)"
        }
    }

    func thumbnail(for wallpaper: Wallpaper, library: LibraryStore) async -> NSImage? {
        let key = cacheKey(for: wallpaper) as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }

        var cgImage: CGImage?
        switch wallpaper.kind {
        case .video, .web, .scene, .native:
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

    /// Average linear luminance the window backdrop is pulled towards (≈ 16% grey once encoded).
    private static let atmosphereLuminance: CGFloat = 0.022
    /// Ceiling for any channel after toning (≈ 35% encoded), so no hot spot can wash out white text.
    private static let atmosphereCeiling: CGFloat = 0.10

    /// The main window's backdrop: a blurred, colour-rich echo of the artwork with its overall
    /// brightness normalised. Bright wallpapers are pulled down and dark ones lifted a little, so the
    /// room always takes the artwork's colour while white text keeps well above 7:1 contrast.
    /// Computed once per wallpaper (a 1×1 average plus one small blur), then cached.
    func atmosphere(for wallpaper: Wallpaper, library: LibraryStore) async -> NSImage? {
        let key = cacheKey(for: wallpaper) as NSString
        if let cached = atmospheres.object(forKey: key) { return cached }
        guard let thumbnail = await thumbnail(for: wallpaper, library: library),
              let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let input = CIImage(cgImage: cgImage)
        let scale = 240 / max(input.extent.width, input.extent.height, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 16)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
            .cropped(to: small.extent)

        // Core Image's working space is linear, so the gain below is a true exposure change.
        var average = [Float](repeating: 0, count: 4)
        let mean = blurred.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        ciContext.render(mean, toBitmap: &average, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let luminance = CGFloat(0.2126 * average[0] + 0.7152 * average[1] + 0.0722 * average[2])
        let gain = min(max(Self.atmosphereLuminance / max(luminance, 0.001), 0.08), 2.2)
        let ceiling = Self.atmosphereCeiling
        let toned = blurred
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            ])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMaxComponents": CIVector(x: ceiling, y: ceiling, z: ceiling, w: 1),
            ])
        guard let output = ciContext.createCGImage(toned, from: small.extent) else { return nil }
        let image = NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
        atmospheres.setObject(image, forKey: key)
        return image
    }

    func invalidate(_ wallpaper: Wallpaper) {
        let key = cacheKey(for: wallpaper) as NSString
        thumbnails.removeObject(forKey: key)
        backdrops.removeObject(forKey: key)
        atmospheres.removeObject(forKey: key)
    }
}
