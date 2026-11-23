import Foundation
import simd

/// Reads Wallpaper Engine's loosely-typed scene values: numbers, `"1 2 3"` strings, booleans,
/// and objects bound to user properties (`{"user": "dust", "value": true}`).
struct SceneValues {
    let properties: [String: PropertyValue]
    /// For two-option on/off combo properties bound directly to a boolean without a condition
    /// (e.g. `"1": 开, "2": 关` on `cameraparallax`), records option values that mean false.
    let comboOffValues: [String: Set<String>]

    init(properties: [String: PropertyValue], comboOffValues: [String: Set<String>] = [:]) {
        self.properties = properties
        self.comboOffValues = comboOffValues
    }

    /// Scans `project.json` for two-option on/off combos so direct boolean bindings treat the
    /// off option (such as `"2"` = `"关"`) as `false` rather than non-zero `true`.
    static func comboOffValues(from projectJSON: [String: Any]?) -> [String: Set<String>] {
        guard let general = projectJSON?["general"] as? [String: Any],
              let props = general["properties"] as? [String: Any]
        else { return [:] }
        let offLabels: Set<String> = ["关", "关闭", "无", "off", "no", "none", "false", "disabled", "disable"]
        let onLabels: Set<String> = ["开", "开启", "有", "on", "yes", "true", "enabled", "enable"]
        var result: [String: Set<String>] = [:]
        for (key, raw) in props {
            guard let dict = raw as? [String: Any],
                  (dict["type"] as? String)?.lowercased() == "combo",
                  let options = dict["options"] as? [[String: Any]], options.count == 2
            else { continue }
            var offValue: String?
            var hasOn = false
            for option in options {
                let label = (option["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = option["value"].map { PropertyValue(json: $0).stringValue } ?? ""
                if offLabels.contains(label) { offValue = value }
                else if onLabels.contains(label) { hasOn = true }
            }
            if hasOn, let offValue { result[key] = [offValue] }
        }
        return result
    }

    /// Unwraps `{"value": …}` wrappers, applying a user-property binding when present.
    func resolve(_ raw: Any?) -> Any? {
        resolve(raw, matching: nil, depth: 0)
    }

    private func resolve(_ raw: Any?, matching destination: Any?, depth: Int = 0) -> Any? {
        guard depth < 8, let object = raw as? [String: Any] else { return raw }
        let fallback = object["value"]
        let user = object["user"]
        guard fallback != nil || user != nil else { return raw }
        let binding = user as? [String: Any]
        let name = user as? String ?? binding?["name"] as? String
        guard let name, let bound = properties[name] else {
            return resolve(fallback, matching: destination, depth: depth + 1)
        }
        if let condition = binding?["condition"] {
            // Option IDs are compared before converting values to the field's type.
            return bound.stringValue == PropertyValue(json: condition).stringValue
        }
        let target = destination ?? fallback
        if let number = target as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID(),
           comboOffValues[name]?.contains(bound.stringValue) == true {
            return false
        }
        return bound.anyValue(matching: target)
    }

    func float(_ raw: Any?, default fallback: Float) -> Float {
        switch resolve(raw) {
        case let number as NSNumber: return number.floatValue
        case let string as String: return Float(string.split(separator: " ").first ?? "") ?? fallback
        default: return fallback
        }
    }

    func bool(_ raw: Any?, default fallback: Bool) -> Bool {
        switch resolve(raw, matching: false) {
        case let number as NSNumber: return number.boolValue
        case let string as String: return ["true", "1"].contains(string.lowercased())
        default: return fallback
        }
    }

    func int(_ raw: Any?, default fallback: Int) -> Int {
        Int(float(raw, default: Float(fallback)))
    }

    func vector(_ raw: Any?) -> [Float]? {
        Self.components(resolve(raw))
    }

    func vec2(_ raw: Any?, default fallback: SIMD2<Float>) -> SIMD2<Float> {
        guard let values = vector(raw), !values.isEmpty else { return fallback }
        return values.count == 1 ? SIMD2(repeating: values[0]) : SIMD2(values[0], values[1])
    }

    func vec3(_ raw: Any?, default fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let values = vector(raw), !values.isEmpty else { return fallback }
        if values.count == 1 { return SIMD3(repeating: values[0]) }
        return SIMD3(values[0], values[1], values.count > 2 ? values[2] : fallback.z)
    }

    static func components(_ raw: Any?) -> [Float]? {
        switch raw {
        case let number as NSNumber:
            return [number.floatValue]
        case let string as String:
            let parts = string.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
            return parts.isEmpty ? nil : parts
        case let array as [Any]:
            let parts = array.compactMap { ($0 as? NSNumber)?.floatValue }
            return parts.isEmpty ? nil : parts
        default:
            return nil
        }
    }
}

extension PropertyValue {
    /// The property's value in the shape the scene expects at this spot.
    func anyValue(matching template: Any?) -> Any {
        switch template {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            guard case .string(let value) = self else { return boolValue }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            // Parse the whole string so an RGB color is not read as a single scalar.
            return Double(text).map { $0 != 0 } ?? !text.isEmpty
        case is NSNumber:
            return doubleValue
        default:
            switch self {
            case .bool(let value): return value
            case .number(let value): return value
            case .string(let value): return value
            }
        }
    }
}

/// The parts of `scene.json` the renderer uses, with user properties applied.
struct SceneDocument {
    struct Effect {
        let file: String
        let visible: Bool
        let passes: [PassOverride]
    }

    /// Per-pass settings an effect instance overrides.
    struct PassOverride {
        var constants: [String: Any] = [:]
        var textures: [String?] = []
        var combos: [String: Int] = [:]
    }

    struct Object {
        enum Kind { case image, particle, text, sound, model, light, group }

        let id: Int
        let name: String
        let kind: Kind
        let raw: [String: Any]
        var origin: SIMD3<Float>
        var scale: SIMD3<Float>
        var angles: SIMD3<Float>
        var size: SIMD2<Float>?
        var visible: Bool
        var alpha: Float
        var color: SIMD3<Float>
        var brightness: Float
        var colorBlendMode: Int
        var parallaxDepth: SIMD2<Float>
        var parent: Int?
        var effects: [Effect]
        var image: String?
        var particle: String?
        /// Keyframed properties (alpha, color, origin…), evaluated every frame.
        var animations: [String: SceneAnimation] = [:]

        /// The object's animatable properties at `time`.
        func state(at time: Float, animationFrames: [String: Float] = [:]) -> State {
            var state = State(origin: origin, scale: scale, angles: angles, alpha: alpha, color: color, brightness: brightness, visible: visible)
            guard !animations.isEmpty else { return state }
            func animatedValues(_ property: String) -> [Float]? {
                guard let animation = animations[property] else { return nil }
                let timeline = SceneAnimation.timelineProperty(for: property, in: animations)
                let driver = animations[timeline] ?? animation
                return animation.values(atFrame: animationFrames[timeline] ?? driver.frame(at: time))
            }
            func vector(_ key: String, _ current: SIMD3<Float>) -> SIMD3<Float> {
                guard let values = animatedValues(key) else { return current }
                var result = current
                for index in 0..<min(3, values.count) { result[index] = values[index] }
                return result
            }
            state.origin = vector("origin", origin)
            state.scale = vector("scale", scale)
            state.angles = vector("angles", angles)
            state.color = vector("color", color)
            if let alpha = animatedValues("alpha") { state.alpha = alpha.first ?? 0 }
            if let brightness = animatedValues("brightness") { state.brightness = brightness.first ?? 0 }
            if let visible = animatedValues("visible") { state.visible = (visible.first ?? 0) > 0.5 }
            return state
        }

        var hasAnimatedTransform: Bool {
            animations["origin"] != nil || animations["scale"] != nil || animations["angles"] != nil
        }
    }

    struct State {
        var origin: SIMD3<Float>
        var scale: SIMD3<Float>
        var angles: SIMD3<Float>
        var alpha: Float
        var color: SIMD3<Float>
        var brightness: Float
        var visible: Bool
    }

    var clearColor: SIMD3<Float>
    var canvas: SIMD2<Float>
    var isOrthographic: Bool
    var parallaxEnabled: Bool
    var parallaxAmount: Float
    var parallaxDelay: Float
    var parallaxMouseInfluence: Float
    var ambientColor: SIMD3<Float>
    var skylightColor: SIMD3<Float>
    var objects: [Object]

    init(json: [String: Any], values: SceneValues) {
        let general = json["general"] as? [String: Any] ?? [:]
        clearColor = values.vec3(general["clearcolor"], default: SIMD3(0, 0, 0))
        if let projection = general["orthogonalprojection"] as? [String: Any],
           let width = (projection["width"] as? NSNumber)?.floatValue,
           let height = (projection["height"] as? NSNumber)?.floatValue, width > 0, height > 0 {
            canvas = SIMD2(width, height)
            isOrthographic = true
        } else {
            canvas = SIMD2(1920, 1080)
            isOrthographic = false
        }
        parallaxEnabled = values.bool(general["cameraparallax"], default: false)
        parallaxAmount = values.float(general["cameraparallaxamount"], default: 0.5)
        parallaxDelay = values.float(general["cameraparallaxdelay"], default: 0.1)
        parallaxMouseInfluence = values.float(general["cameraparallaxmouseinfluence"], default: 0.5)
        ambientColor = values.vec3(general["ambientcolor"], default: SIMD3(repeating: 0.3))
        skylightColor = values.vec3(general["skylightcolor"], default: SIMD3(repeating: 0.3))

        var objects: [Object] = []
        for case let raw as [String: Any] in json["objects"] as? [Any] ?? [] {
            objects.append(Self.object(raw, values: values))
        }
        self.objects = objects
    }

    private static func object(_ raw: [String: Any], values: SceneValues) -> Object {
        let kind: Object.Kind
        if raw["image"] is String { kind = .image }
        else if raw["particle"] is String { kind = .particle }
        else if raw["text"] != nil { kind = .text }
        else if raw["sound"] != nil { kind = .sound }
        else if raw["model"] is String { kind = .model }
        else if raw["light"] != nil { kind = .light }
        else { kind = .group }

        var effects: [Effect] = []
        for case let effect as [String: Any] in raw["effects"] as? [Any] ?? [] {
            guard let file = effect["file"] as? String else { continue }
            var passes: [PassOverride] = []
            for case let pass as [String: Any] in effect["passes"] as? [Any] ?? [] {
                var override = PassOverride()
                override.constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
                override.textures = (pass["textures"] as? [Any] ?? []).map { $0 as? String }
                for (name, value) in pass["combos"] as? [String: Any] ?? [:] {
                    override.combos[name] = values.int(value, default: 0)
                }
                passes.append(override)
            }
            effects.append(Effect(file: file, visible: values.bool(effect["visible"], default: true), passes: passes))
        }

        let size = values.vector(raw["size"]).flatMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
        var animations: [String: SceneAnimation] = [:]
        for key in ["alpha", "color", "brightness", "origin", "scale", "angles", "visible"] {
            if let animation = SceneAnimation(raw[key]) { animations[key] = animation }
        }
        var object = Object(
            id: values.int(raw["id"], default: 0),
            name: raw["name"] as? String ?? "",
            kind: kind,
            raw: raw,
            origin: values.vec3(raw["origin"], default: .zero),
            scale: values.vec3(raw["scale"], default: SIMD3(1, 1, 1)),
            angles: values.vec3(raw["angles"], default: .zero),
            size: size,
            visible: values.bool(raw["visible"], default: true),
            alpha: values.float(raw["alpha"], default: 1),
            color: values.vec3(raw["color"], default: SIMD3(1, 1, 1)),
            brightness: values.float(raw["brightness"], default: 1),
            colorBlendMode: values.int(raw["colorBlendMode"], default: 0),
            parallaxDepth: values.vec2(raw["parallaxDepth"], default: SIMD2(1, 1)),
            parent: (raw["parent"] as? NSNumber)?.intValue,
            effects: effects,
            image: raw["image"] as? String,
            particle: raw["particle"] as? String
        )
        object.animations = animations
        return object
    }
}
