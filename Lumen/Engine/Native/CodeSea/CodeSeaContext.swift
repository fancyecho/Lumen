import AppKit
import CoreText
import Metal
import MetalKit

// Ported from Code Sea (Sources/SeaContext.swift). Lumen changes: the shader library is passed in
// (compiled at runtime from CodeSea.msl), the portrait is optional, and types are nested under `CodeSea`.
extension CodeSea {
    /// 各块屏幕共用的资源：Metal 设备与管线、人像贴图、各缩放比例的字形图集。
    final class SeaContext {
        static let pixelFormat: MTLPixelFormat = .bgra8Unorm
        /// 字号与行高（点）。10 点的等宽字在 1470 点宽的屏幕上约 240 列、80 行。
        static let fontSize: CGFloat = 10
        static let lineHeight: CGFloat = 12

        let device: MTLDevice
        let queue: MTLCommandQueue
        /// 四个管线变体：有没有翅膀 × 是不是在浮现之前的聚拢阶段（着色器的 function constant）。
        /// 用不到的那部分代码不编进去，不占寄存器，平时的帧更快。
        private let pipelines: [MTLRenderPipelineState]

        func pipeline(wings: Bool, gather: Bool) -> MTLRenderPipelineState { pipelines[(wings ? 1 : 0) + (gather ? 2 : 0)] }
        let figure: MTLTexture
        let figureAspect: Float
        /// False when no portrait was imported: the sea plays, and she never appears.
        let hasFigure: Bool
        /// 诗句流（r8Uint，每行 2048 个字符）与它的长度。
        let verses: MTLTexture
        let versesLength: Int
        static let versesWidth = 2048
        private var atlases: [Int: GlyphAtlas] = [:]

        init(device: MTLDevice, library: MTLLibrary, avatarURL: URL?, versesURL: URL?) throws {
            guard let queue = device.makeCommandQueue() else {
                throw SeaError("没有可用的 Metal 设备")
            }
            self.device = device
            self.queue = queue

            pipelines = try (0..<4).map { variant in
                let constants = MTLFunctionConstantValues()
                var wings = variant & 1 != 0, gather = variant & 2 != 0
                constants.setConstantValue(&wings, type: .bool, index: 0)
                constants.setConstantValue(&gather, type: .bool, index: 1)
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name: "seaVertex")
                desc.fragmentFunction = try library.makeFunction(name: "seaFragment", constantValues: constants)
                desc.colorAttachments[0].pixelFormat = SeaContext.pixelFormat
                return try device.makeRenderPipelineState(descriptor: desc)
            }

            if let avatarURL, let loaded = try? SeaContext.loadFigure(url: avatarURL, device: device, queue: queue) {
                (figure, figureAspect) = loaded
                hasFigure = true
            } else {
                // A transparent pixel keeps the shader's figure binding valid without a portrait.
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
                desc.usage = .shaderRead
                guard let blank = device.makeTexture(descriptor: desc) else { throw SeaError("无法创建人像贴图") }
                blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
                (figure, figureAspect) = (blank, 0.5)
                hasFigure = false
            }

            let text = versesURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            var stream = Verses.stream(text)
            versesLength = stream.count
            let vw = SeaContext.versesWidth, vh = (stream.count + vw - 1) / vw
            stream += [UInt8](repeating: 32, count: vw * vh - stream.count)
            let vdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: vw, height: vh, mipmapped: false)
            vdesc.usage = .shaderRead
            guard let vt = device.makeTexture(descriptor: vdesc) else { throw SeaError("无法创建诗句贴图") }
            vt.replace(region: MTLRegionMake2D(0, 0, vw, vh), mipmapLevel: 0, withBytes: stream, bytesPerRow: vw)
            verses = vt
        }

        /// 人像：预乘透明度的 RGBA8，带完整 mip 链（着色器按字符格大小取对应层级）。
        private static func loadFigure(url: URL, device: MTLDevice, queue: MTLCommandQueue) throws -> (MTLTexture, Float) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw SeaError("读不到人像图 \(url.lastPathComponent)")
            }
            let w = image.width, h = image.height
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok else { throw SeaError("人像图解码失败") }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
            desc.usage = .shaderRead
            guard let tex = device.makeTexture(descriptor: desc) else { throw SeaError("无法创建人像贴图") }
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
            if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: tex)
                blit.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
            }
            return (tex, Float(w) / Float(h))
        }

        func atlas(scale: CGFloat) -> GlyphAtlas {
            let key = Int((scale * 100).rounded())
            if let a = atlases[key] { return a }
            let a = GlyphAtlas(device: device, scale: scale)
            atlases[key] = a
            return a
        }
    }

    /// ASCII 32…127 的字形，按屏幕像素大小一比一画好（16×6 格，每格四周留 1 像素空隙防止串字）。
    /// 竖着排三种字重：0 细、1 常规、2 半粗。字符海用常规；她身上按明暗选字重（字符画里用字重表现色调的做法）。
    struct GlyphAtlas {
        let texture: MTLTexture
        let cellPx: SIMD2<Float>

        init(device: MTLDevice, scale: CGFloat) {
            let weights: [NSFont.Weight] = [.light, .regular, .semibold]
            let font = NSFont.monospacedSystemFont(ofSize: SeaContext.fontSize * scale, weight: .regular)
            let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
            let cw = max(4, Int(advance.rounded()))
            let ch = max(6, Int((SeaContext.lineHeight * scale).rounded()))
            cellPx = SIMD2(Float(cw), Float(ch))
            let bw = cw + 2, bh = ch + 2
            let W = bw * 16, H = bh * 6 * weights.count
            var pixels = [UInt8](repeating: 0, count: W * H)
            pixels.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.setAllowsAntialiasing(true)
                ctx.setShouldSmoothFonts(false)
                ctx.setFillColor(gray: 1, alpha: 1)
                let ctFont = font as CTFont
                let ascent = CTFontGetAscent(ctFont), descent = CTFontGetDescent(ctFont)
                let baselineFromTop = (CGFloat(ch) - (ascent + descent)) / 2 + ascent
                for (wi, weight) in weights.enumerated() {
                    let wf = NSFont.monospacedSystemFont(ofSize: SeaContext.fontSize * scale, weight: weight)
                    for code in 32..<127 {
                        let i = code - 32
                        let bx = (i % 16) * bw + 1, by = (wi * 6 + i / 16) * bh + 1
                        let s = String(UnicodeScalar(UInt8(code)))
                        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                            .font: wf, .foregroundColor: NSColor.white,
                        ]))
                        ctx.textPosition = CGPoint(x: CGFloat(bx), y: CGFloat(H) - (CGFloat(by) + baselineFromTop))
                        CTLineDraw(line, ctx)
                    }
                }
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: W, height: H, mipmapped: false)
            desc.usage = .shaderRead
            texture = device.makeTexture(descriptor: desc)!
            texture.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: pixels, bytesPerRow: W)
        }
    }

    struct SeaError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
