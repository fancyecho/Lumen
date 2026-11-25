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
    /// Only a handful of large surfaces show posters at once; each is a few megabytes decoded.
    private let posters: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()
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
        case .video:
            guard let url = library.thumbnailURL(for: wallpaper) else { return nil }
            let source = library.playbackURL(for: wallpaper)
            cgImage = await Task.detached(priority: .utility) {
                let stored = MediaInspector.loadImage(at: url)
                // Workshop video items used to keep the item's preview image as their thumbnail, and
                // many of those are 160–256 px squares that blur on any card. A frame from the video
                // itself replaces them, once.
                guard let source, (stored.map { max($0.width, $0.height) } ?? 0) < 640,
                      let frame = try? await MediaInspector.frame(of: source, maxPixelSize: CGSize(width: 960, height: 960), at: 0.08)
                else { return stored }
                try? MediaInspector.writeJPEG(frame, to: url, quality: 0.88)
                return frame
            }.value
        case .web, .scene, .native:
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

    /// Artwork for the few large surfaces — the Home stage, the rotation stage, the menu bar panel —
    /// which show a wallpaper at up to ~1600 px, where a 960 px card thumbnail visibly softens.
    /// Rendered once from the source (a frame of the video, the shader at full size) and kept on
    /// disk. Scenes and web pages have no renderer to grab a frame from yet (T32), so they fall
    /// back to the thumbnail.
    func poster(for wallpaper: Wallpaper, library: LibraryStore) async -> NSImage? {
        let key = cacheKey(for: wallpaper) as NSString
        if let cached = posters.object(forKey: key) { return cached }

        var cgImage: CGImage?
        switch wallpaper.kind {
        case .video:
            guard !wallpaper.isBuiltin, let source = library.playbackURL(for: wallpaper) else { break }
            let file = AppPaths.folder(for: wallpaper.id).appending(path: "poster.jpg")
            let pixels = Self.posterPixels
            cgImage = await Task.detached(priority: .utility) {
                if let stored = MediaInspector.loadImage(at: file) { return stored }
                // The same moment as the card thumbnail, so the two never disagree.
                guard let frame = try? await MediaInspector.frame(of: source, maxPixelSize: CGSize(width: pixels, height: pixels), at: 0.08)
                else { return nil }
                try? MediaInspector.writeJPEG(frame, to: file, quality: 0.9)
                return frame
            }.value
        case .shader:
            let file = AppPaths.thumbnails.appending(path: "\(key)-poster.jpg")
            if FileManager.default.fileExists(atPath: file.path) {
                cgImage = await Task.detached(priority: .utility) { MediaInspector.loadImage(at: file) }.value
            } else if let config = wallpaper.shader,
                      let rendered = try? MetalContext.shared.snapshot(of: config, size: CGSize(width: 1920, height: 1080), time: 20) {
                try? MediaInspector.writeJPEG(rendered, to: file, quality: 0.9)
                cgImage = rendered
            }
        case .web, .scene, .native:
            break
        }
        guard let cgImage else { return await thumbnail(for: wallpaper, library: library) }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        posters.setObject(image, forKey: key)
        return image
    }

    /// Longest side of a poster: sharp at full width on a 2× display for the largest stage.
    nonisolated private static let posterPixels: CGFloat = 2560

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
        posters.removeObject(forKey: key)
        // An optimised (re-encoded) video gets a fresh poster from the new file.
        if wallpaper.kind == .video, !wallpaper.isBuiltin {
            try? FileManager.default.removeItem(at: AppPaths.folder(for: wallpaper.id).appending(path: "poster.jpg"))
        }
    }
}
