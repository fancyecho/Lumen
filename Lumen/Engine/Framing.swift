import CoreGraphics
import Foundation

/// Where a wallpaper sits on the display: which part shows when it's cropped, plus extra zoom.
///
/// Offsets are normalised so one setting works on displays of any shape:
/// -1 aligns the content's left/top edge with the display, 0 centres it, 1 aligns the right/bottom edge.
struct WallpaperFraming: Codable, Hashable {
    var horizontal: Double = 0
    var vertical: Double = 0
    /// 1 just covers the display; larger values zoom in, which also leaves room to pan.
    var zoom: Double = 1

    static let centered = WallpaperFraming()
    static let zoomRange: ClosedRange<Double> = 1...3

    var isCentered: Bool {
        abs(horizontal) < 0.001 && abs(vertical) < 0.001 && abs(zoom - 1) < 0.001
    }

    var clamped: WallpaperFraming {
        WallpaperFraming(
            horizontal: min(max(horizontal, -1), 1),
            vertical: min(max(vertical, -1), 1),
            zoom: min(max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        )
    }

    /// Frame for content of `contentSize` inside `bounds`, in y-up (AppKit / Core Animation) coordinates.
    func rect(for contentSize: CGSize, in bounds: CGRect, scaling: VideoScaling) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let framing = clamped
        var size: CGSize
        switch scaling {
        case .fill:
            let scale = max(bounds.width / contentSize.width, bounds.height / contentSize.height)
            size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        case .fit:
            let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
            size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        case .stretch:
            size = bounds.size
        }
        size = CGSize(width: size.width * framing.zoom, height: size.height * framing.zoom)

        let overflowX = size.width - bounds.width
        let overflowY = size.height - bounds.height
        let x = bounds.minX - overflowX * (framing.horizontal + 1) / 2
        let y = bounds.minY - overflowY * (1 - framing.vertical) / 2
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Same placement in y-down coordinates (Core Graphics bitmaps, video compositions).
    func flippedRect(for contentSize: CGSize, in bounds: CGRect, scaling: VideoScaling) -> CGRect {
        let up = rect(for: contentSize, in: bounds, scaling: scaling)
        return CGRect(x: up.minX, y: bounds.maxY - (up.minY - bounds.minY) - up.height, width: up.width, height: up.height)
    }

    /// Procedural shaders have no edges, so offsets move the scene by up to half a screen.
    var shaderVector: SIMD4<Float> {
        let framing = clamped
        return SIMD4(Float(framing.horizontal * 0.5), Float(-framing.vertical * 0.5), Float(framing.zoom), 0)
    }

    /// Draws `image` into a new bitmap of `size` the way the desktop would show it.
    func render(_ image: CGImage, into size: CGSize, scaling: VideoScaling) -> CGImage? {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        // CGContext is y-up, matching `rect(for:in:scaling:)`.
        let target = rect(
            for: CGSize(width: image.width, height: image.height),
            in: CGRect(x: 0, y: 0, width: width, height: height),
            scaling: scaling
        )
        context.draw(image, in: target)
        return context.makeImage()
    }
}
