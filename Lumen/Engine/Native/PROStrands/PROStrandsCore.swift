import Metal
import MetalKit
import QuartzCore

// Ported from PRO Strands (pro-native/Sources/Renderer.swift). Lumen changes: the device and shader
// library are passed in (compiled at runtime from PROStrands.msl), and types are nested under `PROStrands`.
extension PROStrands {
    /// 与着色器 `Uniforms` 一致（88 字节）。
    struct Uniforms {
        var viewSize = SIMD2<Float>(0, 0)
        var srcSize = SIMD2<Float>(0, 0)
        var offset = SIMD2<Float>(0, 0)
        var scale: Float = 1
        var footprint: Float = 1
        var time: Float = 0
        var simActive: Float = 0
        var flow: Float = 0
        var glow: Float = 0
        var lod: Float = 0
        var reach: Float = 0
        var depth: Float = 0
        var maxWidth: Float = 0
        var strandCount: Int32 = 0
        var rows: Int32 = 0
        var srcWidth: Int32 = 0
        var activeLo: Int32 = 0
        var activeHi: Int32 = -1
        var blocks: Int32 = 0
    }

    /// 所有屏幕共用的 GPU 资源：原图纹理、光丝表、着色器。
    final class RenderContext {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let image: MTLTexture
        let strandBuffer: MTLBuffer
        let restIndexBuffer: MTLBuffer
        let layout: StrandLayout
        let cohesionTexture: MTLTexture
        static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

        init(device: MTLDevice, library: MTLLibrary, imageURL: URL) throws {
            guard let queue = device.makeCommandQueue() else {
                throw NSError(domain: "PROStrands", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的 Metal 设备"])
            }
            self.device = device
            self.queue = queue

            guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NSError(domain: "PROStrands", code: 2, userInfo: [NSLocalizedDescriptionKey: "读不到壁纸图片 \(imageURL.path)"])
            }
            layout = StrandLayout(image: cgImage)

            let loader = MTKTextureLoader(device: device)
            image = try loader.newTexture(cgImage: cgImage, options: [
                .SRGB: true,
                .generateMipmaps: true,
                .textureStorageMode: MTLStorageMode.private.rawValue,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            ])
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vmain")
            desc.fragmentFunction = library.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = RenderContext.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)

            strandBuffer = layout.gpu.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
            }
            restIndexBuffer = layout.restIndex.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
            }

            let cdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: layout.count,
                                                                 height: layout.rows, mipmapped: false)
            cdesc.usage = .shaderRead
            cdesc.storageMode = .shared
            cohesionTexture = device.makeTexture(descriptor: cdesc)!
            let half = layout.cohesion.map { Float16($0) }
            half.withUnsafeBytes {
                cohesionTexture.replace(region: MTLRegionMake2D(0, 0, layout.count, layout.rows), mipmapLevel: 0,
                                        withBytes: $0.baseAddress!, bytesPerRow: layout.count * 2)
            }
        }
    }

    /// 外观参数（不影响物理）。
    struct LookParams: Equatable {
        var glow: Float = 65       // 金属反光 0…100
        var flow: Float = 30       // 空闲流光 0…100，0 = 关
        var flowSpeed: Float = 50  // 流光速度 0…100
    }

    /// 空闲流光的时间表：光区按顺序轮流点亮，每次从一端灌入。输出与着色器 `FlowParams` 一致的 100 个 Float。
    enum FlowSchedule {
        static func params(layout: StrandLayout, time t: Float, speed: Float) -> [Float] {
            let sections = layout.sections
            let count = min(sections.count, 8)
            let period = 20 - 12 * speed / 100
            let lowerIndex = layout.splitSection >= 0 ? sections.count - 1 : -1

            // 光区的横向边界放在相邻两束之间黑缝的中线，着色器在这里羽化。
            var columns = sections.indices.filter { $0 != lowerIndex }.sorted { sections[$0].x0 < sections[$1].x0 }
            var edges: [Int: (Float, Float)] = [:]
            for (n, k) in columns.enumerated() {
                let left: Float = n == 0 ? -1e6 : (sections[columns[n - 1]].x1 + sections[k].x0) / 2
                let right: Float = n == columns.count - 1 ? 1e6 : (sections[k].x1 + sections[columns[n + 1]].x0) / 2
                edges[k] = (left, right)
            }
            if lowerIndex >= 0 { edges[lowerIndex] = edges[layout.splitSection] }
            columns.removeAll()

            var out = [Float](repeating: 0, count: 100)
            for k in 0..<count {
                let sec = sections[k]
                // 顺序就是光区编号：P 竖 → P 弧 → R 竖 → R 上 → O 左 → O 右 → R 下，绕整个单词一圈。
                let phase = t / period - Float(k) / Float(count)
                let x = phase - phase.rounded(.down)
                let on: Float = 0.42
                let e: Float = x < on ? pow(sin(Float.pi * x / on), 2) : 0
                // 每一轮换一端灌入（只在这一束暗着的时候切换，看不到跳变）。
                let cycle = Int(phase.rounded(.down))
                let fromTop = (cycle + k) % 2 == 0
                let length = sec.y1 - sec.y0
                let (x0, x1) = edges[k] ?? (sec.x0, sec.x1)
                let o = k * 12
                out[o + 0] = x0
                out[o + 1] = x1
                out[o + 2] = sec.y0
                out[o + 3] = sec.y1
                out[o + 4] = fromTop ? sec.y0 : sec.y1
                out[o + 5] = fromTop ? 1 : -1
                out[o + 6] = e
                out[o + 7] = (0.2 + 0.95 * e) * length
                out[o + 8] = k == layout.splitSection ? 1 : (k == lowerIndex ? 2 : 0)
                out[o + 9] = layout.waistY
            }
            out[99] = Float(count)
            return out
        }
    }

    /// 一块屏幕（或离屏快照）的渲染器：拥有自己的模拟与模拟纹理。
    final class StrandRenderer {
        let ctx: RenderContext
        let sim: StrandSim
        let simTexture: MTLTexture
        let activityBuffer: MTLBuffer
        var look = LookParams()
        private(set) var lastGPUms: Double = 0
        private let startTime = CACurrentMediaTime()

        init(context: RenderContext) {
            ctx = context
            sim = StrandSim(layout: context.layout)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                width: context.layout.count,
                                                                height: context.layout.rows,
                                                                mipmapped: false)
            desc.usage = .shaderRead
            desc.storageMode = .shared
            simTexture = context.device.makeTexture(descriptor: desc)!
            activityBuffer = context.device.makeBuffer(length: sim.activity.count, options: .storageModeShared)!
            upload()
        }

        func upload() {
            let n = ctx.layout.count, m = ctx.layout.rows
            sim.packed.withUnsafeBytes { raw in
                simTexture.replace(region: MTLRegionMake2D(0, 0, n, m), mipmapLevel: 0,
                                   withBytes: raw.baseAddress!, bytesPerRow: n * 8)
            }
            sim.activity.withUnsafeBytes { raw in
                activityBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }

        /// 源图（原图像素）铺满目标的几何：等比填充、居中。
        static func fit(target: CGSize, source: CGSize) -> (scale: Float, offset: SIMD2<Float>) {
            let s = max(target.width / source.width, target.height / source.height)
            let off = SIMD2<Float>(Float((target.width - source.width * s) / 2), Float((target.height - source.height * s) / 2))
            return (Float(s), off)
        }

        func encode(into pass: MTLRenderPassDescriptor, size: CGSize, commandBuffer: MTLCommandBuffer, time: Float? = nil) {
            let layout = ctx.layout
            let src = CGSize(width: layout.srcWidth, height: layout.srcHeight)
            let (scale, offset) = StrandRenderer.fit(target: size, source: src)
            var u = Uniforms()
            u.viewSize = SIMD2(Float(size.width), Float(size.height))
            u.srcSize = SIMD2(Float(src.width), Float(src.height))
            u.offset = offset
            u.scale = scale
            u.footprint = 1 / scale
            u.time = time ?? Float(CACurrentMediaTime() - startTime)
            u.simActive = sim.active ? 1 : 0
            u.flow = look.flow / 100
            u.glow = look.glow / 100
            u.lod = max(0, log2(1 / scale))
            u.reach = sim.maxAbsDisplacement + layout.maxWidth + 2
            u.maxWidth = layout.maxWidth
            u.depth = sim.params.depth / 100
            u.strandCount = Int32(layout.count)
            u.rows = Int32(layout.rows)
            u.srcWidth = Int32(layout.srcWidth)
            let range = sim.activeStrands
            u.activeLo = Int32(range.lo)
            u.activeHi = Int32(range.hi)
            u.blocks = Int32(sim.blocks)

            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(ctx.pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBuffer(ctx.strandBuffer, offset: 0, index: 1)
            enc.setFragmentBuffer(ctx.restIndexBuffer, offset: 0, index: 2)
            enc.setFragmentBuffer(activityBuffer, offset: 0, index: 3)
            enc.setFragmentTexture(ctx.image, index: 0)
            enc.setFragmentTexture(simTexture, index: 1)
            enc.setFragmentTexture(ctx.cohesionTexture, index: 2)
            let fp = FlowSchedule.params(layout: layout, time: u.time, speed: look.flowSpeed)
            fp.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 4) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        /// 连续渲染若干帧（不回读），返回平均 GPU 毫秒数，用于估算真实帧耗时。
        func benchmark(width: Int, height: Int, frames: Int) -> Double {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.pixelFormat,
                                                                width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget]
            desc.storageMode = .private
            let target = ctx.device.makeTexture(descriptor: desc)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            var buffers: [MTLCommandBuffer] = []
            for k in 0..<frames {
                let cb = ctx.queue.makeCommandBuffer()!
                encode(into: pass, size: CGSize(width: width, height: height), commandBuffer: cb, time: Float(k) / 60)
                cb.commit()
                buffers.append(cb)
            }
            buffers.last?.waitUntilCompleted()
            // 其他程序也在用 GPU 时平均值会被时间片拉高，取最小值更接近本着色器的真实开销。
            let times = buffers.dropFirst(frames / 4).map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 }
            return times.min() ?? 0
        }

        /// 离屏渲染一帧，返回 BGRA8（sRGB 编码）像素。
        func renderOffscreen(width: Int, height: Int, time: Float) -> [UInt8] {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.pixelFormat,
                                                                width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            let target = ctx.device.makeTexture(descriptor: desc)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            let cb = ctx.queue.makeCommandBuffer()!
            encode(into: pass, size: CGSize(width: width, height: height), commandBuffer: cb, time: time)
            cb.commit()
            cb.waitUntilCompleted()
            lastGPUms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return bytes
        }
    }
}
