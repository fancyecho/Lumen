import Foundation
import simd

// Ported from PRO Strands (pro-native/Sources/StrandSim.swift). The logic is unchanged; types are nested under
// `PROStrands` so their names stay out of Lumen's module namespace.
extension PROStrands {
    struct SimParams: Equatable {
        var strength: Float = 32   // 拨动强度 0…100
        var radius: Float = 22     // 作用范围 0…100
        var depth: Float = 50      // 分层深度 0…100
        var twist: Float = 40      // 光丝扭转 0…100
        var recovery: Float = 55   // 回弹速度 0…100
    }

    /// 指针在原图坐标系（源像素）中的状态。
    struct PointerSample {
        var position = SIMD2<Float>(0, 0)
        var present = false
        var pressed = false
    }

    /// 每根丝是一条沿竖直方向的弹性链（128 个节点），只做横向位移和绕自身轴的扭转。
    ///
    /// 让“独立光丝”成立又不出大黑洞的几条约束：
    /// - 每根丝的刚度、打滑阈值各不相同，回弹时各自振动；
    /// - 指针像一根细梳齿：能勾住丝往一边推，推过阈值丝就从下面滑脱、弹回（拨弦感）；
    /// - 同一行相邻丝保持顺序且不分离过远：被推的丝会挤压邻居，但空隙最多比丝宽大一点；
    /// - 卷边、腰部收口和顶/底边由原图自动检测出来并钉住，轮廓始终是原图的轮廓。
    final class StrandSim {
        let layout: StrandLayout
        let n: Int
        let m: Int
        private(set) var active = false

        /// 上传给 GPU 的节点数据：(d, θ, slope, z)，行优先。
        private(set) var packed: [Float16]
        /// 每 8 根丝 × 每行一格：这一格有没有可见的位移/扭转。着色器据此只在真正动的地方走光丝路径。
        static let blockSize = 8
        let blocks: Int
        private(set) var activity: [UInt8]

        private var d: [Float]
        private var v: [Float]
        private var th: [Float]
        private var tv: [Float]
        private let kMul: [Float]
        private let slipMul: [Float]
        private let z0: [Float]
        private var side: [Int8]
        private var released: [Bool]

        private var lo = 0
        private var hi = -1
        private var dirtyLo = 0
        private var dirtyHi = -1
        private var quiet: Float = 0
        private var lastPointer: SIMD2<Float>?
        private var fingerVel = SIMD2<Float>(0, 0)
        private var wasPressed = false

        var params = SimParams()

        /// 当前可能非零的丝（含上一帧刚清零的范围，保证清零那一帧也被正确绘制）。
        /// 空范围时 hi < lo。
        var activeStrands: (lo: Int, hi: Int) {
            let a = min(dirtyLo, lo), b = max(dirtyHi, hi)
            return a <= b ? (max(0, a), min(n - 1, b)) : (0, -1)
        }

        init(layout: StrandLayout) {
            self.layout = layout
            n = layout.count
            m = layout.rows
            let total = n * m
            d = [Float](repeating: 0, count: total)
            v = d
            th = d
            tv = d
            packed = [Float16](repeating: 0, count: total * 4)
            blocks = (n + StrandSim.blockSize - 1) / StrandSim.blockSize
            activity = [UInt8](repeating: 0, count: blocks * m)
            side = [Int8](repeating: 0, count: n)
            released = [Bool](repeating: false, count: n)
            var rng = SplitMix64(seed: 0x4649_4245_5253)
            kMul = (0..<n).map { _ in 0.62 + 0.76 * rng.unit() }
            slipMul = (0..<n).map { _ in 0.55 + 0.9 * rng.unit() }
            z0 = layout.gpu.map { $0.z0 }
            for i in 0..<n {
                for r in 0..<m { packed[(r * n + i) * 4 + 3] = Float16(z0[i] * 0.25) }
            }
        }

        // MARK: - 参数映射

        private var maxDisplacement: Float { 18 + params.strength * 0.85 }
        private var slipBase: Float { 8 + params.strength * 0.42 }
        private var sigma: Float { 26 + params.radius * 1.3 }

        private func fingerRadius(pressed: Bool, speedFactor: Float) -> Float {
            pressed ? 8 + params.radius * 0.3 : (3 + params.radius * 0.14) * speedFactor
        }

        private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }

        // MARK: - 推进

        /// 返回本帧是否有需要上传的变化。
        @discardableResult
        func advance(dt rawDt: Float, pointer: PointerSample) -> Bool {
            let dt = min(max(rawDt, 1 / 240), 1 / 15)
            let present = pointer.present
            let previous = present ? (lastPointer ?? pointer.position) : pointer.position
            if present, lastPointer != nil {
                let raw = (pointer.position - previous) / dt
                fingerVel = fingerVel + (raw - fingerVel) * 0.6
            } else {
                fingerVel = .zero
            }
            let speed = simd_length(fingerVel)
            let pressed = present && pointer.pressed
            let click = pressed && !wasPressed
            let hoverFactor = StrandSim.smoothstep(20, 320, speed)
            let contact = present && (pressed || hoverFactor > 0.02)

            lastPointer = present ? pointer.position : nil
            wasPressed = pressed

            if contact || click {
                active = true
                quiet = 0
                includeRange(around: pointer.position.x, previous: previous.x)
            }
            guard active else { return false }

            dirtyLo = lo
            dirtyHi = hi
            let substeps = max(1, Int((dt * 120).rounded(.up)))
            let h = dt / Float(substeps)
            for s in 0..<substeps {
                let t1 = Float(s + 1) / Float(substeps)
                let t0 = Float(s) / Float(substeps)
                let fPrev = previous + (pointer.position - previous) * t0
                let fCur = previous + (pointer.position - previous) * t1
                if click && s == 0 { impulse(at: fCur) }
                if contact {
                    drag(at: fCur, velocity: fingerVel, factor: pressed ? 1 : hoverFactor, h: h)
                }
                integrate(h: h)
                if contact {
                    collide(finger: fCur, previous: fPrev,
                            radius: fingerRadius(pressed: pressed, speedFactor: hoverFactor),
                            pressed: pressed)
                } else {
                    for i in lo...max(lo, hi) where i < n { side[i] = 0; released[i] = false }
                }
                constrain(finger: contact ? fCur : nil, radius: fingerRadius(pressed: pressed, speedFactor: hoverFactor))
                bundle()
                updateTwist(h: h)
            }
            shrinkRange(contact: contact, dt: dt)
            pack()
            return true
        }

        private func includeRange(around x: Float, previous px: Float) {
            let reach = sigma * 2.6 + maxDisplacement + layout.maxWidth
            let a = layout.restIndex[max(0, min(layout.srcWidth - 1, Int(min(x, px) - reach)))]
            let b = layout.restIndex[max(0, min(layout.srcWidth - 1, Int(max(x, px) + reach)))]
            if hi < lo {
                lo = Int(a)
                hi = Int(b)
            } else {
                lo = min(lo, Int(a))
                hi = max(hi, Int(b))
            }
        }

        // MARK: - 力

        private func impulse(at p: SIMD2<Float>) {
            let sig = sigma * 0.9
            let strength = 140 + params.strength * 5
            let rowSpacing = layout.rowSpacing
            let r0 = max(0, Int((p.y - sig * 2.5) / rowSpacing)), r1 = min(m - 1, Int((p.y + sig * 2.5) / rowSpacing) + 1)
            guard r0 <= r1 else { return }
            for r in r0...r1 {
                let dy = Float(r) * rowSpacing - p.y
                for i in lo...hi {
                    let x = layout.restCenter[i] + d[r * n + i]
                    let dx = x - p.x
                    let w = exp(-(dx * dx + dy * dy) / (2 * sig * sig))
                    if w < 0.01 { continue }
                    let a = layout.anchor[r * n + i]
                    v[r * n + i] += (dx >= 0 ? 1 : -1) * strength * w * (1 - a)
                }
            }
        }

        private func drag(at p: SIMD2<Float>, velocity: SIMD2<Float>, factor: Float, h: Float) {
            let sx = sigma, sy = sigma * 1.35
            let mu = params.strength / 50 * 22 * factor
            let gain: Float = 0.4
            let target = velocity.x * gain
            let rowSpacing = layout.rowSpacing
            let r0 = max(0, Int((p.y - sy * 2.6) / rowSpacing)), r1 = min(m - 1, Int((p.y + sy * 2.6) / rowSpacing) + 1)
            guard r0 <= r1, mu > 0 else { return }
            for r in r0...r1 {
                let dy = Float(r) * rowSpacing - p.y
                let wy = exp(-dy * dy / (2 * sy * sy))
                if wy < 0.01 { continue }
                for i in lo...hi {
                    let idx = r * n + i
                    let dx = layout.restCenter[i] + d[idx] - p.x
                    let w = wy * exp(-dx * dx / (2 * sx * sx))
                    if w < 0.01 { continue }
                    let k = (1 - exp(-mu * w * h)) * (1 - layout.anchor[idx])
                    v[idx] += (target - v[idx]) * k
                }
            }
        }

        // MARK: - 积分

        private func integrate(h: Float) {
            guard hi >= lo else { return }
            let omega = 2 * Float.pi * (0.55 + params.recovery / 100 * 1.5)
            let k0 = omega * omega
            let gamma = 2 * 0.2 * omega
            // 沿丝的黏性阻尼：压掉高阶小弯（S 形抖动），保留整根丝的大弯和回弹。
            let viscosity: Float = 30
            let waveSpeed: Float = 1350
            let rs = layout.rowSpacing
            let tension = waveSpeed * waveSpeed / (rs * rs)
            let coupling = k0 * 1.4
            let n = self.n, m = self.m
            let lo = self.lo, hi = self.hi

            let vOld = v
            d.withUnsafeBufferPointer { dp in
                vOld.withUnsafeBufferPointer { vo in
                v.withUnsafeMutableBufferPointer { vp in
                    layout.anchor.withUnsafeBufferPointer { ap in
                        layout.cohesion.withUnsafeBufferPointer { cp in
                        kMul.withUnsafeBufferPointer { kp in
                            for r in 0..<m {
                                let row = r * n
                                for i in lo...hi {
                                    let idx = row + i
                                    let di = dp[idx]
                                    let up = r > 0 ? dp[idx - n] : di
                                    let dn = r < m - 1 ? dp[idx + n] : di
                                    let lf = i > 0 ? dp[idx - 1] : di
                                    let rt = i < n - 1 ? dp[idx + 1] : di
                                    let a = ap[idx]
                                    let co = cp[idx]
                                    let vi = vo[idx]
                                    let vu = r > 0 ? vo[idx - n] : vi
                                    let vd = r < m - 1 ? vo[idx + n] : vi
                                    let acc = -k0 * kp[i] * (1 + 28 * a + 3 * co) * di
                                        + viscosity * (vu + vd - 2 * vi)
                                        + tension * (1 - 0.5 * a) * (up + dn - 2 * di)
                                        + coupling * (lf + rt - 2 * di)
                                        - gamma * (1 + 5 * a) * vp[idx]
                                    vp[idx] += acc * h
                                }
                            }
                        }
                        }
                    }
                }
                }
            }
            let limit = maxDisplacement
            d.withUnsafeMutableBufferPointer { dp in
                v.withUnsafeBufferPointer { vp in
                    for r in 0..<m {
                        let row = r * n
                        for i in lo...hi {
                            let idx = row + i
                            dp[idx] = min(limit, max(-limit, dp[idx] + vp[idx] * h))
                        }
                    }
                }
            }
        }

        // MARK: - 指针碰撞（梳齿）

        /// 接触沿丝方向的高斯宽度。至少三个节点间距：弯曲的顶点由多个节点共同撑起，才是圆弧而不是折角。
        private func contactSigma(radius rc: Float) -> Float {
            max(rc * 3.5, layout.rowSpacing * 3.0)
        }

        private func collide(finger p: SIMD2<Float>, previous: SIMD2<Float>, radius rc: Float, pressed: Bool) {
            guard rc > 0.5 else { return }
            let rs = layout.rowSpacing
            // 接触沿丝方向是高斯形：中间推得最开，往上下平滑收拢，分开的缝两端是圆润的尖，
            // 不会只在一两个节点上被推开、折成直线和尖角。
            let sigmaY = contactSigma(radius: rc)
            let reach = sigmaY * 2.6
            let r0 = max(0, Int(((p.y - reach) / rs).rounded(.up))), r1 = min(m - 1, Int((p.y + reach) / rs))
            let slipLimit = slipBase * (pressed ? 1.6 : 1)
            let span = rc + maxDisplacement + layout.maxWidth
            let a = Int(layout.restIndex[max(0, min(layout.srcWidth - 1, Int(p.x - span)))])
            let b = Int(layout.restIndex[max(0, min(layout.srcWidth - 1, Int(p.x + span)))])
            let i0 = max(a, lo), i1 = min(b, hi)
            guard i0 <= i1 else { return }

            for i in i0...i1 {
                let c = layout.restCenter[i]
                if released[i] {
                    var near = false
                    if r0 <= r1 {
                        for r in r0...r1 where abs(c + d[r * n + i] - p.x) < rc + 3 { near = true }
                    }
                    if !near { released[i] = false; side[i] = 0 }
                    continue
                }
                var touched = false
                if r0 <= r1 {
                    for r in r0...r1 {
                        let idx = r * n + i
                        let ey = (Float(r) * rs - p.y) / sigmaY
                        let profile = exp(-0.5 * ey * ey)
                        guard profile > 0.04 else { continue }
                        let halfW = (rc + layout.width[i] * 0.5) * profile
                        let x = c + d[idx]
                        if side[i] == 0 {
                            // 只在接触的中段决定往哪边推，免得被尾部的轻触随机分边。
                            guard profile > 0.5, abs(x - p.x) < halfW else { continue }
                            side[i] = x >= previous.x ? 1 : -1
                        }
                        let target = p.x + Float(side[i]) * halfW
                        let inside = side[i] > 0 ? x < target : x > target
                        guard inside else { continue }
                        if profile > 0.3 { touched = true }
                        let need = target - c
                        let bound = max(layout.anchor[idx], 0.8 * layout.cohesion[idx])
                        if abs(need) > slipLimit * slipMul[i] * (1 - 0.7 * bound) {
                            // 推得太远：丝从梳齿下滑脱，自己弹回去。
                            released[i] = true
                            side[i] = 0
                            break
                        }
                        let a = layout.anchor[idx]
                        // 接触中段几乎完全贴住指尖的圆弧轮廓，两端渐弱；张力只负责外侧的过渡。
                        let follow = min(1, profile * 1.6) * (1 - a)
                        d[idx] += (need - d[idx]) * follow
                        v[idx] += (fingerVel.x - v[idx]) * 0.5 * follow
                    }
                }
                if !touched && side[i] != 0 {
                    var far = true
                    if r0 <= r1 {
                        for r in r0...r1 where abs(c + d[r * n + i] - p.x) < rc + 3 { far = false }
                    }
                    if far { side[i] = 0 }
                }
            }
        }

        // MARK: - 顺序与间距

        private func constrain(finger: SIMD2<Float>?, radius rc: Float) {
            guard hi > lo else { return }
            let rs = layout.rowSpacing
            let spread = 0.55 + params.depth / 100 * 0.6
            d.withUnsafeMutableBufferPointer { dp in
                for r in 0..<m {
                    let row = r * n
                    let y = Float(r) * rs
                    // 指尖撑开的缝在整个接触高度内都不受“相邻丝不能分太远”的约束，
                    // 否则只有正中一行能张开，缝会变成一个单行的尖刺。
                    let fingerHere = finger.map { abs($0.y - y) < contactSigma(radius: rc) * 2.6 } ?? false
                    let fx = finger?.x ?? 0
                    // 正向 + 反向各一遍：不交叉、最小间距。
                    for i in (lo + 1)...hi {
                        let li = layout.restL[i] + dp[row + i]
                        let lp = layout.restL[i - 1] + dp[row + i - 1]
                        let minGap = layout.width[i - 1] * 0.32
                        if li - lp < minGap {
                            let c = (minGap - (li - lp)) * 0.5
                            dp[row + i - 1] -= c
                            dp[row + i] += c
                        }
                    }
                    for i in stride(from: hi, to: lo, by: -1) {
                        let li = layout.restL[i] + dp[row + i]
                        let lp = layout.restL[i - 1] + dp[row + i - 1]
                        let minGap = layout.width[i - 1] * 0.32
                        if li - lp < minGap {
                            let c = (minGap - (li - lp)) * 0.5
                            dp[row + i - 1] -= c
                            dp[row + i] += c
                        }
                        // 软性最大间距：相邻丝不会被拉开成大洞（梳齿正在穿过的那条缝除外）。
                        let co = layout.cohesion[row + i]
                        let maxGap = layout.width[i - 1] * (1 + spread * (1 - co))
                        let gap = li - lp
                        if gap > maxGap {
                            if fingerHere && lp < fx && li > fx && co < 0.5 { continue }
                            let c = (gap - maxGap) * (0.35 + 0.15 * co)
                            dp[row + i - 1] += c
                            dp[row + i] -= c
                        }
                    }
                }
            }
        }

        // MARK: - 成束

        /// 成束区里把每根丝的位移和速度拉向左右邻居的平均：整束一起弯，丝与丝之间不错开。
        private func bundle() {
            guard hi > lo else { return }
            for _ in 0..<2 {
                for r in 0..<m {
                    let row = r * n
                    for i in lo...hi {
                        let c = layout.cohesion[row + i]
                        if c < 0.02 { continue }
                        var sd: Float = 0, sv: Float = 0
                        for k in (i - 2)...(i + 2) {
                            let kk = min(n - 1, max(0, k))
                            sd += d[row + kk]
                            sv += v[row + kk]
                        }
                        let w = min(1, c * 1.1)
                        d[row + i] += (sd / 5 - d[row + i]) * w
                        v[row + i] += (sv / 5 - v[row + i]) * w
                    }
                }
            }
        }

        // MARK: - 扭转

        private func updateTwist(h: Float) {
            guard hi >= lo else { return }
            let amount = params.twist / 100
            let rs = layout.rowSpacing
            let k: Float = 170, damping: Float = 2 * 0.32 * (170 as Float).squareRoot()
            for r in 0..<m {
                let row = r * n
                for i in lo...hi {
                    let idx = row + i
                    let up = r > 0 ? d[idx - n] : d[idx]
                    let dn = r < m - 1 ? d[idx + n] : d[idx]
                    let slope = (dn - up) / (2 * rs)
                    let a = max(layout.anchor[idx], layout.cohesion[idx])
                    let target = amount * (1.25 * tanh(v[idx] / 320) + 0.7 * tanh(slope * 2.2)) * (1 - a)
                    tv[idx] += (-k * (th[idx] - target) - damping * tv[idx]) * h
                    th[idx] = min(1.3, max(-1.3, th[idx] + tv[idx] * h))
                }
            }
        }

        // MARK: - 收尾

        private func shrinkRange(contact: Bool, dt: Float) {
            guard hi >= lo else { active = false; return }
            var newLo = Int.max, newHi = Int.min
            var peak: Float = 0
            for i in lo...hi {
                var amp: Float = 0
                for r in 0..<m {
                    let idx = r * n + i
                    amp = max(amp, abs(d[idx]) + abs(v[idx]) * 0.02 + abs(th[idx]) * 20)
                }
                peak = max(peak, amp)
                if amp > 0.02 {
                    newLo = min(newLo, i)
                    newHi = max(newHi, i)
                }
            }
            if contact || peak > 0.05 {
                quiet = 0
            } else {
                quiet += dt
            }
            if quiet > 0.35 || newLo > newHi {
                if !contact {
                    zero(from: lo, to: hi)
                    lo = 0
                    hi = -1
                    active = false
                    return
                }
            }
            if newLo <= newHi {
                let keepLo = max(0, newLo - 10), keepHi = min(n - 1, newHi + 10)
                if !contact {
                    if keepLo > lo { zero(from: lo, to: keepLo - 1) }
                    if keepHi < hi { zero(from: keepHi + 1, to: hi) }
                    lo = keepLo
                    hi = keepHi
                }
            }
        }

        /// 调试：某根丝在各行的位移。
        func debugDisplacement(strand i: Int) -> [Float] { (0..<m).map { d[$0 * n + i] } }

        /// 测试用：状态全零但标记为活动，让渲染走光丝合成路径，用来核对静止保真。
        func forceZeroActive() {
            zero(from: 0, to: n - 1)
            dirtyLo = 0
            dirtyHi = n - 1
            lo = 0
            hi = n - 1
            pack()
            for k in activity.indices { activity[k] = 1 }
            lo = 0
            hi = -1
            active = true
        }

        /// 立即停止并清零（暂停壁纸时用）。
        func reset() {
            zero(from: 0, to: n - 1)
            dirtyLo = 0
            dirtyHi = n - 1
            lo = 0
            hi = n - 1
            pack()
            lo = 0
            hi = -1
            active = false
            lastPointer = nil
            wasPressed = false
        }

        private func zero(from a: Int, to b: Int) {
            guard a <= b else { return }
            for r in 0..<m {
                for i in a...b {
                    let idx = r * n + i
                    d[idx] = 0; v[idx] = 0; th[idx] = 0; tv[idx] = 0
                }
            }
            for i in a...b { side[i] = 0; released[i] = false }
        }

        /// 当前最大位移（加上约束可能的少量超出），渲染时用来缩小查找窗口。
        private(set) var maxAbsDisplacement: Float = 0

        private func pack() {
            let a = min(dirtyLo, lo), b = max(dirtyHi, hi)
            guard a <= b, a >= 0 else { return }
            var peak: Float = 0
            let rs = layout.rowSpacing
            let depth = params.depth / 100
            for r in 0..<m {
                for i in a...min(b, n - 1) {
                    let idx = r * n + i
                    let up = r > 0 ? d[idx - n] : d[idx]
                    let dn = r < m - 1 ? d[idx + n] : d[idx]
                    let slope = (dn - up) / (2 * rs)
                    let z = z0[i] * 0.25 - depth * min(abs(d[idx]) / 14, 2) * 0.5
                    let o = idx * 4
                    peak = max(peak, abs(d[idx]))
                    packed[o] = Float16(d[idx])
                    packed[o + 1] = Float16(th[idx])
                    packed[o + 2] = Float16(slope)
                    packed[o + 3] = Float16(z)
                }
            }
            maxAbsDisplacement = peak + 1

            let bs = StrandSim.blockSize
            for blk in (a / bs)...(min(b, n - 1) / bs) {
                let i0 = blk * bs, i1 = min(n - 1, i0 + bs - 1)
                for r in 0..<m {
                    var on: UInt8 = 0
                    for i in i0...i1 {
                        let idx = r * n + i
                        if abs(d[idx]) > 0.02 || abs(th[idx]) > 0.001 { on = 1; break }
                    }
                    activity[r * blocks + blk] = on
                }
            }
        }
    }
}
