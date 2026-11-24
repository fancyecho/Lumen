import Foundation
import simd

// Ported from Code Sea (Sources/Wings.swift). The logic is unchanged; types are nested under
// `CodeSea` so their names stay out of Lumen's module namespace.
extension CodeSea {
    /// 她的翅膀：一对由光和经文组成的羽翼，从她肩胛后长出，一直伸到屏幕两侧（最外几根飞羽伸出画框），
    /// 和她竖直的身形构成十字。光环上写着“推动太阳和其余群星的爱”，翅膀就是那些“其余的星”。
    ///
    /// 形：前缘从肩胛升到腕关节（约在光环中心的高度）、圆滑地转平，再缓缓上扬伸向屏幕边缘。前缘是一条有厚度的光带
    /// （肩部最厚、往翼尖渐细），只在上沿描一道亮线。羽分三层，各有各的形：小覆羽、大覆羽是两排圆鳞片，
    /// 圆圆的下缘一排排垂在前缘带下面；次级飞羽宽而钝圆，彼此叠压，圆头连成一道波浪形的后缘；
    /// 初级飞羽长而尖，扇形展开，往外渐疏，最外两根伸出画框。每片羽有清楚的轮廓，前层盖住后层，
    /// 羽轴只是一道细筋；羽毛微微向外弯，每根的角度、长短、宽窄都带一点不规则。
    /// 光：前缘带最亮，往后一层比一层暗；色温从根部的近白到羽身的香槟金，再到初级飞羽尖端的银蓝，融进夜海。
    /// 两边腕关节各缀一颗四芒主星，肩胛后的辉光从她身体两侧溢出来。
    /// 字：前缘带和每根飞羽上各是一行经文（钦定本，公有领域），从羽毛露出来的地方读起；羽片照亮落在其中的海面字。
    ///
    /// 动：翅膀长在她身上，跟着她上下飘浮、轻轻摆动。
    /// 预备（肩胛后两点光聚起，周围的海略暗）→ 破（两点光闪白，一道环形波扫过海面）→ 展（前缘先快后慢地射出，
    /// 羽毛贴着前缘收拢，前缘经过后才像折扇一样转下来，初级飞羽转过头再弹回）→ 振（先微微上提，再一下压下去：
    /// 从肩部传到翼尖，像鞭梢；羽尖被气流压弯；回弹时略过头再落定；她被这一下托高一点，慢慢落回；
    /// 一道金光顺着浪尖从翼下推开）→ 驻（约 10 秒一次呼吸，吸慢呼快，一道缓波从肩部传到翼尖；
    /// 每根羽各有各的微风颤动；约 45 秒一阵抖羽从根部掠到翼尖；偶尔一道光沿羽轴跑到尖端，偶尔一个字从翼尖脱落飘走）
    /// → 收（像扇子合上：外侧先转回、贴向前缘，光从翼尖收回背后，化作往上飘的光点）。
    ///
    /// 每帧在 CPU 上算好：字缝里的光写进一张半格大小的光纹理——羽片的亮度与色温（前层按遮挡盖住后层），
    /// 以及最近那道线（轮廓或羽轴）的有向距离和亮度，着色器只采样一次就能画出细到一两个像素的轮廓；
    /// 羽毛多少不影响 GPU。羽轴上的字写进字符格纹理。只有两颗腕星、根部辉光和冲击波在着色器里按参数现算。
    final class Wings {
        enum Tier { case lesserCovert, greaterCovert, secondary, primary }

        struct Feather {
            let tier: Tier
            /// 沿翼骨的位置（0 肩胛 … 1 屏幕边缘）、静止时与竖直向下的夹角（度，向外为正）、长度与半宽（屏幕高度的比例）。
            let xn: Float, angle: Float, length: Float, width: Float
            /// 飞羽在本层从内到外的序号（取经文用）；覆羽为 -1。
            let slot: Int
            /// 微风颤动的两个相位。
            let phase: SIMD2<Float>
            /// 翼指（0 … 1）：最外几根初级飞羽彼此分开，外半段收窄成一根手指，羽尖更往上翘。
            var finger: Float = 0
        }

        /// 每层的样子与动作。fill/rim/shaft：羽片、轮廓、羽轴多亮；glyph：羽轴上的字多亮；cool：尖端偏冷多少；
        /// warm：羽身的色温；bend：羽尖向外弯多少（长度的比例）；tipStart：从哪里开始收成椭圆形的羽尖（沿羽的比例）；
        /// drop：根部在前缘下面多深（前缘带厚度的倍数）；glyphFrom：字从哪里读起（被覆羽盖住的部分不写）；
        /// zeta/omega/delay：展开时的弹簧（阻尼比、角频率）和比前缘晚多少秒。
        struct Style { let fill, rim, shaft, glyph, cool, warm, bend, tipStart, drop, glyphFrom, zeta, omega, delay: Float }
        static func style(_ tier: Tier) -> Style {
            switch tier {
            case .secondary:
                return Style(fill: 0.60, rim: 0.28, shaft: 0.30, glyph: 0.62, cool: 0.30, warm: 0.36, bend: 0.045, tipStart: 0.45,
                             drop: 0.45, glyphFrom: 0.38, zeta: 0.85, omega: 7.5, delay: 0.08)
            case .primary:
                return Style(fill: 0.66, rim: 0.32, shaft: 0.36, glyph: 0.74, cool: 0.80, warm: 0.33, bend: 0.085, tipStart: 0.35,
                             drop: 0.45, glyphFrom: 0.36, zeta: 0.60, omega: 6.5, delay: 0.14)
            case .greaterCovert:
                return Style(fill: 0.48, rim: 0.20, shaft: 0.14, glyph: 0, cool: 0.10, warm: 0.32, bend: 0.04, tipStart: 0.35,
                             drop: 0.75, glyphFrom: 1, zeta: 1, omega: 11, delay: 0.04)
            case .lesserCovert:
                return Style(fill: 0.40, rim: 0, shaft: 0, glyph: 0, cool: 0.05, warm: 0.28, bend: 0.02, tipStart: 0.25,
                             drop: 0.30, glyphFrom: 1, zeta: 1, omega: 12, delay: 0)
            }
        }

        // MARK: 形

        /// 腕关节在翼骨上的位置、比肩胛高多少；过了腕关节先下沉多少，到翼尖再比腕关节高多少（屏幕高度的比例）。
        static let wristX: Float = 0.36, wristRise: Float = 0.125, handSag: Float = 0.014, tipRise: Float = 0.042
        /// 腕星的位置（沿翼骨）。
        static let starX: Float = 0.34

        /// 翼骨在 xn 处比肩胛高多少（屏幕高度的比例）：肩胛到腕关节是三次缓出（到腕关节时斜率和弯曲都归零）；
        /// 腕关节以外是一道 S 形——先微微下沉，再在翼尖处上扬，像书法里收笔前的一顿一提。两段在腕关节处光滑相接。
        static func armHeight(_ xn: Float) -> Float {
            if xn < wristX {
                let k = 1 - xn / wristX
                return wristRise * (1 - k * k * k)
            }
            let k = (xn - wristX) / (1 - wristX)
            return wristRise - handSag * 16 * k * k * (1 - k) * (1 - k) + tipRise * k * k * k
        }

        /// 前缘带的厚度（屏幕高度的比例）：从她背后细细地长出来，前臂处略厚，再收细到翼尖。
        static func bandThickness(_ xn: Float) -> Float { 0.004 + 0.016 * smooth(0, 0.20, xn) * pow(max(0, 1 - xn), 0.9) }

        private static let secondaryTable: [(xn: Float, angle: Float, length: Float)] = [
            (0.035, 3, 0.300), (0.089, 5, 0.298), (0.143, 7, 0.294), (0.197, 9, 0.288), (0.251, 11, 0.280), (0.305, 14, 0.270),
        ]
        /// 初级飞羽。最外四根略收窄（fingerOf），角度逐根收拢、弯度一致，连成一个干净的后掠翼尖，不散开、不翘过前缘。
        static func fingerOf(slot: Int) -> Float { [0, 0, 0, 0.15, 0.25, 0.35, 0.40][slot] }
        private static let primaryTable: [(xn: Float, angle: Float, length: Float)] = [
            (0.370, 18, 0.265), (0.425, 25, 0.285), (0.485, 33, 0.300), (0.550, 40, 0.312),
            (0.625, 48, 0.316), (0.705, 56, 0.312), (0.790, 64, 0.300),
        ]

        /// 某处飞羽的静止角度（度）：在相邻两根飞羽之间插值，覆羽顺着它排。
        static func flightAngle(_ xn: Float) -> Float {
            let pts = secondaryTable.map { ($0.xn, $0.angle) } + primaryTable.map { ($0.xn, $0.angle) }
            if xn <= pts[0].0 { return pts[0].1 }
            for k in 1..<pts.count where xn <= pts[k].0 {
                let f = (xn - pts[k - 1].0) / (pts[k].0 - pts[k - 1].0)
                return pts[k - 1].1 + (pts[k].1 - pts[k - 1].1) * f
            }
            return pts[pts.count - 1].1
        }

        /// 由后到前：后层飞羽（夹在相邻两根飞羽中间，没有经文）、次级飞羽、初级飞羽、大覆羽、小覆羽（前缘带最后画，在最前面）。
        /// 同一层里外侧的盖住内侧的。
        static let feathers: [Feather] = {
            var list: [Feather] = []
            var rng = SplitMix(seed: 0x57A6_2026)
            func phase() -> SIMD2<Float> {
                SIMD2(Float(rng.next() % 10_000) / 10_000 * 2 * .pi, Float(rng.next() % 10_000) / 10_000 * 2 * .pi)
            }
            let flights = secondaryTable.map { (Tier.secondary, $0) } + primaryTable.map { (Tier.primary, $0) }
            func flightWidth(_ tier: Tier, _ xn: Float) -> Float { tier == .secondary ? 0.018 : 0.015 + 0.004 * (xn - 0.37) / 0.48 }
            for k in 1..<flights.count {                                         // 后层：相邻两根飞羽中间各一根
                let (t0, a) = flights[k - 1], (t1, b) = flights[k]
                let xn = (a.xn + b.xn) / 2
                let tier = t0 == t1 ? t1 : .secondary
                list.append(Feather(tier: tier, xn: xn, angle: (a.angle + b.angle) / 2, length: (a.length + b.length) / 2 * 0.95,
                                    width: flightWidth(tier, xn) * 0.95, slot: -1, phase: phase()))
            }
            for (k, s) in secondaryTable.enumerated() {
                list.append(Feather(tier: .secondary, xn: s.xn, angle: s.angle, length: s.length, width: flightWidth(.secondary, s.xn),
                                    slot: k, phase: phase()))
            }
            for (k, p) in primaryTable.enumerated() {
                list.append(Feather(tier: .primary, xn: p.xn, angle: p.angle, length: p.length, width: flightWidth(.primary, p.xn),
                                    slot: k, phase: phase(), finger: fingerOf(slot: k)))
            }
            for k in 0..<18 {
                let xn = 0.03 + 0.68 * pow(Float(k) / 17, 1.15)
                list.append(Feather(tier: .greaterCovert, xn: xn, angle: flightAngle(xn) * 0.92 + 2, length: 0.115, width: 0.012,
                                    slot: -1, phase: phase()))
            }
            for k in 0..<20 {
                let xn = 0.02 + 0.82 * pow(Float(k) / 19, 1.2)
                list.append(Feather(tier: .lesserCovert, xn: xn, angle: flightAngle(xn) * 0.85 + 6, length: 0.050, width: 0.008,
                                    slot: -1, phase: phase()))
            }
            return list
        }()

        /// 每根羽在每一侧的一点不规则：角度（度）、长度、宽度、亮度的倍率。两侧各不相同，左右不完全对称。
        private static let jitters: [[SIMD4<Float>]] = (0..<2).map { s in
            var rng = SplitMix(seed: 0x1D17_7E40 &+ UInt64(s) &* 977)
            func r() -> Float { Float(rng.next() % 10_000) / 10_000 - 0.5 }
            return feathers.map { _ in SIMD4(r() * 2.4, 1 + r() * 0.06, 1 + r() * 0.10, 1 + r() * 0.12) }
        }

        // MARK: 经文（钦定本，公有领域）
        // 左翼的数组按从左到右（从翼尖读向她）排，右翼按从她读向翼尖排，整对翅膀从左读到右是通顺的。

        /// 前缘：《诗篇》139:9–10，横贯整个翼展。
        private static let boneVerse = [
            "IfITakeTheWingsOfTheMorning,AndDwellInTheUttermostPartsOfTheSea;",
            "EvenThereShallThyHandLeadMe,AndThyRightHandShallHoldMe.",
        ]
        /// 次级飞羽（竖着从上读到下）：左《诗篇》36:7，右 57:1。
        private static let secondaryVerse = [
            ["HowExcellentIsThy", "Lovingkindness,OGod!", "ThereforeTheChildren", "OfMenPutTheirTrust", "UnderTheShadow", "OfThyWings."],
            ["InTheShadow", "OfThyWings", "WillIMake", "MyRefuge,", "UntilTheseCalamities", "BeOverpast."],
        ]
        /// 初级飞羽：左《诗篇》91:4、17:8、55:6；右《以赛亚书》40:31、《出埃及记》19:4、《玛拉基书》4:2。
        private static let primaryVerse = [
            ["HeShallCoverTheeWithHisFeathers,", "AndUnderHisWingsShaltThouTrust:", "HisTruthShallBeThyShieldAndBuckler.",
             "HideMeUnderTheShadowOfThyWings.", "OhThatIHadWingsLikeADove!", "ForThenWouldIFlyAway,", "AndBeAtRest."],
            ["TheyShallMountUpWithWingsAsEagles;", "TheyShallRunAndNotBeWeary;", "AndTheyShallWalkAndNotFaint.",
             "IBareYouOnEaglesWings,", "AndBroughtYouUntoMyself.", "ShallTheSunOfRighteousnessArise", "WithHealingInHisWings."],
        ]

        /// 某根羽轴上的经文（左翼按阅读顺序反过来取，从内到外的 slot 对应从右到左的那一句）。
        private static func verse(side s: Int, _ f: Feather) -> [UInt8]? {
            guard f.slot >= 0 else { return nil }
            let table = f.tier == .secondary ? secondaryVerse : primaryVerse
            let row = table[s]
            return Array(row[s == 0 ? row.count - 1 - f.slot : f.slot].utf8)
        }

        // MARK: 输出

        /// 给着色器的参数个数（布局见 Sea.metal 的 fx[0…7]）。
        static let paramCount = 8
        private(set) var params = [SIMD4<Float>](repeating: .zero, count: paramCount)
        /// 翅膀这一帧占的横条（像素：上、下），着色器只在这里面采样光纹理。
        private(set) var band = SIMD2<Float>(0, 0)
        /// 振翅时她被托高多少（像素）：人像和翅膀一起上移，光环不动。
        private(set) var figureLift: Float = 0
        /// 字缝里的光（RGBA16F，每格 texel 像素）：R 羽片的光、G 色温（0 近白 · 0.35 香槟金 · 1 银蓝）、
        /// B 到最近那道线（轮廓或羽轴）的有向距离（像素）、A 那道线的亮度（已含远近衰减和被前层遮住的部分）。
        /// 有向距离在一格之内近似线性，双线性插值后仍是准确的距离，着色器据此画出细到一两个像素的线。
        private(set) var glow: [Float16] = []
        private(set) var glowSize = SIMD2<Int>(0, 0)
        private(set) var texel = SIMD2<Float>(1, 1)
        /// 每格的累加量，7 个一组：羽片亮度（前层盖后层）、羽片色温（同样）、外缘柔光、柔光的色温和、
        /// 线的亮度、线的有向距离、线的色温。
        private var acc: [Float] = []
        private static let accStride = 7
        /// 光纹理里这一帧、上一帧写到的行（只清理、只收尾这些行，其余一直是 0）。
        private var rowsTouched = (Int.max, Int.min)
        private var rowsDirty: (Int, Int)?

        static func texelSize(cell: SIMD2<Float>) -> SIMD2<Float> { SIMD2(cell.x, cell.y * 0.5) }
        static func glowSize(view: SIMD2<Float>, cell: SIMD2<Float>) -> SIMD2<Int> {
            let t = texelSize(cell: cell)
            return SIMD2(Int(ceil(view.x / t.x)) + 1, Int(ceil(view.y / t.y)) + 1)
        }

        private static let breathOmega = HourLoop.omega(2 * .pi / 10)
        private static let twinkleOmega = [HourLoop.omega(0.37), HourLoop.omega(0.29)]
        private static let breezeA = HourLoop.omega(0.93), breezeB = HourLoop.omega(1.71)
        /// 她的飘浮与轻摆（与着色器 figureUV 里的 hourly(0.62)、hourly(0.41) 一致）。
        private static let bobOmega = HourLoop.omega(0.62), swayOmega = HourLoop.omega(0.41)

        /// 呼吸的波形：吸气慢、呼气快（基波加一点二次谐波），约在 −1…1 之间。
        private static func breathShape(_ t: Float) -> Float {
            (sin(t * breathOmega) + 0.22 * sin(2 * t * breathOmega - 0.9)) / 1.1
        }

        /// 振翅时翅膀绕肩胛转过的角度（度，正 = 下压），x 是从振开始算的秒数：
        /// 先微微上提，再一下压下去，回弹时略过头再落定（阻尼弹簧）。
        private static func beat(_ x: Float) -> Float {
            if x <= 0 { return 0 }
            if x < 0.3 { return -1.2 * smooth(0, 0.3, x) }
            if x < 0.7 { return -1.2 + 4.7 * smooth(0.3, 0.7, x) }
            return 3.5 * (1 - spring(x - 0.7, zeta: 0.5, omega: 5.5))
        }
        private static let beatStart: Float = 2.85

        /// 算这一帧的翅膀：字缝里的光写进 glow，羽轴上的字写进 cells（cols×rows，RGBA8：R 字的强度、G 色温、
        /// B 字符（0 = 用诗句流里这一格的字）、A 字重（1 半粗 … 0 细）；格子坐标比屏幕格多一格边，和字符网格一致）。
        /// unfurl 是浮现开始后的秒数（展开的时间轴），dissolve 是消散进度，elapsed 是她出现后的秒数（她飘浮的相位）。
        /// 返回翅膀这一帧是否看得见。
        func update(cells: inout [UInt8], cols: Int, rows: Int, cell: SIMD2<Float>, view: SIMD2<Float>, rect: SIMD4<Float>,
                    dissolve d: Float, unfurl tw: Float, time t: Float, elapsed te: Float) -> Bool {
            let size = Self.glowSize(view: view, cell: cell)
            texel = Self.texelSize(cell: cell)
            let n = size.x * size.y
            let stride = Self.accStride
            if size != glowSize {
                glowSize = size
                glow = [Float16](repeating: 0, count: n * 4)
                acc = [Float](repeating: 0, count: n * stride)
                rowsDirty = nil
            } else if let (r0, r1) = rowsDirty {
                let a0 = r0 * size.x, a1 = (r1 + 1) * size.x
                acc.withUnsafeMutableBufferPointer { p in
                    for k in (a0 * stride)..<(a1 * stride) { p[k] = 0 }
                }
                glow.withUnsafeMutableBufferPointer { p in
                    for k in (a0 * 4)..<(a1 * 4) { p[k] = 0 }
                }
            }
            rowsTouched = (Int.max, Int.min)
            cells.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 0, $0.count) }

            let H = view.y
            let sides: [Float] = [-1, 1]

            // ---- 她这一刻在哪：翅膀长在她身上，跟着她飘浮、轻摆；振翅时被托高一点 ----
            let bob = 0.011 * sin(te * Self.bobOmega) * rect.w
            let sway = 0.011 * sin(te * Self.swayOmega + 0.7)
            let xLift = tw - Self.beatStart - 0.6
            figureLift = xLift > 0 && xLift < 2.6 ? 0.005 * H * smooth(0, 0.45, xLift) * (1 - smooth(0.6, 2.6, xLift)) : 0
            let center = SIMD2<Float>(rect.x + 0.52 * rect.z + 0.681 * sway * rect.z, rect.y + 0.215 * rect.w + bob - figureLift)
            let rootOff = 0.03 * rect.z
            let roots = [center - SIMD2(rootOff, 0), center + SIMD2(rootOff, 0)]
            let margin = 0.012 * view.x
            let spans = [max(1, roots[0].x - margin), max(1, view.x - margin - roots[1].x)]
            /// 前缘从她身后露出来的地方（离肩胛的水平距离）：前缘上的经文从这里读起，不藏在她身后。
            let emerge = 0.26 * rect.z

            // ---- 整只翅膀这一刻的姿态 ----
            let reachOpen = easeOutCubic((tw - 0.85) / 1.4)
            let reach = min(reachOpen, 1 - smooth(0.10, 0.62, d))      // 前缘伸到哪；消散时从翼尖往回收
            let fade = 1 - smooth(0.62, 0.85, d)

            /// 翼骨在 xn 处转过的角度（弧度，右翼顺时针为正）：振翅从肩部传到翼尖（外侧晚一点），呼吸的缓波也是。
            func rot(_ xn: Float) -> Float {
                rad(Self.beat(tw - Self.beatStart - 0.10 * xn)) - rad(0.7) * Self.breathShape(t - 0.8 * xn)
            }
            func arm(_ s: Int, _ xn: Float) -> SIMD2<Float> {
                let lift = 1 + 0.03 * Self.breathShape(t - 0.4 * xn)
                let local = SIMD2(sides[s] * xn * spans[s], -Self.armHeight(xn) * H * lift)
                return roots[s] + rotate(local, sides[s] * rot(xn))
            }
            /// 翼骨在 xn 处朝下的法线。
            func armDown(_ s: Int, _ xn: Float) -> SIMD2<Float> {
                let a = arm(s, max(0, xn - 0.004)), b = arm(s, min(1, xn + 0.004))
                let tng = simd_normalize(b - a)
                let nrm = SIMD2(-tng.y, tng.x)
                return nrm.y < 0 ? -nrm : nrm
            }
            /// 翼骨切线（朝外）与竖直向下的夹角（度）：水平为 90，往上翘大于 90。
            func armTangent(_ s: Int, _ xn: Float) -> Float {
                let x0 = min(xn, 0.99)
                let dy = (Self.armHeight(x0 + 0.01) - Self.armHeight(x0)) * H
                return deg(atan2(0.01 * spans[s], -dy))
            }

            // ---- 约 45 秒一阵抖羽：一道小小的颤动从根部掠到翼尖（一小时整 80 次）----
            let ruffleT = (t + 20).truncatingRemainder(dividingBy: 3600)
            let ruffleTau = ruffleT - Float(Int(ruffleT / 45)) * 45
            func ruffle(_ xn: Float) -> Float {
                let x = ruffleTau - 1.0 * xn
                return x > 0 && x < 0.55 ? sq(sin(Float.pi * x / 0.55)) : 0
            }

            struct Pose {
                var base: SIMD2<Float>, dir: SIMD2<Float>, out: SIMD2<Float>
                var length: Float, width: Float, bright: Float, bend: Float, finger: Float
            }
            /// 第 i 根羽此刻的位置。rest = 完全展开、不在消散（给掉落的光点取起点用）。
            func pose(_ s: Int, _ i: Int, rest: Bool = false) -> Pose {
                let f = Self.feathers[i]
                let st = Self.style(f.tier)
                let jt = Self.jitters[s][i]
                let sg = sides[s]
                let base = arm(s, f.xn) + armDown(s, f.xn) * (Self.bandThickness(f.xn) * H * st.drop)
                let tOpen = 0.85 + 1.4 * (1 - cbrt(1 - min(f.xn, 0.999))) + st.delay   // 前缘经过这里的时刻
                let tau = rest ? 60 : tw - tOpen
                let o = Self.spring(tau, zeta: st.zeta, omega: st.omega)
                let c0 = 0.03 + 0.30 * (1 - f.xn)
                let c = rest ? 0 : smooth(c0, c0 + 0.28, d)
                let fold = 90 + 0.5 * (armTangent(s, f.xn) - 90)            // 收拢时贴着前缘
                let flight = f.tier == .primary || f.tier == .secondary
                var theta = f.angle + jt.x * (1 - 0.7 * smooth(0.5, 0.8, f.xn))   // 翼尖处不规则收小，轮廓干净
                theta += 0.5 * sin(t * Self.breezeA + f.phase.x + Float(s) * 2.1) + 0.3 * sin(t * Self.breezeB + f.phase.y)
                let rf = ruffle(f.xn)
                theta += 2.2 * rf * (flight ? 1 : 0.5)
                // 振翅时羽尖被气流压弯：翅膀转得越快，羽尖越往后翘（外侧更明显）
                let xb = tw - Self.beatStart - 0.10 * f.xn - 0.06
                let vel = (Self.beat(xb + 0.01) - Self.beat(xb - 0.01)) / 0.02   // 度/秒
                if flight { theta += 0.16 * vel * (0.3 + f.xn) }
                theta = fold + (theta - fold) * o
                theta += (fold - theta) * c * c
                let r = sg * rot(f.xn), th = rad(theta)
                let dir = rotate(SIMD2(sg * sin(th), cos(th)), r)
                let out = rotate(SIMD2(sg * cos(th), -sin(th)), r)                // 向外的一侧（羽尖往这边弯）
                let oc = min(o, 1)
                let length = f.length * jt.y * H * (0.3 + 0.7 * smooth(-0.05, 0.75, oc)) * (1 - 0.7 * c)
                var bright = smooth(0, 0.35, tau) + 0.55 * exp(-sq((tau - 0.12) / 0.09))   // 点亮的一瞬根部闪一下
                bright *= jt.w * (0.92 + 0.08 * Self.breathShape(t - 1.2 * f.xn)) * (1 + 0.15 * rf)   // 光随呼吸从根部往外走
                bright *= pow(1 - c, 1.5) + 0.35 * sin(Float.pi * c) * (1 - c)             // 合上时亮一下再熄
                let bend = (st.bend + 0.03 * f.finger) * (1 + 0.8 * min(1, abs(vel) / 14))   // 下扑时弯得更多
                return Pose(base: base, dir: dir, out: out, length: length, width: f.width * jt.z * H,
                            bright: bright * (rest ? 1 : fade), bend: bend, finger: f.finger)
            }

            var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
            func cover(_ y0: Float, _ y1: Float) { minY = min(minY, y0); maxY = max(maxY, y1) }
            var visible = false

            // ---- 偶尔一道光沿某根飞羽的羽轴从根部跑到尖端（每 30 秒一次，一小时整 120 次）----
            let shimmerEpoch = Int(t / 30)
            let shimmerTau = t - Float(shimmerEpoch) * 30
            let shimmerHash = mix32(UInt32(shimmerEpoch) &* 2654435761 &+ 17)
            let shimmerSide = Int(shimmerHash & 1), shimmerSlot = Int((shimmerHash >> 1) % 13)
            let shimmerU = shimmerTau / 1.6 * 1.15 - 0.05
            let shimmerA: Float = shimmerTau < 1.9 ? 0.9 * smooth(0, 0.2, shimmerTau) * (1 - smooth(1.5, 1.9, shimmerTau)) : 0

            // ---- 流光：约 24 秒一次，一道很慢的光泽从根部斜着扫向翼尖，一根羽接一根羽地经过（一小时整 150 次）----
            let sheenT = (t + 11).truncatingRemainder(dividingBy: 3600)
            let sheenTau = sheenT - Float(Int(sheenT / 24)) * 24
            let sheenPos = -0.2 + 1.6 * smooth(0, 4.2, sheenTau)
            let sheenA: Float = sheenTau < 4.2 && reach > 0.99 && d == 0
                ? 1.0 * smooth(0, 0.6, sheenTau) * (1 - smooth(3.4, 4.2, sheenTau)) : 0
            /// 流光在沿翼骨 xn、沿羽 u 处有多亮（0 … sheenA）。
            func sheenAt(_ xn: Float, _ u: Float) -> Float {
                sheenA > 0 ? sheenA * exp(-sq((xn * 0.8 + u * 0.4 - sheenPos) / 0.075)) : 0
            }

            // ---- 羽（由后到前）----
            for s in 0..<2 {
                for (i, f) in Self.feathers.enumerated() {
                    let p = pose(s, i)
                    guard p.bright > 0.003, p.length > 1 else { continue }
                    visible = true
                    let st = Self.style(f.tier)
                    let flight = f.slot < 0 ? -1 : (f.tier == .secondary ? f.slot : (f.tier == .primary ? 6 + f.slot : -1))
                    let filler = f.slot < 0 && (f.tier == .secondary || f.tier == .primary)
                    let back: Float = filler ? 0.78 : 1
                    // 景深：后层（后层羽、次级飞羽）偏冷、边缘更柔，前层的初级飞羽清楚；翅膀外端融进一层冷色的雾气
                    let soft: Float = filler ? 1.7 : (f.tier == .secondary ? 1.35 : 1)
                    let haze = smooth(0.60, 1.0, f.xn)
                    let coolShift = (filler ? 0.10 : (f.tier == .secondary ? 0.06 : 0)) + 0.14 * haze
                    let pa: Float = flight >= 0 && s == shimmerSide && flight == shimmerSlot ? shimmerA : 0
                    let warm = st.warm * (0.4 + 0.6 * min(1, f.xn / 0.3))      // 越靠近她越白
                    let near = smooth(0.02, 0.17, f.xn)                         // 靠近她背后羽片渐渐透明，只留羽轴汇向她身后
                    rasterFeather(p.base, p.dir, p.out, p.length, p.width, bend: p.bend, finger: p.finger, tipStart: st.tipStart,
                                  fill: st.fill * p.bright * near * back * (1 - 0.12 * haze), rim: st.rim * p.bright * near * back / soft,
                                  shaft: st.shaft * p.bright * (0.55 + 0.45 * near) * back,
                                  warm: warm + coolShift, cool: st.cool, soft: soft, pulseU: shimmerU, pulseA: pa,
                                  sheenA: sheenA, sheenC: sheenPos - f.xn * 0.8)
                    if st.glyph > 0 && f.slot >= 0 {
                        let from = f.xn > 0.72 ? 0.12 : st.glyphFrom              // 外侧没有大覆羽，字从更靠根部的地方读起
                        shaftGlyphs(&cells, cols: cols, rows: rows, cell: cell, p.base, p.dir, p.out, p.length, bend: p.bend,
                                    from: from, gain: st.glyph * p.bright * (1 + 0.6 * sheenAt(f.xn, 0.5)), warm: warm + coolShift,
                                    cool: st.cool, text: Self.verse(side: s, f),
                                    pulseU: shimmerU, pulseA: pa)
                    }
                    let tip = p.base + p.dir * p.length
                    let pad = p.width * 1.6 + p.bend * p.length + texel.y * 3
                    cover(min(p.base.y, tip.y) - pad, max(p.base.y, tip.y) + pad)
                }
            }

            // ---- 前缘带：一条有厚度的光带，上沿一道亮线，带里是一行经文；展开时最前面有一点亮的光头 ----
            let boneOn = smooth(0.85, 1.15, tw) * fade
            let head = (1 - reachOpen).squareRoot()
            func bandBright(_ xn: Float) -> Float {
                let along = (1 - smooth(0.72, 0.95, xn)) * (0.75 + 0.25 * (1 - xn)) * (1 + 0.8 * sheenAt(xn, 0))
                let front = 1 - smooth(reach - 0.04, reach, xn)
                let emergeFade = 0.25 + 0.75 * smooth(0.02, 0.16, xn)            // 从她背后淡淡地长出来
                return 0.78 * boneOn * along * front * emergeFade + 0.9 * head * exp(-sq((xn - reach) / 0.015)) * boneOn
            }
            if reach > 0.002 && boneOn > 0 {
                visible = true
                for s in 0..<2 {
                    let segs = 40
                    let end = min(reach + 0.02, 1)
                    var prev = arm(s, 0), prevT = Self.bandThickness(0) * H, prevB = bandBright(0)
                    for k in 1...segs {
                        let xn = end * Float(k) / Float(segs)
                        let P = arm(s, xn), tb = Self.bandThickness(xn) * H, b = bandBright(xn)
                        rasterBand(prev, P, tb0: prevT, tb1: tb, b0: prevB, b1: b, temp: 0.14 + 0.18 * xn)
                        cover(min(prev.y, P.y) - texel.y * 3, max(prev.y, P.y) + max(prevT, tb) * 1.6 + texel.y * 3)
                        prev = P; prevT = tb; prevB = b
                    }
                    // 字：沿带的中线每列一格，从她身后露出来的地方开始读
                    let text = Array(Self.boneVerse[s].utf8)
                    var lastGx = Int.min, k = 0
                    var xn: Float = 0
                    let dxn = 0.4 * cell.x / spans[s]
                    while xn <= end {
                        let P = arm(s, xn) + armDown(s, xn) * (Self.bandThickness(xn) * H * 0.5)
                        let gx = Int(floor(P.x / cell.x)) + 1
                        if gx != lastGx {
                            lastGx = gx
                            let out = abs(P.x - roots[s].x) > emerge
                            let idx = s == 0 ? text.count - 1 - k : k
                            let ch: UInt8 = out && idx >= 0 && idx < text.count ? text[idx] : 0
                            if out { k += 1 }
                            let b = bandBright(xn) * 1.05
                            let y = P.y / cell.y - 0.5, y0 = floor(y), wy = y - y0
                            let temp = 0.14 + 0.18 * xn, weight = 1 - 0.6 * xn
                            put(&cells, cols, rows, gx, Int(y0) + 1, b * (1 - wy), temp, ch, weight)
                            put(&cells, cols, rows, gx, Int(y0) + 2, b * wy, temp, ch, weight)
                        }
                        xn += dxn
                    }
                }
            }

            // ---- 腕关节的主星（缀在前缘带上）----
            let tWrist = 0.85 + 1.4 * (1 - cbrt(1 - Self.starX))
            let tauW = tw - tWrist
            let cW = smooth(0.03 + 0.30 * (1 - Self.starX), 0.31 + 0.30 * (1 - Self.starX), d)
            var starB: [Float] = [0, 0]
            var wrists = [SIMD2<Float>](repeating: .zero, count: 2)
            let starLen = 0.026 * H * (0.6 + 0.4 * smooth(0, 0.4, tauW))
            for s in 0..<2 {
                wrists[s] = arm(s, Self.starX) + armDown(s, Self.starX) * (Self.bandThickness(Self.starX) * H * 0.35)
                let twinkle = 0.80 + 0.20 * sq(sin(t * Self.twinkleOmega[s] + Float(s) * 1.7))   // 两颗星各按自己的节奏闪
                starB[s] = (0.62 * smooth(0, 0.3, tauW) + 0.9 * exp(-sq((tauW - 0.1) / 0.1))) * twinkle * (1 - cW) * fade
                guard starB[s] > 0.003 else { continue }
                visible = true
                let gx = Int(floor(wrists[s].x / cell.x)) + 1, gy = Int(floor(wrists[s].y / cell.y)) + 1
                put(&cells, cols, rows, gx, gy, min(1, starB[s]) * 0.6, 0, UInt8(ascii: "*"), 0.6)
                cover(wrists[s].y - starLen * 1.4, wrists[s].y + starLen * 1.4)
            }

            // ---- 肩胛后的根部辉光：预备时聚起，破的一瞬闪白，之后稳在一个柔和的亮度 ----
            let flash = exp(-sq((tw - 0.85) / 0.12))
            let rootB = (0.5 * smooth(0, 0.75, tw) - 0.25 * smooth(0.9, 2.0, tw) + 0.8 * flash) * (0.95 + 0.05 * Self.breathShape(t))
                * (1 - smooth(0.35, 0.8, d))
            let rootR = 0.055 * H * (1 + 0.9 * flash)                // 平时小、大多藏在她身后；闪白时略微扩开
            if rootB > 0.003 {
                visible = true
                cover(center.y - rootR * 2.6, center.y + rootR * 2.6)
            }

            // ---- 破：一道环形波从她背后扫过整片海 ----
            let tauS = tw - 0.8
            var shock = SIMD4<Float>(center.x, center.y, 0, 0)
            if tauS > 0 && tauS < 2.2 {
                let prog = tauS / 2.2
                shock.z = (1 - pow(1 - prog, 2.2)) * 0.62 * simd_length(view)
                shock.w = pow(1 - prog, 1.6) * smooth(0, 0.12, tauS) * smooth(0.04 * H, 0.2 * H, shock.z)
                if shock.w > 0.002 { visible = true }
            }

            // ---- 偶尔一个字从某根初级飞羽的尖端脱落，往上飘走（每 20 秒一次，一小时整 180 次）----
            let primaryIndex = Self.feathers.indices.filter { Self.feathers[$0].tier == .primary && Self.feathers[$0].slot >= 0 }
            if reach > 0.99 && d == 0 {
                let tt = (t + 7).truncatingRemainder(dividingBy: 3600)
                let epoch = Int(tt / 20)
                let tau = tt - Float(epoch) * 20
                if tau < 6 {
                    let h = mix32(UInt32(epoch) &* 40503 &+ 911)
                    let s = Int(h & 1), i = primaryIndex[Int((h >> 1) % 5)]     // 前五根（后两根多半在画框外）
                    let p = pose(s, i)
                    let u: Float = 0.78
                    let start = p.base + p.dir * (p.length * u) + p.out * (p.bend * p.length * u * u)
                    let drift = (Float((h >> 8) % 100) / 100 - 0.5) * 0.02 * H
                    let pos = start + SIMD2(drift * tau / 6, -0.05 * H * tau)
                    let v = 0.75 * smooth(0, 0.6, tau) * (1 - smooth(3.5, 6, tau))
                    let text = Self.verse(side: s, Self.feathers[i]) ?? []
                    let ch = text.isEmpty ? 0 : text[Int(h >> 4) % text.count]
                    mote(&cells, cols, rows, cell, pos, v, temp: 0.5 + 0.4 * smooth(0, 4, tau), ch: ch)
                    cover(pos.y - cell.y * 2, pos.y + cell.y * 2)
                }
            }

            // ---- 收：合上的羽化作往上飘的光点 ----
            if d > 0 && d < 1 {
                for s in 0..<2 {
                    for (i, f) in Self.feathers.enumerated() where f.slot >= 0 {
                        let c0 = 0.03 + 0.30 * (1 - f.xn)
                        let rp = pose(s, i, rest: true)
                        let text = Self.verse(side: s, f) ?? []
                        for j in 0..<3 {
                            let h = mix32(UInt32(s * 97 + f.slot * 13 + (f.tier == .primary ? 500 : 0) + j * 7919))
                            let r1 = Float(h % 1000) / 1000, r2 = Float((h >> 10) % 1000) / 1000
                            let born = c0 + 0.28 * (0.15 + 0.6 * r1)
                            let life = (d - born) / 0.35
                            guard life > 0, life < 1 else { continue }
                            let u = 0.3 + 0.6 * r2
                            let start = rp.base + rp.dir * (rp.length * u * (1 - 0.6 * smooth(c0, c0 + 0.28, born)))
                            let pos = start + SIMD2((r1 - 0.5) * 0.03 * H * life, -0.22 * H * life)
                            let v = 0.8 * sin(Float.pi * life) * (f.tier == .primary ? 1 : 0.7)
                            let ch = text.isEmpty ? 0 : text[Int(h >> 20) % text.count]
                            mote(&cells, cols, rows, cell, pos, v, temp: 0.2 + 0.5 * life, ch: ch)
                            cover(pos.y - cell.y * 2, pos.y + cell.y * 2)
                            visible = true
                        }
                    }
                }
            }

            // ---- 光纹理收尾：羽片 + 外缘柔光，色温按两者加权（都没有的地方用线的），转成半精度。只处理这一帧写到的行 ----
            let touched = rowsTouched.0 <= rowsTouched.1 ? rowsTouched : (0, -1)
            rowsDirty = touched.0 <= touched.1 ? touched : nil
            acc.withUnsafeBufferPointer { ap in
                glow.withUnsafeMutableBufferPointer { gp in
                    for k in (touched.0 * size.x)..<((touched.1 + 1) * size.x) {
                        let q = k * stride
                        let fill = ap[q], soft = ap[q + 2], a = ap[q + 4]
                        let light = fill + soft
                        let temp = light > 0.01 ? (fill * ap[q + 1] + ap[q + 3]) / light : ap[q + 6]
                        gp[k * 4] = Float16(min(light, 1))
                        gp[k * 4 + 1] = Float16(temp)
                        gp[k * 4 + 2] = Float16(a > 0 ? max(-1000, min(1000, ap[q + 5])) : 1000)
                        gp[k * 4 + 3] = Float16(a)
                    }
                }
            }

            let wristY = 0.5 * (wrists[0].y + wrists[1].y)
            let wave: Float = tw > Self.beatStart + 0.7 && tw < Self.beatStart + 2.4 ? (tw - Self.beatStart - 0.7) / 1.7 : -1
            let antic = smooth(0, 0.7, tw) * (1 - smooth(0.78, 1.1, tw))
            params[0] = SIMD4(roots[0].x, roots[0].y, roots[1].x, roots[1].y)
            params[1] = SIMD4(wrists[0].x, wrists[0].y, wrists[1].x, wrists[1].y)
            params[2] = SIMD4(starLen, starB[0], starB[1], max(rootB, 0))
            params[3] = shock
            params[4] = SIMD4(antic, wave, reach * fade, rootR)
            params[5] = SIMD4(spans[0], spans[1], reach, wristY)
            params[6] = SIMD4(texel.x, texel.y, Float(size.x), Float(size.y))
            params[7] = .zero
            band = visible ? SIMD2(max(0, minY), min(view.y, maxY)) : SIMD2(0, 0)
            return visible
        }

        // MARK: 光纹理

        /// 一片羽的光。形状：前段两条平行边（根部收窄，藏在前层下面），后段收成椭圆形的羽尖；整片沿弯曲的羽轴微微向外弯。
        /// 羽片按“前层盖住后层”合成：盖住的地方，后层的亮度、色温换成这一片的，后层的轮廓和羽轴也跟着变淡；
        /// 外缘再透一圈淡淡的柔光。线：轮廓（到羽片边缘的有向距离）和羽轴（到羽轴的有向距离），每格只留最近最亮的一道。
        private func rasterFeather(_ B: SIMD2<Float>, _ d: SIMD2<Float>, _ out: SIMD2<Float>, _ L: Float, _ w: Float, bend: Float,
                                   finger: Float, tipStart: Float, fill: Float, rim: Float, shaft: Float, warm t0: Float, cool: Float,
                                   soft: Float, pulseU: Float, pulseA: Float, sheenA: Float, sheenC: Float) {
            let nrm = SIMD2(-d.y, d.x)
            let side: Float = simd_dot(out, nrm) >= 0 ? 1 : -1
            let bendPx = bend * L
            let lineR = 2.2 * texel.x
            let bloom = max(0.8 * w * soft.squareRoot(), lineR)
            let shadowW = 0.55 * w
            let ramp = 8 * soft                                             // 羽片边缘的过渡宽度（像素）：后层更柔
            let wOut = 0.78 * w, wIn = 1.12 * w                        // 朝外的半片窄、朝内的半片宽（真实的飞羽就是不对称的）
            let aTip = L * tipStart, tipLen = max(L - aTip, 1)
            let pulsing = pulseA > 0
            let eNear = wIn + bloom, eFar = wIn + bloom + bendPx
            raster(B, d, aMin: -bloom, aMax: L + bloom, eMin: side > 0 ? -eNear : -eFar, eMax: side > 0 ? eFar : eNear) { p, q, a, e in
                let u = min(max(a / L, 0), 1)
                let ep = e - side * bendPx * u * u                         // 到弯曲羽轴的离轴距离
                // 宽度：根部收窄（藏在前层下面），从 tipStart 起收成一个外凸的柳叶尖（不是直边的刀尖）
                let k = a <= aTip ? 1 : max(0, (L - a) / tipLen)
                let km = 1 - k
                let notch = 1 - finger * 0.48 * smooth(0.30, 0.52, u)       // 翼指：外半段收窄成一根手指
                let ww = (ep * side > 0 ? wOut : wIn) * min(1, (u / 0.06).squareRoot()) * (1 - km * km.squareRoot()) * notch
                let r = abs(ep) / max(ww, 0.5)                             // 0 在羽轴 … 1 在边缘
                let dE = a > L ? (ep * ep + (a - L) * (a - L)).squareRoot() : abs(ep) - ww   // 到边缘的有向距离（负在里面）
                guard dE < bloom || abs(ep) < lineR else { return }       // 羽片、柔光、影子、线都够不着的格子
                let temp = t0 + 0.06 * u + cool * 0.60 * smooth(0.70, 1, u)
                let tipSide = smooth(0.40, 0.85, u)                        // 边缘只在羽尖那一段清楚，往根部渐渐隐去
                let dissolve = 1 - smooth(0.80, 1.0, u)                    // 最尖的一小段散进光里，不留一个硬尖
                // 前层在后层上投下一道柔和的影子：紧挨着这片羽的边缘外侧，后层暗一点（靠明暗分层，不靠描边）
                if dE > 0 && dE < shadowW && p[q] > 0 {
                    let k = 1 - dE / shadowW
                    p[q] *= 1 - 0.40 * k * k * (0.4 + 0.6 * tipSide)
                }
                let alpha = min(max(0.5 - dE / ramp, 0), 1)
                let sh: Float = sheenA > 0 ? sheenA * exp(-sq((u * 0.4 - sheenC) / 0.075)) : 0   // 流光（sheenAt 的同一个式子）
                if alpha > 0 {
                    // 光沿羽轴最亮、往边缘柔和地变淡；羽尖那一段边缘再透一点亮，最尖处淡进光里
                    let inner = max(0, 1 - r)
                    let lit = smooth(0.6, 1.0, r) * tipSide
                    let F = fill * (0.30 + 0.70 * inner * inner.squareRoot() + 0.20 * lit) * (1 - 0.30 * u) * (0.35 + 0.65 * dissolve)
                        * (1 + sh)
                    p[q] = p[q] * (1 - alpha) + alpha * F
                    p[q + 1] = p[q + 1] * (1 - alpha) + alpha * temp
                    p[q + 4] *= 1 - 0.92 * alpha
                }
                if dE > 0 && dE < bloom {
                    let o = 1 - dE / bloom
                    let g = 0.21 * fill * o * o * (1 - 0.30 * u) * (1 + sh)
                    p[q + 2] += g
                    p[q + 3] += g * temp
                }
                if rim > 0 && abs(dE) < lineR && tipSide > 0 {
                    let fall = 1 - sq(dE / lineR)
                    let A = rim * tipSide * dissolve * fall * fall * (1 + 0.6 * sh)
                    if A > p[q + 4] { p[q + 4] = A; p[q + 5] = dE; p[q + 6] = temp }
                }
                if shaft > 0 && a > 0 && a < L * 0.94 && abs(ep) < lineR {
                    var along = (1 - u).squareRoot() * smooth(0.04, 0.12, u)
                    if pulsing { along += pulseA * exp(-sq((u - pulseU) / 0.06)) }
                    let fall = 1 - sq(ep / lineR)
                    let A = shaft * along * fall * fall * (1 + sh)
                    if A > p[q + 4] { p[q + 4] = A; p[q + 5] = ep; p[q + 6] = temp }
                }
            }
        }

        /// 前缘带的一段：从翼骨线往下 tb 厚的一条光带（上沿亮、往下略暗），上沿一道亮线，外面一圈淡光。
        private func rasterBand(_ P0: SIMD2<Float>, _ P1: SIMD2<Float>, tb0: Float, tb1: Float, b0: Float, b1: Float, temp: Float) {
            guard max(b0, b1) > 0.003 else { return }
            let seg = P1 - P0, L = simd_length(seg)
            guard L > 0.5 else { return }
            let d = seg / L, nrm = SIMD2(-d.y, d.x)
            let down: Float = nrm.y >= 0 ? 1 : -1
            let lineR = 2.2 * texel.x
            let tbMax = max(tb0, tb1)
            let bloom = max(0.5 * tbMax, lineR)
            raster(P0, d, aMin: -1, aMax: L + 1, eMin: -(tbMax + bloom), eMax: tbMax + bloom) { p, q, a, e in
                let f = min(max(a / L, 0), 1)
                let tb = tb0 + (tb1 - tb0) * f, b = b0 + (b1 - b0) * f
                let ed = e * down                                          // 0 在前缘线上，往下为正
                let dE = max(-ed, ed - tb)
                let alpha = min(max(0.5 - dE / 5, 0), 1)
                if alpha > 0 {
                    let F = b * (0.80 + 0.20 * max(0, 1 - ed / max(tb, 1)))
                    p[q] = p[q] * (1 - alpha) + alpha * F
                    p[q + 1] = p[q + 1] * (1 - alpha) + alpha * temp
                    p[q + 4] *= 1 - 0.92 * alpha
                }
                if dE > 0 && dE < bloom {
                    let o = 1 - dE / bloom
                    let g = 0.14 * b * o * o
                    p[q + 2] += g
                    p[q + 3] += g * temp
                }
                if abs(ed) < lineR {
                    let fall = 1 - sq(ed / lineR)
                    let A = b * 0.80 * fall * fall
                    if A > p[q + 4] { p[q + 4] = A; p[q + 5] = ed; p[q + 6] = temp }
                }
            }
        }

        /// 走遍以 B 为原点、沿 d 方向的那个斜矩形（沿轴 aMin…aMax、离轴 eMin…eMax）里的每一格：
        /// 逐行算出矩形在这一行覆盖的列区间，只访问这些格。body 拿到累加数组、这一格的下标、沿轴距离和有向离轴距离。
        private func raster(_ B: SIMD2<Float>, _ d: SIMD2<Float>, aMin: Float, aMax: Float, eMin: Float, eMax: Float,
                            _ body: (UnsafeMutableBufferPointer<Float>, Int, Float, Float) -> Void) {
            let nrm = SIMD2(-d.y, d.x)
            let tx = texel.x, ty = texel.y, gw = glowSize.x, gh = glowSize.y
            // 四个角的竖直范围 → 行区间
            let corners = [B + d * aMin + nrm * eMax, B + d * aMin + nrm * eMin, B + d * aMax + nrm * eMax, B + d * aMax + nrm * eMin]
            let yLo = corners.map(\.y).min()!, yHi = corners.map(\.y).max()!
            let j0 = max(0, Int(floor(yLo / ty - 0.5))), j1 = min(gh - 1, Int(ceil(yHi / ty - 0.5)))
            guard j0 <= j1 else { return }
            var touchedLo = Int.max, touchedHi = Int.min
            let stride = Self.accStride
            acc.withUnsafeMutableBufferPointer { p in
                for j in j0...j1 {
                    let qy = (Float(j) + 0.5) * ty - B.y
                    // 两条“板”（沿轴、离轴）在这一行上的交集
                    var lo = -Float.greatestFiniteMagnitude, hi = Float.greatestFiniteMagnitude
                    func slab(_ k: Float, _ c: Float, _ m0: Float, _ m1: Float) -> Bool {   // m0 < qx·k + c < m1
                        if abs(k) < 1e-5 { return c > m0 && c < m1 }
                        let x0 = (m0 - c) / k, x1 = (m1 - c) / k
                        lo = max(lo, min(x0, x1)); hi = min(hi, max(x0, x1))
                        return true
                    }
                    guard slab(d.x, qy * d.y, aMin, aMax), slab(nrm.x, qy * nrm.y, eMin, eMax), lo < hi else { continue }
                    let i0 = max(0, Int(ceil((lo + B.x) / tx - 0.5))), i1 = min(gw - 1, Int(floor((hi + B.x) / tx - 0.5)))
                    guard i0 <= i1 else { continue }
                    touchedLo = min(touchedLo, j); touchedHi = max(touchedHi, j)
                    let rowBase = j * gw
                    for i in i0...i1 {
                        let qx = (Float(i) + 0.5) * tx - B.x
                        body(p, (rowBase + i) * stride, qx * d.x + qy * d.y, qx * nrm.x + qy * nrm.y)
                    }
                }
            }
            if touchedLo <= touchedHi { rowsTouched = (min(rowsTouched.0, touchedLo), max(rowsTouched.1, touchedHi)) }
        }

        // MARK: 字

        /// 羽轴上的字：沿弯曲的羽轴每行（或每列）取一格，分给相邻两格（抗锯齿），羽毛轻轻摆动时字淡入淡出、不跳。
        /// 从羽毛露出来的地方（from）读起；竖着走的从上读到下，横着走的从左读到右——左翼的羽轴朝左伸，
        /// 经文倒着排，读到覆羽边上正好读完。
        private func shaftGlyphs(_ cells: inout [UInt8], cols: Int, rows: Int, cell: SIMD2<Float>, _ B: SIMD2<Float>, _ d: SIMD2<Float>,
                                 _ out: SIMD2<Float>, _ L: Float, bend: Float, from: Float, gain: Float, warm t0: Float, cool: Float,
                                 text: [UInt8]?, pulseU: Float, pulseA: Float) {
            let vertical = abs(d.y) / cell.y >= abs(d.x) / cell.x
            let step = vertical ? cell.y / max(abs(d.y), 1e-3) : cell.x / max(abs(d.x), 1e-3)
            let mirrored = !vertical && d.x < 0
            let bendPx = bend * L
            var along = from * L + step * 0.5
            var k = 0
            while along < L * 0.96 {
                let u = along / L
                let v = gain * ((1 - u).squareRoot() * smooth(from, from + 0.06, u) + 0.8 * pulseA * exp(-sq((u - pulseU) / 0.06)))
                var ch: UInt8 = 0
                if let text {
                    let idx = mirrored ? text.count - 1 - k : k
                    if idx >= 0 && idx < text.count { ch = text[idx] }
                }
                let temp = t0 + 0.06 * u + cool * 0.60 * smooth(0.70, 1, u)
                let weight = 1 - u
                let pos = B + d * along + out * (bendPx * u * u)
                if vertical {
                    let x = pos.x / cell.x - 0.5, x0 = floor(x), w = x - x0
                    let gy = Int(floor(pos.y / cell.y)) + 1
                    put(&cells, cols, rows, Int(x0) + 1, gy, v * (1 - w), temp, ch, weight)
                    put(&cells, cols, rows, Int(x0) + 2, gy, v * w, temp, ch, weight)
                } else {
                    let y = pos.y / cell.y - 0.5, y0 = floor(y), w = y - y0
                    let gx = Int(floor(pos.x / cell.x)) + 1
                    put(&cells, cols, rows, gx, Int(y0) + 1, v * (1 - w), temp, ch, weight)
                    put(&cells, cols, rows, gx, Int(y0) + 2, v * w, temp, ch, weight)
                }
                along += step
                k += 1
            }
        }

        /// 一个往上飘的字（光点）：竖直方向分给相邻两格，飘动是连续的。
        private func mote(_ cells: inout [UInt8], _ cols: Int, _ rows: Int, _ cell: SIMD2<Float>, _ pos: SIMD2<Float>, _ v: Float,
                          temp: Float, ch: UInt8) {
            let y = pos.y / cell.y - 0.5, y0 = floor(y), w = y - y0
            let gx = Int(floor(pos.x / cell.x)) + 1
            put(&cells, cols, rows, gx, Int(y0) + 1, v * (1 - w), temp, ch, 0.4)
            put(&cells, cols, rows, gx, Int(y0) + 2, v * w, temp, ch, 0.4)
        }

        /// 写一格（取最亮的那个：亮的盖住暗的，字符、色温、字重跟着它走）。
        private func put(_ cells: inout [UInt8], _ cols: Int, _ rows: Int, _ gx: Int, _ gy: Int, _ v: Float, _ temp: Float,
                         _ ch: UInt8, _ weight: Float) {
            guard gx >= 0, gy >= 0, gx < cols, gy < rows, v > 0.004 else { return }
            let k = (gy * cols + gx) * 4
            let r = UInt8(min(1, v) * 255)
            guard r > cells[k] else { return }
            cells[k] = r
            cells[k + 1] = UInt8(min(1, max(0, temp)) * 255)
            cells[k + 2] = ch
            cells[k + 3] = UInt8(min(1, max(0, weight)) * 255)
        }

        // MARK: 工具

        /// 阻尼弹簧从 0 到 1 的阶跃响应：阻尼比小于 1 时会冲过头再弹回。
        static func spring(_ t: Float, zeta z: Float, omega w: Float) -> Float {
            guard t > 0 else { return 0 }
            if z >= 1 { return 1 - (1 + w * t) * exp(-w * t) }
            let wd = w * (1 - z * z).squareRoot()
            return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
        }
    }
}

private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

private func easeOutCubic(_ x: Float) -> Float {
    let t = max(0, min(1, x))
    return 1 - (1 - t) * (1 - t) * (1 - t)
}

private func sq(_ x: Float) -> Float { x * x }
private func rad(_ deg: Float) -> Float { deg * .pi / 180 }
private func deg(_ rad: Float) -> Float { rad * 180 / .pi }

/// 绕原点转 a 弧度（屏幕坐标 y 向下，正角度看起来是顺时针）。
private func rotate(_ v: SIMD2<Float>, _ a: Float) -> SIMD2<Float> {
    let c = cos(a), s = sin(a)
    return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
}

private func mix32(_ x: UInt32) -> UInt32 {
    var h = x
    h ^= h >> 16; h &*= 0x7feb352d
    h ^= h >> 15; h &*= 0x846ca68b
    h ^= h >> 16
    return h
}
