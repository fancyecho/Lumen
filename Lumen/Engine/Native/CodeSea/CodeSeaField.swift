import Foundation

// Ported from Code Sea (Sources/SeaField.swift). The logic is unchanged; types are nested under
// `CodeSea` so their names stay out of Lumen's module namespace.
extension CodeSea {
    /// 画面里所有周期运动都以一小时为大周期：角速度取整到“一小时恰好转整数圈”，
    /// 时间每小时归零（保住 Float 精度）时，海浪、光带、闪光和她的飘动都能无缝接上，不会跳一下。
    /// 着色器里的 hourly() 是同一个规则。
    enum HourLoop {
        static let period: Double = 3600

        /// 最接近 omega（弧度/秒）、且一小时恰好转整数圈的角速度。
        static func omega(_ omega: Double) -> Float {
            Float((omega * period / (2 * .pi)).rounded() * 2 * .pi / period)
        }

        /// 秒数按一小时取模，总是落在 0..<3600。
        static func time(_ seconds: Double) -> Float {
            let r = seconds.truncatingRemainder(dividingBy: period)
            return Float(r < 0 ? r + period : r)
        }
    }

    /// 海面：每个字整体（不变形）随几列长波轻轻漂浮；长波的波峰连成柔和的光带缓缓移动，
    /// 光带里的字反射出白光，波谷里的字略暗。
    /// 浪大体朝同一个方向（朝屏幕下方、朝人涌来，各列只差十几度），波峰连成一道道横向的浪脊；
    /// 屏幕上方是远处：行坐标换成“海面上的距离”，浪往上越来越密、起伏越来越小，像一片朝远处铺开的海。
    /// 另有一列短波，让相邻的字之间也有一点相对起伏，水面才有质感。
    /// 所有三角函数按行/列分离预计算，整屏一帧不到 1 ms。
    final class SeaField {
        let cols: Int
        let rows: Int
        /// 字符格大小（点）。
        let cell: SIMD2<Float>
        private let rnd: [Float]
        /// 每一行在海面上的距离（点，透视换算后）与这一行的起伏幅度比例（远处小）。
        private let rowDepth: [Float]
        private let rowAmp: [Float]

        /// 透视的“地平线”参数：底边每行代表 1 行的海面，顶边约 ((1+h)/h)² ≈ 2.5 行。
        private static let horizon: Float = 1.7

        init(cols: Int, rows: Int, cell: SIMD2<Float>, seed: UInt64) {
            self.cols = cols
            self.rows = rows
            self.cell = cell
            var rng = SplitMix(seed: seed ^ 0xC0FFEE)
            rnd = (0..<(cols * rows)).map { _ in Float(rng.next() % 1_000_000) / 1_000_000 }

            // 网格四周各多一格（第 0 行在屏幕上方外面），高度按屏幕内的行数算。
            let height = Float(max(rows - 2, 1)) * cell.y
            let h = Self.horizon
            var depth = [Float](repeating: 0, count: rows), amp = depth
            for j in 0..<rows {
                let s = max(0, min(1, (Float(j - 1) + 0.5) * cell.y / height))   // 0 顶边 … 1 底边
                // ∫ ((1+h)/(s+h))² dy：底边斜率为 1，往上越来越陡；以底边为 0，往上为负。
                depth[j] = height * (1 + h) * (1 + h) * (1 / (1 + h) - 1 / (s + h))
                amp[j] = (s + h) / (1 + h)
            }
            rowDepth = depth
            rowAmp = amp
        }

        /// 漂浮的波：(kx, ky, 角速度, 振幅, 相位)。前四列是长波（波长约 400~750 点，方向在竖直方向 ±17° 内），
        /// 最后一列是短波（约 120 点）。都朝 +y（屏幕下方）传播。
        private static let swell: [(Float, Float, Float, Float, Float)] = [
            (0.0016, 0.0098, HourLoop.omega(0.40), 0.50, 0.0), (-0.0024, 0.0080, HourLoop.omega(0.33), 0.38, 1.3),
            (0.0030, 0.0128, HourLoop.omega(0.47), 0.25, 4.1), (-0.0014, 0.0160, HourLoop.omega(0.52), 0.15, 2.0),
            (0.0110, 0.0500, HourLoop.omega(1.25), 0.26, 0.7),
        ]
        /// 浪尖：两列短波相乘
        private static let crest: [(Float, Float, Float)] = [(0.041, 0.013, HourLoop.omega(1.25)), (-0.017, 0.035, HourLoop.omega(1.05))]
        private static let sparkleOmega = HourLoop.omega(1.9)

        /// 写出每个字此刻的状态（RGBA16F：x/y 位移像素、转角（保留，恒为 0）、明暗：正为白光、负为变暗）。
        /// t 是按一小时取模的时间（HourLoop.time）。
        func fill(_ out: UnsafeMutablePointer<Float16>, time t: Float, amplitude A: Float, glint: Float, scale: Float) {
            let swell = Self.swell, crest = Self.crest
            let ns = swell.count, nw = ns + crest.count

            var colSin = [[Float]](repeating: [Float](repeating: 0, count: cols), count: nw)
            var colCos = colSin
            var rowSin = [[Float]](repeating: [Float](repeating: 0, count: rows), count: nw)
            var rowCos = rowSin
            for w in 0..<nw {
                let (kx, ky, om, ph): (Float, Float, Float, Float) = w < ns
                    ? (swell[w].0, swell[w].1, swell[w].2, swell[w].4) : (crest[w - ns].0, crest[w - ns].1, crest[w - ns].2, 0)
                for i in 0..<cols {
                    let a = kx * (Float(i - 1) + 0.5) * cell.x - om * t + ph
                    colSin[w][i] = sin(a); colCos[w][i] = cos(a)
                }
                for j in 0..<rows {
                    let b = ky * rowDepth[j]
                    rowSin[w][j] = sin(b); rowCos[w][j] = cos(b)
                }
            }
            let norm: Float = 1 / 1.28
            let dirX: [Float] = swell.map { $0.0 / ($0.0 * $0.0 + $0.1 * $0.1).squareRoot() }
            let maxX = cell.x * 0.9 * scale, maxY = cell.y * 0.9 * scale

            for j in 0..<rows {
                let rowA = A * rowAmp[j] * scale
                for i in 0..<cols {
                    let k = j * cols + i
                    var hgt: Float = 0, ox: Float = 0
                    for w in 0..<ns {
                        let s = colSin[w][i] * rowCos[w][j] + colCos[w][i] * rowSin[w][j]
                        let c = colCos[w][i] * rowCos[w][j] - colSin[w][i] * rowSin[w][j]
                        hgt += swell[w].3 * s
                        ox += swell[w].3 * c * dirX[w] * 0.6
                    }
                    hgt *= norm; ox *= norm
                    let g1 = colSin[ns][i] * rowCos[ns][j] + colCos[ns][i] * rowSin[ns][j]
                    let g2 = colSin[ns + 1][i] * rowCos[ns + 1][j] + colCos[ns + 1][i] * rowSin[ns + 1][j]
                    // 浪尖光带：长波的波峰连成一道道柔和的亮带，随海面缓缓涌来；短波把亮带的边缘打碎，
                    // 每个字只在光带里带一点轻微的闪烁。整片一起明暗，而不是一个个孤立的亮点。
                    var light: Float
                    let band = max(0, min(1, (hgt - 0.28) / 0.62))
                    if band > 0 {
                        let b = band * band * (3 - 2 * band)
                        let detail = 0.55 + 0.45 * (g1 * g2 * 0.5 + 0.5)
                        let sparkle = 0.85 + 0.15 * sin(t * Self.sparkleOmega + rnd[k] * 37)
                        light = b * detail * sparkle * glint * 0.75
                    } else {
                        light = -0.16 * glint * max(0, min(1, (-hgt - 0.15) / 0.7))   // 波谷略暗
                    }
                    out[k * 4] = Float16(min(maxX, max(-maxX, ox * rowA)))
                    out[k * 4 + 1] = Float16(min(maxY, max(-maxY, hgt * rowA)))
                    out[k * 4 + 2] = 0
                    out[k * 4 + 3] = Float16(max(-0.5, min(1, light)))
                }
            }
        }
    }
}
