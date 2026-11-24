import Foundation
import Metal
import QuartzCore
import simd

// Ported from Code Sea (Sources/SeaRenderer.swift). The logic is unchanged; types are nested under
// `CodeSea` so their names stay out of Lumen's module namespace.
extension CodeSea {
    /// 外观参数（来自设置）。
    struct SeaLook {
        /// 海面浮动 0…100（0 = 静止，静止且无效果时完全不绘制）。
        var motion: Float = 50
        /// 字符亮度 0…100。
        var brightness: Float = 50
        var hover = true
        /// 夜海色调：海面偏冷（月光下的蓝灰），衬出她的暖金；关掉是原来的暖灰。
        var nightSea = true
        /// 她背后一对由诗句组成的翅膀。
        var wings = true

        /// 每个字整体漂浮的幅度（点）与浪尖白光的多少。
        var amplitudePt: Float { motion / 50 * 2.3 }
        var glint: Float { min(1, motion / 50 * 0.85) }
        var level: Float { 0.55 + brightness / 100 * 0.9 }
    }

    /// 人像这一刻的状态。
    struct AvatarFrame {
        var reveal: Float = 0
        /// 浮现之前，海面的光向她心口聚拢的进度（0…1；1 = 已聚拢，开始浮现）。
        var gather: Float = 1
        var dissolve: Float = 0
        var elapsed: Float = 0
        var present = false
        /// 浮现开始后的秒数（翅膀展开的时间轴；完全展开后封顶，不随时间增长）。
        var unfurl: Float = 60

        static let hidden = AvatarFrame()
    }

    /// 决定人像何时出现：闪烁着显现 → 飘浮一会儿 → 化作光点消散，过一段时间再来。
    final class AvatarDirector {
        enum Phase { case hidden, revealing, shown, dissolving }
        /// 浮现分两段：先用 gatherTime 让海面的光向她心口聚拢、I Love You 先亮，再用 revealTime 从心口向外浮现。
        static let gatherTime = 2.0, revealTime = 3.4, holdTime = 16.0, dissolveTime = 4.6

        private(set) var phase = Phase.hidden
        /// 常显：出现后一直留下，不再消散。
        var persistent = false {
            didSet { if oldValue && !persistent && phase == .shown { phaseStart = CACurrentMediaTime() } }
        }
        private var phaseStart: Double = 0
        private var appearStart: Double = 0
        private var next: Double
        /// 两次出现之间的平均间隔（秒）；nil 表示不主动出现（仍可手动召唤）。
        var interval: Double? {
            didSet { if oldValue != interval { scheduleNext(after: CACurrentMediaTime(), first: true) } }
        }

        init(interval: Double?, firstDelay: Double = 20) {
            self.interval = interval
            next = CACurrentMediaTime() + firstDelay
        }

        var isActive: Bool { phase != .hidden }

        /// 下次需要开始绘制的时间（给“静止不绘制”模式安排唤醒用）。
        var nextAppearance: Double? { persistent ? 0 : (interval == nil ? nil : next) }

        func summon(now: Double = CACurrentMediaTime()) {
            switch phase {
            case .hidden: begin(now)
            case .dissolving: begin(now)
            case .revealing: break
            case .shown: phaseStart = now   // 已经在场：多停留一会儿
            }
        }

        func restart(firstDelay: Double, now: Double = CACurrentMediaTime()) {
            phase = .hidden
            next = now + firstDelay
        }

        func frame(now: Double) -> AvatarFrame {
            if phase == .hidden, persistent || (interval != nil && now >= next) { begin(now) }
            let t = now - phaseStart
            switch phase {
            case .hidden:
                return .hidden
            case .revealing:
                if t >= Self.gatherTime + Self.revealTime { setPhase(.shown, now) }
            case .shown:
                if !persistent && t >= Self.holdTime { setPhase(.dissolving, now) }
            case .dissolving:
                if t >= Self.dissolveTime {
                    phase = .hidden
                    scheduleNext(after: now, first: false)
                    return .hidden
                }
            }
            let k = now - phaseStart
            // 常显时可能一连几天都在：秒数按小时取模，Float 精度不掉，飘动也不会变成一顿一顿的。
            var f = AvatarFrame(elapsed: HourLoop.time(now - appearStart), present: true)
            switch phase {
            case .revealing:
                f.gather = Float(min(1, k / Self.gatherTime))
                f.reveal = Float(max(0, (k - Self.gatherTime) / Self.revealTime))
                f.unfurl = Float(max(0, k - Self.gatherTime))
            case .shown: f.reveal = 1; f.unfurl = Float(min(60, Self.revealTime + k))
            case .dissolving: f.reveal = 1; f.dissolve = Float(k / Self.dissolveTime)
            case .hidden: break
            }
            return f
        }

        /// 她所在的那块屏幕停画了 seconds 秒：她的时间轴整体往后挪，回来时从停下的地方接着演（没出现时不用挪）。
        func hold(_ seconds: Double) {
            guard phase != .hidden else { return }
            phaseStart += seconds
            appearStart += seconds
        }

        private func begin(_ now: Double) {
            if phase == .dissolving {
                // 正在消散时再次召唤：跳过聚拢，从当前可见程度接着显现，不闪断。
                let left = 1 - min(1, (now - phaseStart) / Self.dissolveTime)
                phase = .revealing
                phaseStart = now - Self.gatherTime - Self.revealTime * left
                return
            }
            phase = .revealing
            phaseStart = now
            appearStart = now
        }

        private func setPhase(_ p: Phase, _ now: Double) {
            phase = p
            phaseStart = now
        }

        private func scheduleNext(after now: Double, first: Bool) {
            guard let interval else { return }
            let jitter = Double.random(in: 0.7...1.3)
            next = now + (first ? min(interval, 20) : interval * jitter)
        }
    }

    /// 浮现之前从四周的海面向她心口汇聚的光点。每个光点错开出发，沿略带弧度的路径、越近越快，拖一小段尾光，
    /// 到心口就融进那团光里。位置每帧在这里算好交给着色器，着色器只量到每段尾光的距离。
    enum GatherMotes {
        static let count = 28

        /// count 段尾光（xy 头、zw 尾，像素）和 count 个亮度。g 是聚拢进度（0…1），heart 是她心口（像素）。
        static func compute(g: Float, heart: SIMD2<Float>, viewHeight H: Float) -> ([SIMD4<Float>], [Float]) {
            var rng = SplitMix(seed: 0x6A7E_2026)
            func unit() -> Float { Float(rng.next() % 1_000_000) / 1_000_000 }
            var segments = [SIMD4<Float>](repeating: .zero, count: count)
            var brightness = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let r1 = unit(), r2 = unit(), r3 = unit(), r4 = unit()
                let tau = max(0, min(1, (g - 0.45 * r3) / (0.50 + 0.05 * r4)))
                guard tau > 0, tau < 1 else { continue }
                let radius = (0.30 + 0.45 * r2) * H
                let angle = 2 * Float.pi * r1, swirl: Float = r4 > 0.5 ? 0.7 : -0.7
                func at(_ t: Float) -> SIMD2<Float> {
                    let e = pow(1 - t, 1.8)                                // 半径收拢：越近越快
                    let a = angle + swirl * (1 - e)
                    return heart + radius * e * SIMD2(cos(a), 0.8 * sin(a))
                }
                let head = at(tau), tail = at(max(tau - 0.05, 0))
                segments[i] = SIMD4(head.x, head.y, tail.x, tail.y)
                let fadeIn = min(1, tau / 0.2), fadeOut = 1 - max(0, (tau - 0.85) / 0.15)
                brightness[i] = fadeIn * fadeIn * (3 - 2 * fadeIn) * fadeOut * fadeOut * (3 - 2 * fadeOut) * (0.55 + 0.45 * r2)
            }
            return (segments, brightness)
        }
    }

    /// 着色器常量，布局与 Sea.metal 里的 SeaUniforms 一一对应（256 字节）。
    struct SeaUniforms {
        var pointer = SIMD4<Float>.zero
        var avatarRect = SIMD4<Float>.zero
        var avatar = SIMD4<Float>.zero
        var look = SIMD4<Float>.zero
        var halo = SIMD4<Float>.zero
        /// x 夜海色调（0/1），y 翅膀（0/1），z 浮现前光向心口聚拢的进度，w 振翅时她被托高多少（像素）。
        var style = SIMD4<Float>.zero
        var reserved: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                       SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero)
        var viewPx = SIMD2<Float>.zero
        var cellPx = SIMD2<Float>.zero
        var gridSize = SIMD2<Float>.zero
        var atlasSize = SIMD2<Float>.zero
        var scale: Float = 1
        var time: Float = 0
        var rippleCount: Int32 = 0
        var pad: Float = 0
    }

    /// 一块屏幕（或锁屏表面）的渲染器：字符网格、海面漂浮、指针光晕、人像。
    final class SeaRenderer {
        /// 人像在人像图里的光环位置（头后）与半径（人像宽度的比例）。
        static let halo = SIMD3<Float>(0.505, 0.075, 0.22)

        let ctx: SeaContext
        var look = SeaLook()
        var avatar = AvatarFrame.hidden
        /// 屏幕四边被菜单栏、程序坞占住的宽度（点：上、左、下、右）。她只站在剩下的区域里，
        /// 头顶的光环不碰菜单栏，赤足和脚下那片光不被程序坞挡住。锁屏和离屏渲染保持 0。
        var reserved = SIMD4<Float>(0, 0, 0, 0)
        let seed: UInt64
        /// 计时起点；u.time 是从这里算起、按一小时取模的秒数。停画的那段时间由 hold 加进来，画面里的时间也跟着停住。
        private(set) var epoch = CACurrentMediaTime()

        /// 画面停了 seconds 秒（被遮住、切到别的桌面、锁屏、睡眠……）：海面的时间停在原处，回来时接着上一帧往下走，不跳。
        func hold(_ seconds: Double) { epoch += seconds }
        private var cells: MTLTexture?
        private var gridSize = SIMD2<Int>(0, 0)
        private var messageAt = SIMD2<Int>(-1, -1)
        private var atlas: GlyphAtlas?
        private var atlasScale: CGFloat = 0
        private var field: SeaField?
        private var fieldTextures: [MTLTexture] = []
        private var fieldIndex = 0
        private var fieldBuffer: [Float16] = []
        private var currentField: MTLTexture?
        private let wings = Wings()
        private var wingBytes: [UInt8] = []
        private var wingTextures: [MTLTexture] = []
        private var glowTextures: [MTLTexture] = []
        private var wingIndex = 0
        /// 每帧交给着色器的参数（buffer 1）：翅膀 8 个 + 光点尾光 28 个 + 光点亮度 7 个 + 范围 1 个（布局见 Sea.metal 的 fx）。
        private static let moteBase = Wings.paramCount, moteBrightBase = moteBase + GatherMotes.count, rangeIndex = moteBrightBase + 7
        private var effects = [SIMD4<Float>](repeating: .zero, count: rangeIndex + 1)
        private var pointerPx = SIMD2<Float>(-1e5, -1e5)
        private var pointerGlow: Float = 0
        private var lastPointerTime: Double = 0

        init(context: SeaContext, seed: UInt64 = 1) {
            ctx = context
            self.seed = seed
        }

        /// 指针（像素，nil = 不在露出的桌面上）。光晕随移动速度出现，停下后慢慢淡去。
        func updatePointer(_ px: SIMD2<Float>?, scale: Float, now: Double) {
            let dt = Float(max(1e-3, min(0.1, now - lastPointerTime)))
            lastPointerTime = now
            var target: Float = 0
            if let px, look.hover {
                let speed = simd_length(px - pointerPx) / scale / dt
                if pointerPx.x > -1e4 { target = min(1, speed / 700) }
                pointerPx = px
            } else if px == nil {
                target = 0
            }
            let rate: Float = target > pointerGlow ? 9 : 1.6
            pointerGlow += (target - pointerGlow) * min(1, rate * dt)
            if pointerGlow < 0.004 && target == 0 {
                pointerGlow = 0
                if px == nil { pointerPx = SIMD2(-1e5, -1e5) }   // 离开后重新进入时不把跳变当成速度
            }
        }

        /// 指针光晕还没散：需要跟手的高帧率。
        var hasGlow: Bool { pointerGlow > 0 }

        private func prepare(width: Int, height: Int, scale: CGFloat) {
            if atlas == nil || atlasScale != scale {
                atlas = ctx.atlas(scale: scale)
                atlasScale = scale
                cells = nil
            }
            guard let atlas else { return }
            let cols = Int(ceil(Float(width) / atlas.cellPx.x)) + 2
            let rows = Int(ceil(Float(height) / atlas.cellPx.y)) + 2
            let gridChanged = cells == nil || gridSize != SIMD2(cols, rows)
            if gridChanged {
                gridSize = SIMD2(cols, rows)
                field = SeaField(cols: cols, rows: rows, cell: atlas.cellPx / Float(scale), seed: seed)
                fieldBuffer = [Float16](repeating: 0, count: cols * rows * 4)
                let fdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: cols, height: rows, mipmapped: false)
                fdesc.usage = .shaderRead
                // 三块轮换：CPU 写这一帧时，GPU 可能还在读上一帧那块。
                fieldTextures = (0..<3).map { _ in ctx.device.makeTexture(descriptor: fdesc)! }
                // 翅膀羽轴上的字（每格一个），同样三块轮换。
                wingBytes = [UInt8](repeating: 0, count: cols * rows * 4)
                let wdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: cols, height: rows, mipmapped: false)
                wdesc.usage = .shaderRead
                wingTextures = (0..<3).map { _ in ctx.device.makeTexture(descriptor: wdesc)! }
                // 翅膀在字缝里的光（半格大小），同样三块轮换。
                let gs = Wings.glowSize(view: SIMD2(Float(width), Float(height)), cell: atlas.cellPx)
                let gdesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: gs.x, height: gs.y, mipmapped: false)
                gdesc.usage = .shaderRead
                glowTextures = (0..<3).map { _ in ctx.device.makeTexture(descriptor: gdesc)! }
            }
            // I Love You 写在她心口的位置（她不在时也一直藏在那片字符海里）。她换了位置（设置、程序坞变化）时重铺字符。
            let rect = figureRect(width: Float(width), height: Float(height), scale: Float(scale))
            let heart = SIMD2(rect.x + Self.heart.x * rect.z, rect.y + Self.heart.y * rect.w)
            let at = SIMD2(Int(heart.x / atlas.cellPx.x) + 1, Int(heart.y / atlas.cellPx.y) + 1)
            guard gridChanged || at != messageAt else { return }
            messageAt = at
            let bytes = CodeText.grid(cols: cols, rows: rows, seed: seed, message: Self.note, messageAt: at)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: cols, height: rows, mipmapped: false)
            desc.usage = .shaderRead
            let tex = ctx.device.makeTexture(descriptor: desc)!
            tex.replace(region: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0, withBytes: bytes, bytesPerRow: cols * 4)
            cells = tex
        }

        static let note = " I Love You "   // 前后各留一个空格，和周围的字分开
        /// 她心口在人像图里的位置（uv）。
        static let heart = SIMD2<Float>(0.50, 0.24)

        /// 人像在屏幕上的矩形（像素：x, y, 宽, 高）。只用菜单栏、程序坞以外的区域：高约这块区域的 86%，
        /// 头顶留出光环、脚下留出那片光的位置；水平居中（一对翅膀才能对称地伸到屏幕两侧）。
        func figureRect(width W: Float, height H: Float, scale s: Float) -> SIMD4<Float> {
            let top = reserved.x * s, left = reserved.y * s, bottom = reserved.z * s, right = reserved.w * s
            let aw = max(1, W - left - right), ah = max(1, H - top - bottom)
            var fh = ah * 0.86
            var fw = fh * ctx.figureAspect
            if fw > aw * 0.9 { fw = aw * 0.9; fh = fw / ctx.figureAspect }
            let x = left + (aw - fw) / 2
            return SIMD4(x, top + ah * 0.085, fw, fh)
        }

        /// 把每个字此刻的漂浮位移和明暗写进 field 纹理。
        private func updateField(now: Double, time: Float, scale: Float) -> MTLTexture? {
            guard let field, !fieldTextures.isEmpty else { return nil }
            fieldBuffer.withUnsafeMutableBufferPointer { buf in
                field.fill(buf.baseAddress!, time: time, amplitude: look.amplitudePt, glint: look.glint, scale: scale)
            }
            fieldIndex = (fieldIndex + 1) % fieldTextures.count
            let tex = fieldTextures[fieldIndex]
            tex.replace(region: MTLRegionMake2D(0, 0, field.cols, field.rows), mipmapLevel: 0,
                        withBytes: fieldBuffer, bytesPerRow: field.cols * 8)
            return tex
        }

        func uniforms(width: Int, height: Int, scale: CGFloat, now: Double) -> SeaUniforms {
            prepare(width: width, height: height, scale: scale)
            var u = SeaUniforms()
            let s = Float(scale)
            let W = Float(width), H = Float(height)
            u.viewPx = SIMD2(W, H)
            u.cellPx = atlas!.cellPx
            u.gridSize = SIMD2(Float(gridSize.x), Float(gridSize.y))
            u.atlasSize = SIMD2(Float(atlas!.texture.width), Float(atlas!.texture.height))
            u.scale = s
            u.time = HourLoop.time(now - epoch)
            u.pointer = SIMD4(pointerPx.x, pointerPx.y, pointerGlow, 95 * s)
            u.look = SIMD4(Self.heart.x, look.level, Float(ctx.versesLength), Self.heart.y)
            currentField = updateField(now: now, time: u.time, scale: s)

            u.avatarRect = figureRect(width: W, height: H, scale: s)
            u.avatar = SIMD4(min(1, avatar.reveal), min(1, avatar.dissolve), avatar.elapsed, avatar.present ? 1 : 0)
            var wingsOn: Float = 0
            if look.wings, avatar.present, !wingTextures.isEmpty,
               wings.update(cells: &wingBytes, cols: gridSize.x, rows: gridSize.y, cell: u.cellPx, view: u.viewPx,
                            rect: u.avatarRect, dissolve: u.avatar.y, unfurl: avatar.unfurl, time: u.time, elapsed: avatar.elapsed) {
                wingIndex = (wingIndex + 1) % wingTextures.count
                wingTextures[wingIndex].replace(region: MTLRegionMake2D(0, 0, gridSize.x, gridSize.y), mipmapLevel: 0,
                                                withBytes: wingBytes, bytesPerRow: gridSize.x * 4)
                let gs = wings.glowSize, gt = glowTextures[wingIndex]
                if gt.width == gs.x && gt.height == gs.y {
                    wings.glow.withUnsafeBytes {
                        gt.replace(region: MTLRegionMake2D(0, 0, gs.x, gs.y), mipmapLevel: 0, withBytes: $0.baseAddress!,
                                   bytesPerRow: gs.x * 8)
                    }
                    wingsOn = 1
                }
            }
            u.style = SIMD4(look.nightSea ? 1 : 0, wingsOn, avatar.present ? avatar.gather : 1, wingsOn > 0 ? wings.figureLift : 0)
            for k in 0..<Wings.paramCount { effects[k] = wings.params[k] }
            for k in Wings.paramCount..<effects.count { effects[k] = .zero }
            // 范围（让着色器跳过不相干的像素）：翅膀所在的那一横条（上下边，像素）、光点离心口最远多少像素。
            if wingsOn > 0 {
                effects[Self.rangeIndex].x = wings.band.x
                effects[Self.rangeIndex].y = wings.band.y
            }
            if avatar.present, avatar.gather < 1 {
                let heart = SIMD2(u.avatarRect.x + Self.heart.x * u.avatarRect.z, u.avatarRect.y + Self.heart.y * u.avatarRect.w)
                let (segments, brightness) = GatherMotes.compute(g: avatar.gather, heart: heart, viewHeight: H)
                var reach: Float = 0
                for i in 0..<GatherMotes.count {
                    effects[Self.moteBase + i] = segments[i]
                    effects[Self.moteBrightBase + i / 4][i % 4] = brightness[i]
                    if brightness[i] > 0 {
                        reach = max(reach, simd_length(SIMD2(segments[i].z, segments[i].w) - heart))
                    }
                }
                effects[Self.rangeIndex].z = reach + u.cellPx.y * 3
            }
            u.halo = SIMD4(Self.halo.x, Self.halo.y, Self.halo.z, 0)
            return u
        }

        func encode(into pass: MTLRenderPassDescriptor, width: Int, height: Int, scale: CGFloat, now: Double,
                    commandBuffer: MTLCommandBuffer) {
            var u = uniforms(width: width, height: height, scale: scale, now: now)
            guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            enc.setRenderPipelineState(ctx.pipeline(wings: u.style.y > 0.5, gather: u.style.z < 1))
            enc.setFragmentBytes(&u, length: MemoryLayout<SeaUniforms>.stride, index: 0)
            enc.setFragmentTexture(cells, index: 0)
            enc.setFragmentTexture(atlas?.texture, index: 1)
            enc.setFragmentTexture(ctx.figure, index: 2)
            enc.setFragmentTexture(currentField, index: 3)
            enc.setFragmentTexture(ctx.verses, index: 4)
            enc.setFragmentTexture(wingTextures.isEmpty ? nil : wingTextures[wingIndex], index: 5)
            enc.setFragmentTexture(glowTextures.isEmpty ? nil : glowTextures[wingIndex], index: 6)
            effects.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        /// 画到任意纹理（离屏检查、锁屏快照的 IOSurface）。
        func render(to texture: MTLTexture, scale: CGFloat, now: Double) {
            guard let cb = ctx.queue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            encode(into: pass, width: texture.width, height: texture.height, scale: scale, now: now, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        }

        /// 离屏渲染，返回 BGRA 字节。
        func renderOffscreen(width: Int, height: Int, scale: CGFloat, now: Double) -> [UInt8] {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SeaContext.pixelFormat, width: width, height: height,
                                                                mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            let tex = ctx.device.makeTexture(descriptor: desc)!
            render(to: tex, scale: scale, now: now)
            var out = [UInt8](repeating: 0, count: width * height * 4)
            tex.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            return out
        }

        /// 连续绘制若干帧的 GPU 时间（毫秒，取最小值）。
        func benchmark(width: Int, height: Int, scale: CGFloat, now: Double, frames: Int) -> Double {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SeaContext.pixelFormat, width: width, height: height,
                                                                mipmapped: false)
            desc.usage = [.renderTarget]
            desc.storageMode = .private
            let tex = ctx.device.makeTexture(descriptor: desc)!
            var best = Double.infinity
            for _ in 0..<frames {
                guard let cb = ctx.queue.makeCommandBuffer() else { break }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = tex
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                encode(into: pass, width: width, height: height, scale: scale, now: now, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
                best = min(best, (cb.gpuEndTime - cb.gpuStartTime) * 1000)
            }
            return best
        }
    }
}
