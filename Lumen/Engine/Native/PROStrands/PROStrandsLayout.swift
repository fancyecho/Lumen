import CoreGraphics
import Foundation

// Ported from PRO Strands (pro-native/Sources/StrandLayout.swift). The logic is unchanged; types are nested under
// `PROStrands` so their names stay out of Lumen's module namespace.
extension PROStrands {
    /// 与着色器里 `Strand` 一致的布局（8 个 Float）。
    struct StrandGPU {
        var restL: Float
        var width: Float
        var z0: Float
        var phase: Float
        var speed: Float
        var glint: Float
        var seed: Float
        var section: Float
    }

    /// 一个光区：源像素坐标的矩形范围。
    struct LightSection {
        var x0: Float
        var x1: Float
        var y0: Float
        var y1: Float
    }

    /// 确定性随机数，保证每次启动拆出的光丝属性一致。
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    }

    /// 从原图直接拆出光丝：原图的每条竖向色带就是一根丝，静止几何即原图本身，
    /// 不再手工重绘 P/R/O 轮廓（第二版的接缝和空档都来自轮廓近似误差）。
    final class StrandLayout {
        let srcWidth: Int
        let srcHeight: Int
        let rows: Int
        let restL: [Float]
        let width: [Float]
        let restCenter: [Float]
        /// 每个源像素列属于哪根丝。
        let restIndex: [Int32]
        /// 每个模拟节点的锚定程度（0 自由 … 1 卷边/顶边，几乎不动），行优先 m * count + i。
        let anchor: [Float]
        /// 每个节点的“成束”程度（0 自由 … 1 整束移动）：卷边、收口和屏幕顶/底边附近，
        /// 光丝紧紧并在一起，应当一起弯、一起回弹，不能各自错开露出黑缝。
        let cohesion: [Float]
        let gpu: [StrandGPU]
        let maxWidth: Float
        /// 空闲流光的光区（见 findSections）。
        let sections: [LightSection]
        /// 在腰部被一分为二的光区索引（上段）；下段是 sections 的最后一个。没有则为 -1。
        let splitSection: Int
        let waistY: Float

        var count: Int { restL.count }
        var rowSpacing: Float { Float(srcHeight) / Float(rows - 1) }

        init(image: CGImage, rows: Int = 128) {
            let w = image.width, h = image.height
            srcWidth = w
            srcHeight = h
            self.rows = rows

            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            pixels.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }

            let segments = StrandLayout.segment(pixels: pixels, width: w, height: h)
            restL = segments.map { Float($0.0) }
            width = segments.map { Float($0.1 - $0.0) }
            restCenter = segments.map { Float($0.0 + $0.1) * 0.5 }
            maxWidth = width.max() ?? 1

            var index = [Int32](repeating: 0, count: w)
            for (i, s) in segments.enumerated() {
                for x in s.0..<s.1 { index[x] = Int32(i) }
            }
            restIndex = index

            anchor = StrandLayout.anchorMap(pixels: pixels, width: w, height: h, segments: segments, rows: rows)
            cohesion = StrandLayout.cohesionMap(anchor: anchor, count: segments.count, rows: rows)
            let found = StrandLayout.findSections(pixels: pixels, width: w, height: h,
                                                  segments: segments, anchor: anchor, rows: rows)
            sections = found.sections
            splitSection = found.split
            waistY = found.waistY
            let columnSections = found.split >= 0 ? found.sections.count - 1 : found.sections.count
            func sectionOf(_ s: (Int, Int)) -> Float {
                let c = Float(s.0 + s.1) / 2
                let k = found.sections.prefix(columnSections).firstIndex { c >= $0.x0 && c < $0.x1 }
                // 黑缝里的“空”丝归到最近的光区，反正是透明的。
                return Float(k ?? found.sections.prefix(columnSections).indices.min {
                    abs(found.sections[$0].x0 - c) < abs(found.sections[$1].x0 - c)
                } ?? 0)
            }

            var rng = SplitMix64(seed: 0x5052_4F5F_4C49_4E45)
            gpu = segments.map { s in
                let glintRoll = rng.unit()
                return StrandGPU(restL: Float(s.0), width: Float(s.1 - s.0),
                                 z0: rng.unit(), phase: rng.unit(),
                                 speed: 0.018 + 0.05 * rng.unit(),
                                 glint: glintRoll > 0.6 ? 0.35 + 0.65 * rng.unit() : 0,
                                 seed: rng.unit(), section: sectionOf(s))
            }
        }

        /// 按列间颜色跳变找色带边界。只统计竖直方向平滑的像素，卷边不干扰判断。
        private static func segment(pixels: [UInt8], width w: Int, height h: Int) -> [(Int, Int)] {
            var num = [Double](repeating: 0, count: w - 1)
            var den = [Double](repeating: 0, count: w - 1)
            pixels.withUnsafeBufferPointer { p in
                for y in 0..<(h - 1) {
                    let row = y * w * 4, next = (y + 1) * w * 4
                    for x in 0..<(w - 1) {
                        let o = row + x * 4
                        let dx = abs(Int(p[o + 4]) - Int(p[o])) + abs(Int(p[o + 5]) - Int(p[o + 1]))
                            + abs(Int(p[o + 6]) - Int(p[o + 2]))
                        let n = next + x * 4
                        let dy = abs(Int(p[n]) - Int(p[o])) + abs(Int(p[n + 1]) - Int(p[o + 1]))
                            + abs(Int(p[n + 2]) - Int(p[o + 2]))
                        let wv = exp(-Double(dy) / 255.0 * 30.0)
                        num[x] += Double(dx) / 255.0 * wv
                        den[x] += wv
                    }
                }
            }
            let b = zip(num, den).map { $0 / ($1 + 1e-6) }
            let threshold = b.sorted()[b.count / 2] * 0.6

            var edges = [0]
            for x in 1..<(b.count - 1) where b[x] >= b[x - 1] && b[x] > b[x + 1] && b[x] > threshold {
                edges.append(x + 1)
            }
            edges.append(w)

            var merged: [(Int, Int)] = []
            for k in 0..<(edges.count - 1) {
                let s = (edges[k], edges[k + 1])
                if let last = merged.last, s.1 - s.0 < 2 || last.1 - last.0 < 2 {
                    merged[merged.count - 1].1 = s.1
                } else {
                    merged.append(s)
                }
            }

            var result: [(Int, Int)] = []
            for (a, c) in merged {
                let span = c - a
                let pieces = max(1, Int((Double(span) / 10).rounded(.up)))
                for k in 0..<pieces {
                    result.append((a + span * k / pieces, a + span * (k + 1) / pieces))
                }
            }
            return result
        }

        /// 光区：被贯穿上半部的竖向黑缝隔开的每一束丝（P 的竖与弧、R 的竖与右半、O 的左右两半）。
        /// R 右半在腰部收口处再分成上下两段。发布会里的空闲动画就是这些光区轮流被点亮。
        private static func findSections(pixels: [UInt8], width w: Int, height h: Int,
                                         segments: [(Int, Int)], anchor: [Float], rows: Int)
            -> (sections: [LightSection], split: Int, waistY: Float) {
            func lum(_ x: Int, _ y: Int) -> Float {
                let o = (y * w + x) * 4
                return (Float(pixels[o]) + Float(pixels[o + 1]) + Float(pixels[o + 2])) / 765
            }
            let scanRows = Int(Float(h) * 0.7)
            var gaps: [(Int, Int)] = []
            var start: Int?
            for x in 0...w {
                var dark = false
                if x < w {
                    var n = 0
                    for y in stride(from: 0, to: scanRows, by: 2) where lum(x, y) < 0.035 { n += 1 }
                    dark = Float(n) / Float(scanRows / 2) > 0.55
                }
                if dark, start == nil { start = x }
                if !dark, let s = start {
                    if x - s >= 5 { gaps.append((s, x)) }
                    start = nil
                }
            }
            var bounds: [(Int, Int)] = []
            var left = 0
            for g in gaps + [(w, w)] {
                if g.0 - left >= 40 { bounds.append((left, g.0)) }
                left = g.1
            }
            if bounds.isEmpty { bounds = [(0, w)] }

            var sections: [LightSection] = bounds.map { b in
                var y0 = h, y1 = 0
                // 这一行有三成以上的列是光丝（不是纯黑背景），才算在光区里。
                for y in stride(from: 0, to: h, by: 2) {
                    var lit = 0, total = 0
                    for x in stride(from: b.0, to: b.1, by: 3) {
                        total += 1
                        if lum(x, y) > 0.03 { lit += 1 }
                    }
                    if Float(lit) / Float(max(total, 1)) > 0.35 { y0 = min(y0, y); y1 = max(y1, y) }
                }
                if y0 > y1 { y0 = 0; y1 = h }
                return LightSection(x0: Float(b.0), x1: Float(b.1), y0: Float(y0), y1: Float(min(h, y1 + 2)))
            }

            // 腰部：中段锚定最强的那一束，从锚定最强的那一行一分为二。
            let n = segments.count
            let spacing = Float(h) / Float(rows - 1)
            var best = (index: -1, row: 0, value: Float(0))
            for (k, sec) in sections.enumerated() {
                let members = segments.indices.filter {
                    let c = Float(segments[$0].0 + segments[$0].1) / 2
                    return c >= sec.x0 && c < sec.x1
                }
                guard !members.isEmpty else { continue }
                for r in Int(Float(rows) * 0.3)..<Int(Float(rows) * 0.7) {
                    var s: Float = 0
                    for i in members { s += anchor[r * n + i] }
                    let v = s / Float(members.count)
                    if v > best.value { best = (k, r, v) }
                }
            }
            guard best.index >= 0, best.value > 0.35 else { return (sections, -1, 0) }
            let waist = Float(best.row) * spacing
            let upper = sections[best.index]
            sections[best.index] = LightSection(x0: upper.x0, x1: upper.x1, y0: upper.y0, y1: waist)
            sections.append(LightSection(x0: upper.x0, x1: upper.x1, y0: waist, y1: upper.y1))
            return (sections, best.index, waist)
        }

        /// 离锚点（卷边/收口）越近越成束，按高斯衰减；屏幕顶边和底边同样处理。
        private static func cohesionMap(anchor: [Float], count n: Int, rows: Int) -> [Float] {
            let sigmaRows: Float = 6
            let reach = Int(sigmaRows * 2.5)
            var c = [Float](repeating: 0, count: rows * n)
            for m in 0..<rows {
                let top = Float(m) / sigmaRows, bottom = Float(rows - 1 - m) / sigmaRows
                let edge = max(exp(-top * top), exp(-bottom * bottom))
                for i in 0..<n {
                    var v = edge
                    for k in max(0, m - reach)...min(rows - 1, m + reach) {
                        let a = anchor[k * n + i]
                        if a <= v { continue }
                        let t = Float(k - m) / sigmaRows
                        v = max(v, a * exp(-t * t))
                    }
                    c[m * n + i] = v
                }
            }
            // 横向轻微平滑，避免相邻两根丝一根成束、一根自由。
            var out = c
            for m in 0..<rows {
                for i in 0..<n {
                    var s: Float = 0, w: Float = 0
                    for k in max(0, i - 3)...min(n - 1, i + 3) { s += c[m * n + k]; w += 1 }
                    out[m * n + i] = max(c[m * n + i] * 0.6, s / w)
                }
            }
            return out
        }

        /// 竖向梯度占比高的地方是卷边、腰部收口和顶/底边：丝在那里转弯，应当钉住。
        private static func anchorMap(pixels: [UInt8], width w: Int, height h: Int,
                                      segments: [(Int, Int)], rows: Int) -> [Float] {
            var lum = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) {
                lum[i] = (Float(pixels[i * 4]) + Float(pixels[i * 4 + 1]) + Float(pixels[i * 4 + 2])) / 765
            }
            let n = segments.count
            let spacing = Float(h) / Float(rows - 1)
            var gy = [Float](repeating: 0, count: rows * n)
            var gx = [Float](repeating: 0, count: rows * n)
            var ry = [Float](repeating: 0, count: w)
            var rx = [Float](repeating: 0, count: w)

            for m in 0..<rows {
                let y0 = max(0, Int(Float(m) * spacing - spacing / 2))
                let y1 = min(h - 2, Int(Float(m) * spacing + spacing / 2)) + 1
                for x in 0..<w { ry[x] = 0; rx[x] = 0 }
                for y in y0..<y1 {
                    let r = y * w
                    for x in 0..<(w - 1) {
                        ry[x] += abs(lum[r + w + x] - lum[r + x])
                        rx[x] += abs(lum[r + x + 1] - lum[r + x])
                    }
                }
                let rowsInBand = Float(y1 - y0)
                for (i, s) in segments.enumerated() {
                    let a = max(0, s.0 - 3), c = min(w - 1, s.1 + 3)
                    var sy: Float = 0, sx: Float = 0
                    for x in a..<c { sy += ry[x]; sx += rx[x] }
                    let k = Float(c - a) * rowsInBand
                    gy[m * n + i] = sy / k
                    gx[m * n + i] = sx / k
                }
            }

            func blur(_ src: [Float], radiusX: Int, radiusY: Int) -> [Float] {
                var tmp = src
                for m in 0..<rows {
                    for i in 0..<n {
                        var s: Float = 0, c: Float = 0
                        for k in max(0, i - radiusX)...min(n - 1, i + radiusX) { s += src[m * n + k]; c += 1 }
                        tmp[m * n + i] = s / c
                    }
                }
                var out = tmp
                for m in 0..<rows {
                    for i in 0..<n {
                        var s: Float = 0, c: Float = 0
                        for k in max(0, m - radiusY)...min(rows - 1, m + radiusY) { s += tmp[k * n + i]; c += 1 }
                        out[m * n + i] = s / c
                    }
                }
                return out
            }

            let gyb = blur(gy, radiusX: 8, radiusY: 1)
            let gxb = blur(gx, radiusX: 8, radiusY: 1)
            return zip(gyb, gxb).map { y, x in
                let ratio = y / (x + y + 0.004)
                return min(1, max(0, (ratio - 0.17) / 0.2))
            }
        }
    }
}
