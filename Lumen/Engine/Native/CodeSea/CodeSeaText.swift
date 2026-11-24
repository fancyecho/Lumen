import Foundation

// Ported from Code Sea (Sources/CodeText.swift). The logic is unchanged; types are nested under
// `CodeSea` so their names stay out of Lumen's module namespace.
extension CodeSea {
    /// 字符海：整屏铺满、像代码但不是真代码的字符。
    /// 按“伪词元”连续生成（小写词、驼峰词、数字、运算符、括号），不分行、不缩进、几乎没有空白，
    /// 远看是一片均匀的代码质感，近看也读不出内容。
    enum CodeText {
        /// 分类决定平时的灰度（着色器 classLevel）：0 普通词 1 短关键字样 4 数字 5 符号 6 大写开头。
        /// 7 是藏在屏幕正中的那句话：不会被改写，也不会被人像的补字覆盖。
        enum Kind: UInt8 { case word = 0, keyword = 1, number = 4, symbol = 5, type = 6, message = 7 }

        private static let lower = Array("abcdefghijklmnopqrstuvwxyz".utf8)
        private static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
        private static let digits = Array("0123456789".utf8)
        private static let operators = Array("=+-*/<>&|!?:%^~".utf8)
        private static let brackets = Array("(){}[]".utf8)
        private static let joiners = Array(".,;_#$@".utf8)
        // 字母出现频率接近英文/代码：常见字母多抽几次。
        private static let common = Array("eeeeettttaaaoooiiinnnsssrrrhhlldcumfpgwybvkxjqz".utf8)

        /// cols×rows 的字符网格（RGBA8：字符、分类、随机数、0）。
        /// message 以 messageAt（网格坐标）为中心写进那一行。
        static func grid(cols: Int, rows: Int, seed: UInt64, message: String? = nil, messageAt: SIMD2<Int>? = nil) -> [UInt8] {
            var rng = SplitMix(seed: seed)
            var out = [UInt8](repeating: 0, count: cols * rows * 4)
            var k = 0
            let total = cols * rows
            func put(_ c: UInt8, _ kind: Kind) {
                guard k < total else { return }
                out[k * 4] = c
                out[k * 4 + 1] = kind.rawValue
                out[k * 4 + 2] = UInt8(truncatingIfNeeded: rng.next())
                k += 1
            }
            func pick(_ a: [UInt8]) -> UInt8 { a[Int(rng.next() % UInt64(a.count))] }
            func roll(_ n: UInt64) -> UInt64 { rng.next() % n }

            while k < total {
                switch roll(100) {
                case 0..<46:   // 小写词，偶尔驼峰
                    let n = 2 + Int(roll(7))
                    for i in 0..<n { put(i > 1 && roll(6) == 0 ? pick(upper) : pick(common), .word) }
                case 46..<54:  // 大写开头的类型名
                    put(pick(upper), .type)
                    for _ in 0..<(2 + Int(roll(6))) { put(pick(lower), .type) }
                case 54..<60:  // 短关键字样
                    for _ in 0..<(2 + Int(roll(3))) { put(pick(common), .keyword) }
                case 60..<68:  // 数字
                    for _ in 0..<(1 + Int(roll(4))) { put(pick(digits), .number) }
                    if roll(4) == 0 { put(46, .number); put(pick(digits), .number) }
                case 68..<80:  // 运算符
                    for _ in 0..<(1 + Int(roll(2))) { put(pick(operators), .symbol) }
                case 80..<91:  // 括号
                    put(pick(brackets), .symbol)
                case 91..<97:  // 连接符
                    put(pick(joiners), .symbol)
                default:       // 零星空格，让字符海有一点呼吸感
                    put(32, .word)
                }
            }
            // 那句话写在指定位置（默认屏幕正中）。
            if let message, !message.isEmpty {
                let chars = Array(message.utf8)
                let at = messageAt ?? SIMD2(cols / 2, rows / 2)
                let row = min(max(at.y, 0), rows - 1), x0 = at.x - chars.count / 2
                for (n, c) in chars.enumerated() where x0 + n >= 0 && x0 + n < cols {
                    let k = (row * cols + x0 + n) * 4
                    out[k] = c
                    out[k + 1] = Kind.message.rawValue
                }
            }
            return out
        }
    }

    /// 组成她的字：浪漫的诗与句子（全部是公有领域的文本）。
    /// 每行诗写成驼峰式的一串（"shallICompareTheeToASummer'sDay?"），行与行用 "; " 接起来、段与段用 " :: " 接起来——
    /// 远看和字符海一样像代码，凑近能读出一句句情诗。
    enum Verses {
        static func stream(_ text: String) -> [UInt8] {
            var out: [UInt8] = []
            var passage: [String] = []
            func flush() {
                guard !passage.isEmpty else { return }
                if !out.isEmpty { out += Array(" :: ".utf8) }
                out += Array(passage.joined(separator: "; ").utf8)
                passage.removeAll()
            }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.isASCII && $0.value >= 32 }))
                    .trimmingCharacters(in: .whitespaces)
                if line.isEmpty { flush(); continue }
                let words = line.split(separator: " ").map(String.init)
                var joined = ""
                for (n, w) in words.enumerated() {
                    guard let first = w.first else { continue }
                    joined += n == 0 ? first.lowercased() + w.dropFirst() : first.uppercased() + w.dropFirst()
                }
                passage.append(joined)
            }
            flush()
            return out.isEmpty ? Array("loveIsTheAnswer".utf8) : out
        }
    }

    /// 小而确定的随机数（同一块屏幕每次铺出的字符一样）。
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
