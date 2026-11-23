import Foundation

/// The part of a C preprocessor Wallpaper Engine shaders rely on: `#include`, `#if`/`#ifdef`
/// chains and object-like `#define`s for conditions. It resolves every conditional itself, so
/// the translator knows exactly which uniforms, varyings and samplers a combination declares.
/// `#define` lines stay in the output for Metal's own preprocessor to expand.
struct WEShaderPreprocessor {
    /// Returns an include's source (e.g. `common.h`), or nil when it doesn't exist.
    var resolveInclude: (String) -> String?
    private(set) var defines: [String: String]
    /// Every macro the output defines, so a second program in the same library can undefine them.
    private(set) var emittedMacros: [String] = []
    private var included = Set<String>()

    init(defines: [String: String], resolveInclude: @escaping (String) -> String?) {
        self.defines = defines
        self.resolveInclude = resolveInclude
    }

    mutating func process(_ source: String) -> String {
        var output: [String] = []
        output.reserveCapacity(512)
        process(source, into: &output, depth: 0)
        return output.joined(separator: "\n")
    }

    // MARK: Static scanning (before conditionals are known)

    /// All text reachable through includes, ignoring conditionals: used to find combo and
    /// sampler annotations before deciding which branches are active.
    static func flatten(_ source: String, resolveInclude: (String) -> String?, seen: inout Set<String>) -> String {
        var result = ""
        for line in source.components(separatedBy: "\n") {
            if let name = includeName(in: line) {
                guard !seen.contains(name), let included = resolveInclude(name) else { continue }
                seen.insert(name)
                result += flatten(included, resolveInclude: resolveInclude, seen: &seen) + "\n"
            } else {
                result += line + "\n"
            }
        }
        return result
    }

    static func includeName(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#"), trimmed.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("include") else { return nil }
        guard let open = trimmed.firstIndex(where: { $0 == "\"" || $0 == "<" }) else { return nil }
        let rest = trimmed[trimmed.index(after: open)...]
        guard let close = rest.firstIndex(where: { $0 == "\"" || $0 == ">" }) else { return nil }
        return String(rest[rest.startIndex..<close])
    }

    // MARK: Processing

    private struct Frame {
        let parentActive: Bool
        var active: Bool
        var taken: Bool
    }

    private mutating func process(_ source: String, into output: inout [String], depth: Int) {
        guard depth < 16 else { return }
        let lines = Self.joinContinuations(Self.stripBlockComments(source))
        var stack: [Frame] = []
        var active: Bool { stack.last?.active ?? true }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else {
                if active { output.append(line) }
                continue
            }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let keyword = String(body.prefix { $0.isLetter })
            let argument = body.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            let expression = Self.stripLineComment(argument)

            switch keyword {
            case "if":
                let value = active && evaluate(expression) != 0
                stack.append(Frame(parentActive: active, active: value, taken: value))
            case "ifdef":
                let value = active && defines[Self.identifier(expression)] != nil
                stack.append(Frame(parentActive: active, active: value, taken: value))
            case "ifndef":
                let value = active && defines[Self.identifier(expression)] == nil
                stack.append(Frame(parentActive: active, active: value, taken: value))
            case "elif":
                guard var frame = stack.popLast() else { continue }
                if frame.taken || !frame.parentActive {
                    frame.active = false
                } else {
                    frame.active = evaluate(expression) != 0
                    frame.taken = frame.active
                }
                stack.append(frame)
            case "else":
                guard var frame = stack.popLast() else { continue }
                frame.active = frame.parentActive && !frame.taken
                frame.taken = true
                stack.append(frame)
            case "endif":
                _ = stack.popLast()
            case "include":
                guard active, let name = Self.includeName(in: trimmed), !included.contains(name) else { continue }
                included.insert(name)
                if let text = resolveInclude(name) {
                    process(text, into: &output, depth: depth + 1)
                }
            case "define":
                guard active else { continue }
                let name = String(argument.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty else { continue }
                let rest = argument.dropFirst(name.count)
                if rest.hasPrefix("(") {
                    defines[name] = "1"
                } else {
                    defines[name] = Self.stripLineComment(rest.trimmingCharacters(in: .whitespaces))
                }
                emittedMacros.append(name)
                output.append(line)
            case "undef":
                guard active else { continue }
                defines[Self.identifier(expression)] = nil
                output.append(line)
            case "require", "version", "extension", "pragma", "line":
                continue
            default:
                if active { output.append(line) }
            }
        }
    }

    private static func identifier(_ text: String) -> String {
        String(text.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    static func stripLineComment(_ text: String) -> String {
        guard let range = text.range(of: "//") else { return text }
        return String(text[text.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Removes `/* … */` comments while keeping line breaks, so line numbers stay meaningful.
    static func stripBlockComments(_ source: String) -> String {
        guard source.contains("/*") else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        var inBlock = false
        var inLineComment = false
        while index < source.endIndex {
            let char = source[index]
            let next = source.index(after: index)
            let nextChar: Character? = next < source.endIndex ? source[next] : nil
            if inBlock {
                if char == "*", nextChar == "/" {
                    inBlock = false
                    index = source.index(after: next)
                    continue
                }
                if char == "\n" { result.append("\n") }
            } else if inLineComment {
                result.append(char)
                if char == "\n" { inLineComment = false }
            } else if char == "/", nextChar == "*" {
                inBlock = true
                index = source.index(after: next)
                continue
            } else {
                if char == "/", nextChar == "/" { inLineComment = true }
                result.append(char)
            }
            index = next
        }
        return result
    }

    static func joinContinuations(_ source: String) -> [String] {
        var lines: [String] = []
        var pending = ""
        for raw in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.hasSuffix("\\") {
                pending += raw.dropLast() + " "
            } else {
                lines.append(pending + raw)
                pending = ""
            }
        }
        if !pending.isEmpty { lines.append(pending) }
        return lines
    }

    // MARK: Conditions

    /// Evaluates a `#if` expression: integers, macros (undefined ones are 0), `defined()`,
    /// arithmetic, comparisons and logic.
    func evaluate(_ expression: String) -> Int {
        var parser = ConditionParser(tokens: Self.tokenize(expression), defines: defines)
        return parser.parse()
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex
        let twoCharacter = ["&&", "||", "==", "!=", "<=", ">=", "<<", ">>"]
        while index < text.endIndex {
            let char = text[index]
            if char.isWhitespace {
                index = text.index(after: index)
                continue
            }
            let rest = text[index...]
            if let op = twoCharacter.first(where: { rest.hasPrefix($0) }) {
                tokens.append(op)
                index = text.index(index, offsetBy: 2)
                continue
            }
            if char.isLetter || char == "_" || char.isNumber || char == "." {
                let end = rest.firstIndex { !($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") } ?? text.endIndex
                tokens.append(String(text[index..<end]))
                index = end
                continue
            }
            tokens.append(String(char))
            index = text.index(after: index)
        }
        return tokens
    }
}

private struct ConditionParser {
    let tokens: [String]
    let defines: [String: String]
    var index = 0
    var depth = 0

    init(tokens: [String], defines: [String: String], depth: Int = 0) {
        self.tokens = tokens
        self.defines = defines
        self.depth = depth
    }

    mutating func parse() -> Int { parseTernary() }

    private var current: String? { index < tokens.count ? tokens[index] : nil }

    private mutating func accept(_ token: String) -> Bool {
        if current == token {
            index += 1
            return true
        }
        return false
    }

    private mutating func parseTernary() -> Int {
        let condition = parseOr()
        if accept("?") {
            let a = parseTernary()
            _ = accept(":")
            let b = parseTernary()
            return condition != 0 ? a : b
        }
        return condition
    }

    private mutating func parseOr() -> Int {
        var value = parseAnd()
        while accept("||") { value = (parseAnd() != 0 || value != 0) ? 1 : 0 }
        return value
    }

    private mutating func parseAnd() -> Int {
        var value = parseEquality()
        while accept("&&") {
            let rhs = parseEquality()
            value = (value != 0 && rhs != 0) ? 1 : 0
        }
        return value
    }

    private mutating func parseEquality() -> Int {
        var value = parseRelational()
        while true {
            if accept("==") { value = value == parseRelational() ? 1 : 0 }
            else if accept("!=") { value = value != parseRelational() ? 1 : 0 }
            else { return value }
        }
    }

    private mutating func parseRelational() -> Int {
        var value = parseAdditive()
        while true {
            if accept("<=") { value = value <= parseAdditive() ? 1 : 0 }
            else if accept(">=") { value = value >= parseAdditive() ? 1 : 0 }
            else if accept("<") { value = value < parseAdditive() ? 1 : 0 }
            else if accept(">") { value = value > parseAdditive() ? 1 : 0 }
            else { return value }
        }
    }

    private mutating func parseAdditive() -> Int {
        var value = parseMultiplicative()
        while true {
            if accept("+") { value &+= parseMultiplicative() }
            else if accept("-") { value &-= parseMultiplicative() }
            else { return value }
        }
    }

    private mutating func parseMultiplicative() -> Int {
        var value = parseUnary()
        while true {
            if accept("*") { value &*= parseUnary() }
            else if accept("/") { let d = parseUnary(); value = d == 0 ? 0 : value / d }
            else if accept("%") { let d = parseUnary(); value = d == 0 ? 0 : value % d }
            else { return value }
        }
    }

    private mutating func parseUnary() -> Int {
        if accept("!") { return parseUnary() == 0 ? 1 : 0 }
        if accept("-") { return -parseUnary() }
        if accept("+") { return parseUnary() }
        return parsePrimary()
    }

    private mutating func parsePrimary() -> Int {
        guard let token = current else { return 0 }
        index += 1
        if token == "(" {
            let value = parseTernary()
            _ = accept(")")
            return value
        }
        if token == "defined" {
            let parenthesised = accept("(")
            let name = current ?? ""
            index += 1
            if parenthesised { _ = accept(")") }
            return defines[name] != nil ? 1 : 0
        }
        if let number = Self.number(token) { return number }
        guard let replacement = defines[token] else { return 0 }
        if replacement.isEmpty { return 1 }
        if let number = Self.number(replacement) { return number }
        guard depth < 8 else { return 0 }
        var nested = ConditionParser(tokens: WEShaderPreprocessor.tokenize(replacement), defines: defines, depth: depth + 1)
        return nested.parse()
    }

    private static func number(_ token: String) -> Int? {
        var text = token.lowercased()
        while let last = text.last, "ulf".contains(last), text.count > 1, !text.hasPrefix("0x") { text.removeLast() }
        if text.hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        if let value = Int(text) { return value }
        if let value = Double(text) { return Int(value) }
        return nil
    }
}
