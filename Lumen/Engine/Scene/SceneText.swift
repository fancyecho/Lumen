import AppKit
import CoreText
import Metal

/// A texture whose contents change while the scene plays (video, text).
protocol DynamicTexture: AnyObject {
    func texture() -> MTLTexture?
    func setPlaying(_ playing: Bool)
}

extension SceneVideoTexture: DynamicTexture {}

/// A text layer's string rendered with Core Text into a texture: white glyphs with alpha
/// coverage, tinted by the layer's colour in the shader. Re-rendered only when the text changes.
final class SceneTextTexture: DynamicTexture, @unchecked Sendable {
    struct Style {
        var font: CTFont
        var horizontal: CTTextAlignment
        var vertical: String
        var padding: SIMD2<Float>
        var background: SIMD4<Float>?
        /// Extra width on each side for unwrapped lines longer than the box.
        var overflow: Float = 0
        /// Optional maximum line width in canvas units (`limitwidth` / `maxwidth`).
        var maxWidth: Float?
        /// Optional maximum number of rows (`limitrows` / `maxrows`).
        var maxRows: Int?
        /// Append `…` when truncating rows (`limituseellipsis`).
        var ellipsis: Bool = false
    }

    let pixelSize: SIMD2<Int>
    private let device: MTLDevice
    private let style: Style
    /// Canvas units to texture pixels (clamped consistently with `pixelSize`).
    private let scale: Float
    private var current: MTLTexture?
    private(set) var text: String
    private let lock = NSLock()

    init(device: MTLDevice, text: String, size: SIMD2<Float>, scale: Float, style: Style) {
        self.device = device
        self.text = text
        self.style = style
        let clampedScale = min(scale, 4096 / max(size.x, 1), 4096 / max(size.y, 1))
        self.scale = clampedScale
        pixelSize = SIMD2(max(1, min(4096, Int((size.x * clampedScale).rounded()))),
                          max(1, min(4096, Int((size.y * clampedScale).rounded()))))
        render()
    }

    func texture() -> MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func setPlaying(_ playing: Bool) {}

    func update(_ newText: String) {
        guard newText != text else { return }
        text = newText
        render()
    }

    private func render() {
        let width = pixelSize.x, height = pixelSize.y
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            if let background = style.background {
                context.setFillColor(CGColor(srgbRed: CGFloat(background.x), green: CGFloat(background.y), blue: CGFloat(background.z), alpha: CGFloat(background.w)))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            // The text box sits inside the padding; wrap to `maxWidth` when `limitwidth` is set,
            // otherwise shrink to fit the available width/height so lines aren't clipped.
            let padding = CGSize(width: CGFloat(style.padding.x * scale), height: CGFloat(style.padding.y * scale))
            let extra = CGFloat(style.overflow * scale)
            let box = CGRect(x: padding.width + extra, y: padding.height,
                             width: max(1, CGFloat(width) - (padding.width + extra) * 2), height: max(1, CGFloat(height) - padding.height * 2))
            let wrapWidth = style.maxWidth.map { min(CGFloat($0 * scale), box.width) }
            var fontSize = CTFontGetSize(style.font) * CGFloat(scale)
            var layout = Self.layout(text, font: CTFontCreateCopyWithAttributes(style.font, fontSize, nil, nil),
                                     maxWidth: wrapWidth, maxRows: style.maxRows, ellipsis: style.ellipsis)
            let overflow = max(layout.size.width / (box.width + extra * 2), layout.size.height / (box.height + padding.height * 2))
            if overflow > 1 {
                fontSize /= overflow
                layout = Self.layout(text, font: CTFontCreateCopyWithAttributes(style.font, fontSize, nil, nil),
                                     maxWidth: wrapWidth, maxRows: style.maxRows, ellipsis: style.ellipsis)
            }
            var y: CGFloat
            switch style.vertical {
            case "top": y = box.maxY
            case "bottom": y = box.minY + layout.size.height
            default: y = box.midY + layout.size.height / 2
            }
            context.textMatrix = .identity
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            for (line, lineWidth) in layout.lines {
                y -= layout.ascent
                var x: CGFloat
                switch style.horizontal {
                case .left: x = box.minX
                case .right: x = box.maxX - lineWidth
                default: x = box.midX - lineWidth / 2
                }
                x = min(max(x, padding.width), CGFloat(width) - padding.width - lineWidth)
                context.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(line, context)
                y -= layout.descent + layout.leading
            }
        }
        // Core Graphics draws premultiplied; shaders expect straight alpha.
        var index = 0
        while index < pixels.count {
            let alpha = Int(pixels[index + 3])
            if alpha > 0 && alpha < 255 {
                pixels[index] = UInt8(min(255, Int(pixels[index]) * 255 / alpha))
                pixels[index + 1] = UInt8(min(255, Int(pixels[index + 1]) * 255 / alpha))
                pixels[index + 2] = UInt8(min(255, Int(pixels[index + 2]) * 255 / alpha))
            }
            index += 4
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bytesPerRow) }
        lock.lock()
        current = texture
        lock.unlock()
    }

    private struct Layout {
        var lines: [(CTLine, CGFloat)]
        var size: CGSize
        var ascent: CGFloat
        var descent: CGFloat
        var leading: CGFloat
    }

    private static func layout(_ text: String, font: CTFont, maxWidth: CGFloat? = nil, maxRows: Int? = nil, ellipsis: Bool = false) -> Layout {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = max(CTFontGetLeading(font), 0)
        var lines: [(CTLine, CGFloat)] = []
        var width: CGFloat = 0
        var truncated = false
        for part in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let limit = maxRows, lines.count >= limit {
                truncated = true
                break
            }
            if let maxWidth, maxWidth > 0, !part.isEmpty {
                let attr = NSAttributedString(string: part, attributes: attributes)
                let typesetter = CTTypesetterCreateWithAttributedString(attr)
                let total = attr.length
                var offset = 0
                while offset < total {
                    if let limit = maxRows, lines.count >= limit {
                        truncated = true
                        break
                    }
                    let count = CTTypesetterSuggestLineBreak(typesetter, offset, Double(maxWidth))
                    let step = max(1, count)
                    let isLastAllowed = maxRows.map { lines.count + 1 == $0 } ?? false
                    let hasMore = offset + step < total
                    let line: CTLine
                    if ellipsis && isLastAllowed && hasMore {
                        let sub = (part as NSString).substring(with: NSRange(location: offset, length: step))
                            .trimmingCharacters(in: .whitespaces) + "…"
                        line = CTLineCreateWithAttributedString(NSAttributedString(string: sub, attributes: attributes))
                    } else {
                        line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: step))
                    }
                    let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    width = max(width, lineWidth)
                    lines.append((line, lineWidth))
                    offset += step
                }
            } else {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: part, attributes: attributes))
                let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                width = max(width, lineWidth)
                lines.append((line, lineWidth))
            }
        }
        _ = truncated
        let height = CGFloat(lines.count) * (ascent + descent) + CGFloat(max(lines.count - 1, 0)) * leading
        return Layout(lines: lines, size: CGSize(width: width, height: height), ascent: ascent, descent: descent, leading: leading)
    }

    /// Wallpaper Engine names system fonts `systemfont_*`; packages ship their own files.
    static func font(named name: String, size: CGFloat, files: SceneFileSystem) -> CTFont {
        if name.hasPrefix("systemfont_") {
            let family: String
            switch name.dropFirst("systemfont_".count).lowercased() {
            case "arial": family = "Arial"
            case "cambria": family = "Cambria"
            case "timesnewroman", "serif": family = "Times New Roman"
            case "couriernew", "consolas", "monospace": family = "Menlo"
            case "comicsansms": family = "Comic Sans MS"
            case "impact": family = "Impact"
            case "georgia": family = "Georgia"
            case "verdana": family = "Verdana"
            case "segoeui": family = "Helvetica Neue"
            default: return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            }
            return CTFontCreateWithName(family as CFString, size, nil)
        }
        if let data = files.data(name),
           let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
           let descriptor = descriptors.first {
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
}
