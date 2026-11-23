import Foundation

/// A value a wallpaper's user property can hold.
enum PropertyValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string((try? container.decode(String.self)) ?? "")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    /// Reads whatever JSON put in a `value` field.
    init(json: Any?) {
        switch json {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let string as String: self = .string(string)
        default: self = .string("")
        }
    }

    var boolValue: Bool {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): ["true", "1", "yes"].contains(value.lowercased())
        }
    }

    var doubleValue: Double {
        switch self {
        case .bool(let value): value ? 1 : 0
        case .number(let value): value
        case .string(let value): Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    var stringValue: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .number(let value):
            if value.rounded() == value && abs(value) < 1e15 { String(Int64(value)) } else { String(value) }
        case .string(let value): value
        }
    }

    /// The value as a JSON fragment for the web property API.
    var jsonLiteral: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value.isFinite ? String(value) : "0"
        case .string(let value):
            let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
    }
}

/// One customisable property from a Wallpaper Engine `project.json`.
struct WEProperty: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case slider, bool, color, combo, textinput, text, file, directory, group, scenetexture, usershortcut, unknown
    }

    struct Option: Codable, Hashable, Sendable {
        var label: String
        var value: String
    }

    var id: String
    var kind: Kind
    var label: String
    var order: Int
    var defaultValue: PropertyValue
    var min: Double?
    var max: Double?
    var step: Double?
    var precision: Int?
    var options: [Option] = []
    /// A small JavaScript expression from the project, e.g. `daynight.value == 2`.
    var condition: String?

    /// Properties people can actually change in Lumen.
    var isEditable: Bool {
        switch kind {
        case .slider, .bool, .color, .combo, .textinput: true
        default: false
        }
    }
}

/// A Wallpaper Engine project folder: `project.json` plus the files it names.
struct WEProject: Sendable {
    enum Kind: String, Sendable {
        case video, web, scene, application, preset, unknown
    }

    let folder: URL
    let kind: Kind
    let entry: String
    let title: String
    let preview: String?
    let workshopID: String?
    let tags: [String]
    let contentRating: String?
    let properties: [WEProperty]
    let supportsAudio: Bool

    var entryURL: URL { folder.appending(path: entry) }
    var previewURL: URL? { preview.map { folder.appending(path: $0) } }

    static func isProjectFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appending(path: "project.json").path)
    }

    static func load(folder: URL) throws -> WEProject {
        let file = folder.appending(path: "project.json")
        let data = try Data(contentsOf: file)
        guard let json = LenientJSON.object(from: data) else { throw ProjectError.unreadable }

        let rawType = (json["type"] as? String)?.lowercased() ?? ""
        let entry = (json["file"] as? String) ?? ""
        let kind = Kind(rawValue: rawType) ?? .unknown
        let general = json["general"] as? [String: Any] ?? [:]
        let localization = general["localization"] as? [String: [String: String]] ?? [:]
        let strings = Self.strings(from: localization)

        var properties: [WEProperty] = []
        for (key, value) in general["properties"] as? [String: Any] ?? [:] {
            guard let raw = value as? [String: Any] else { continue }
            properties.append(Self.property(key: key, raw: raw, strings: strings))
        }
        properties.sort { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }

        let workshopID: String? = {
            if let id = json["workshopid"] as? String, !id.isEmpty { return id }
            if let id = json["workshopid"] as? NSNumber { return id.stringValue }
            let name = folder.lastPathComponent
            return name.allSatisfy(\.isNumber) && name.count >= 6 ? name : nil
        }()

        let title = Self.plainText(json["title"] as? String ?? "")
        return WEProject(
            folder: folder,
            kind: kind,
            entry: entry,
            title: title.isEmpty ? folder.lastPathComponent : title,
            preview: (json["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            workshopID: workshopID,
            tags: json["tags"] as? [String] ?? [],
            contentRating: json["contentrating"] as? String,
            properties: properties,
            supportsAudio: general["supportsaudioprocessing"] as? Bool ?? false
        )
    }

    enum ProjectError: LocalizedError {
        case unreadable
        case unsupported(String)
        case missingEntry(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "project.json couldn't be read.")
            case .unsupported(let type): String(localized: "“\(type)” wallpapers are Windows programs and can't run on a Mac.")
            case .missingEntry(let file): String(localized: "The project names “\(file)”, but the file isn't in the folder.")
            }
        }
    }

    // MARK: Parsing helpers

    private static func property(key: String, raw: [String: Any], strings: [String: String]) -> WEProperty {
        let type = (raw["type"] as? String)?.lowercased() ?? ""
        let kind = WEProperty.Kind(rawValue: type) ?? (type.isEmpty ? .text : .unknown)
        let text = raw["text"] as? String ?? key
        var value = PropertyValue(json: raw["value"])
        switch kind {
        case .slider:
            value = .number(value.doubleValue)
        case .bool:
            value = .bool(value.boolValue)
        case .combo, .color, .textinput:
            value = .string(value.stringValue)
        default:
            break
        }
        let options = (raw["options"] as? [[String: Any]] ?? []).map { option in
            WEProperty.Option(
                label: localized(option["label"] as? String ?? "", strings: strings),
                value: PropertyValue(json: option["value"]).stringValue
            )
        }
        return WEProperty(
            id: key,
            kind: kind,
            label: localized(text, strings: strings),
            order: (raw["order"] as? NSNumber)?.intValue ?? (raw["index"] as? NSNumber)?.intValue ?? 0,
            defaultValue: value,
            min: (raw["min"] as? NSNumber)?.doubleValue,
            max: (raw["max"] as? NSNumber)?.doubleValue,
            step: (raw["step"] as? NSNumber)?.doubleValue,
            precision: (raw["precision"] as? NSNumber)?.intValue,
            options: options,
            condition: raw["condition"] as? String
        )
    }

    /// Picks the project's own translations for the current language, falling back to English.
    private static func strings(from localization: [String: [String: String]]) -> [String: String] {
        guard !localization.isEmpty else { return [:] }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let candidates: [String] = preferred.hasPrefix("zh")
            ? (preferred.contains("hant") || preferred.contains("tw") || preferred.contains("hk") ? ["zh-cht", "zh-tw", "zh-chs"] : ["zh-chs", "zh-cn"])
            : [preferred, String(preferred.prefix(2))]
        var merged = localization["en-us"] ?? localization["en"] ?? [:]
        for code in candidates.reversed() {
            if let table = localization[code] { merged.merge(table) { _, new in new } }
        }
        return merged
    }

    private static func localized(_ text: String, strings: [String: String]) -> String {
        if let translated = strings[text] { return plainText(translated) }
        if let builtin = builtinLabels[text] { return builtin }
        if text.hasPrefix("ui_") {
            let words = text.replacingOccurrences(of: "ui_browse_properties_", with: "")
                .replacingOccurrences(of: "ui_editor_properties_", with: "")
                .replacingOccurrences(of: "ui_", with: "")
                .split(separator: "_")
            return words.joined(separator: " ").capitalized
        }
        return plainText(text)
    }

    private static let builtinLabels: [String: String] = [
        "ui_browse_properties_scheme_color": String(localized: "Scheme color"),
        "ui_browse_properties_alignment": String(localized: "Alignment"),
        "ui_browse_properties_audio_volume": String(localized: "Volume"),
        "ui_editor_importer_type_image": String(localized: "Image"),
    ]

    /// Strips HTML markup and entities that projects put in titles and labels.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<br\\s*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// JSON as Wallpaper Engine writes it: sometimes with a byte-order mark, trailing commas or comments.
enum LenientJSON {
    static func parse(_ data: Data) -> Any? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if let value = try? JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed]) { return value }
        return try? JSONSerialization.jsonObject(with: bytes, options: [.json5Allowed, .fragmentsAllowed])
    }

    static func object(from data: Data) -> [String: Any]? {
        parse(data) as? [String: Any]
    }
}

extension WEProperty {
    /// Evaluates the small subset of JavaScript that `condition` strings use, so the
    /// properties list can hide options the way Wallpaper Engine does.
    static func conditionHolds(_ condition: String?, values: [String: PropertyValue]) -> Bool {
        guard let condition = condition?.trimmingCharacters(in: .whitespaces), !condition.isEmpty else { return true }
        var evaluator = ConditionEvaluator(source: condition, values: values)
        return evaluator.evaluate() ?? true
    }
}

/// Tiny recursive-descent evaluator for `a.value == 2 && (b.value || !c.value)`.
private struct ConditionEvaluator {
    private var tokens: [String]
    private var index = 0
    private let values: [String: PropertyValue]

    init(source: String, values: [String: PropertyValue]) {
        self.values = values
        var tokens: [String] = []
        var scanner = Substring(source)
        let operators = ["===", "!==", "==", "!=", ">=", "<=", "&&", "||", "!", "(", ")", ">", "<"]
        while let first = scanner.first {
            if first.isWhitespace { scanner = scanner.dropFirst(); continue }
            if let op = operators.first(where: { scanner.hasPrefix($0) }) {
                tokens.append(op)
                scanner = scanner.dropFirst(op.count)
                continue
            }
            if first == "\"" || first == "'" {
                let rest = scanner.dropFirst()
                let end = rest.firstIndex(of: first) ?? rest.endIndex
                tokens.append("\"" + rest[rest.startIndex..<end])
                scanner = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[end...]
                continue
            }
            let end = scanner.firstIndex { $0.isWhitespace || "=!<>&|()".contains($0) } ?? scanner.endIndex
            tokens.append(String(scanner[scanner.startIndex..<end]))
            scanner = scanner[end...]
        }
        self.tokens = tokens
    }

    mutating func evaluate() -> Bool? {
        let result = parseOr()
        return index == tokens.count ? result.boolValue : nil
    }

    private mutating func peek() -> String? { index < tokens.count ? tokens[index] : nil }
    private mutating func next() -> String? {
        defer { index += 1 }
        return peek()
    }

    private mutating func parseOr() -> PropertyValue {
        var left = parseAnd()
        while peek() == "||" {
            index += 1
            let right = parseAnd()
            left = .bool(left.boolValue || right.boolValue)
        }
        return left
    }

    private mutating func parseAnd() -> PropertyValue {
        var left = parseComparison()
        while peek() == "&&" {
            index += 1
            let right = parseComparison()
            left = .bool(left.boolValue && right.boolValue)
        }
        return left
    }

    private mutating func parseComparison() -> PropertyValue {
        let left = parseUnary()
        guard let op = peek(), ["==", "===", "!=", "!==", ">", "<", ">=", "<="].contains(op) else { return left }
        index += 1
        let right = parseUnary()
        switch op {
        case "==", "===": return .bool(Self.equal(left, right))
        case "!=", "!==": return .bool(!Self.equal(left, right))
        case ">": return .bool(left.doubleValue > right.doubleValue)
        case "<": return .bool(left.doubleValue < right.doubleValue)
        case ">=": return .bool(left.doubleValue >= right.doubleValue)
        default: return .bool(left.doubleValue <= right.doubleValue)
        }
    }

    private mutating func parseUnary() -> PropertyValue {
        if peek() == "!" {
            index += 1
            return .bool(!parseUnary().boolValue)
        }
        if peek() == "(" {
            index += 1
            let value = parseOr()
            if peek() == ")" { index += 1 }
            return value
        }
        guard let token = next() else { return .bool(false) }
        if token.hasPrefix("\"") { return .string(String(token.dropFirst())) }
        if token == "true" { return .bool(true) }
        if token == "false" { return .bool(false) }
        if let number = Double(token) { return .number(number) }
        let name = token.hasSuffix(".value") ? String(token.dropLast(6)) : token
        return values[name] ?? .bool(false)
    }

    private static func equal(_ a: PropertyValue, _ b: PropertyValue) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        default:
            if let x = Double(a.stringValue), let y = Double(b.stringValue) { return x == y }
            return a.stringValue == b.stringValue
        }
    }
}
