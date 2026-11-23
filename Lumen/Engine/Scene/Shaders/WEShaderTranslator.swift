import Foundation

/// A uniform as the translated program reads it: packed into consecutive float4 slots.
struct WEUniform {
    enum Kind: String {
        case float, vec2, vec3, vec4, int, ivec2, ivec3, ivec4, uint, uvec2, uvec3, uvec4, bool
        case mat2, mat3, mat4, mat4x3, mat3x4

        /// float4 slots one element takes.
        var slots: Int {
            switch self {
            case .mat2: 2
            case .mat3, .mat3x4: 3
            case .mat4, .mat4x3: 4
            default: 1
            }
        }

        /// Scalar components a value of this kind has (for material constants).
        var components: Int {
            switch self {
            case .float, .int, .uint, .bool: 1
            case .vec2, .ivec2, .uvec2: 2
            case .vec3, .ivec3, .uvec3: 3
            case .vec4, .ivec4, .uvec4: 4
            case .mat2: 4
            case .mat3: 9
            case .mat3x4, .mat4x3: 12
            case .mat4: 16
            }
        }
    }

    let name: String
    let kind: Kind
    let count: Int
    /// Preserves array syntax even when a symbolic size (e.g. `BLENDROWCOUNT`) defaults to 1.
    let isArray: Bool
    let annotation: [String: Any]?
    var slot = 0

    init(name: String, kind: Kind, count: Int, isArray: Bool = false, annotation: [String: Any]? = nil, slot: Int = 0) {
        self.name = name
        self.kind = kind
        self.count = count
        self.isArray = isArray || count > 1
        self.annotation = annotation
        self.slot = slot
    }

    var materialKey: String? { annotation?["material"] as? String }
    var defaultValue: Any? { annotation?["default"] }
}

/// A texture a program samples, and what Wallpaper Engine binds there by default.
struct WESampler {
    let name: String
    /// Metal texture/sampler index.
    let index: Int
    let annotation: [String: Any]?
    let stage: Stage

    enum Stage { case vertex, fragment }

    var defaultTexture: String? { annotation?["default"] as? String }
    var combo: String? { annotation?["combo"] as? String }
}

struct WEVarying: Hashable {
    let name: String
    let type: String
    var count = 1

    /// Interpolants can't be arrays, so array varyings travel as one field per element.
    var elementNames: [String] { count > 1 ? (0..<count).map { "\(name)_\($0)" } : [name] }
    func element(_ index: Int) -> String { count > 1 ? "\(name)[\(index)]" : name }
}

/// A Wallpaper Engine shader pair, translated to one Metal library.
struct WEShaderProgram {
    let source: String
    let uniforms: [WEUniform]
    let samplers: [WESampler]
    let slotCount: Int
    /// Combos the program was built with (after texture and default combos).
    let combos: [String: Int]
    /// Vertex attributes the vertex program reads, by name.
    let attributes: [String]

    static let vertexFunction = "we_vertex"
    static let fragmentFunction = "we_fragment"

    func uniform(named name: String) -> WEUniform? { uniforms.first { $0.name == name } }
}

enum WEShaderError: LocalizedError {
    case missingShader(String)

    var errorDescription: String? {
        switch self {
        case .missingShader(let name): String(localized: "The shader “\(name)” is missing.")
        }
    }
}

/// Translates Wallpaper Engine's GLSL dialect to Metal.
///
/// Rather than parsing GLSL, the whole shader is placed inside a C++ struct: global functions
/// become member functions, uniforms/varyings/attributes become fields, and `main()` becomes a
/// method the Metal entry point calls after filling the fields. Metal's C++ front end is
/// lenient in the same ways Wallpaper Engine's HLSL-flavoured GLSL relies on (implicit int to
/// float, scalar-vector arithmetic, narrowing constructors), so the shader text survives
/// almost untouched. Conditionals are resolved here so every declaration is known exactly.
enum WEShaderTranslator {
    /// Reads combo annotations: `// [COMBO] {"combo":"MODE","default":1}`.
    static func comboDefaults(in source: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for line in source.components(separatedBy: "\n") where line.contains("[COMBO]") {
            guard let start = line.firstIndex(of: "{"),
                  let json = LenientJSON.object(from: Data(line[start...].utf8)),
                  let name = json["combo"] as? String
            else { continue }
            result[name] = (json["default"] as? NSNumber)?.intValue ?? 0
        }
        return result
    }

    /// Sampler annotations that switch a combo on when a texture is bound (`"combo":"MASK"`),
    /// keyed by texture index.
    static func textureCombos(in source: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for match in source.matches(of: /uniform\s+sampler2D\w*\s+g_Texture(\d+)\s*;\s*\/\/\s*(\{.*\})/) {
            guard let index = Int(match.1),
                  let json = LenientJSON.object(from: Data(match.2.utf8)),
                  let combo = json["combo"] as? String
            else { continue }
            result[index] = combo
        }
        return result
    }

    /// Texture defaults (`"default":"util/black"`) by index, read before combos are known.
    static func textureDefaults(in source: String) -> [Int: String] {
        var result: [Int: String] = [:]
        for match in source.matches(of: /uniform\s+sampler2D\w*\s+g_Texture(\d+)\s*;\s*\/\/\s*(\{.*\})/) {
            guard let index = Int(match.1),
                  let json = LenientJSON.object(from: Data(match.2.utf8)),
                  let texture = json["default"] as? String
            else { continue }
            result[index] = texture
        }
        return result
    }

    static func translate(
        vertex: String,
        fragment: String,
        combos: [String: Int],
        engineDefines: [String: String] = [:],
        resolveInclude: @escaping (String) -> String?
    ) -> WEShaderProgram {
        var defines: [String: String] = ["HLSL": "1"]
        defines.merge(engineDefines) { _, new in new }
        for (name, value) in combos { defines[name] = String(value) }

        var vertexPre = WEShaderPreprocessor(defines: defines, resolveInclude: resolveInclude)
        let vertexText = vertexPre.process(vertex)
        var fragmentPre = WEShaderPreprocessor(defines: defines, resolveInclude: resolveInclude)
        let fragmentText = fragmentPre.process(fragment)

        var vertexUnit = Unit(text: vertexText, stage: .vertex, defines: vertexPre.defines)
        var fragmentUnit = Unit(text: fragmentText, stage: .fragment, defines: fragmentPre.defines)
        vertexUnit.extract()
        fragmentUnit.extract()

        // One uniform buffer layout shared by both stages.
        var uniforms: [WEUniform] = []
        var slot = 0
        for uniform in vertexUnit.uniforms + fragmentUnit.uniforms where !uniforms.contains(where: { $0.name == uniform.name }) {
            var placed = uniform
            placed.slot = slot
            slot += uniform.kind.slots * uniform.count
            uniforms.append(placed)
        }

        var samplers: [WESampler] = []
        var nextCustomIndex = 16
        func index(for name: String) -> Int {
            if let match = name.wholeMatch(of: /g_Texture(\d+)/), let number = Int(match.1), number < 16 { return number }
            if let existing = samplers.first(where: { $0.name == name }) { return existing.index }
            defer { nextCustomIndex += 1 }
            return nextCustomIndex
        }
        for (name, annotation, _) in vertexUnit.samplers {
            samplers.append(WESampler(name: name, index: index(for: name), annotation: annotation, stage: .vertex))
        }
        for (name, annotation, _) in fragmentUnit.samplers {
            samplers.append(WESampler(name: name, index: index(for: name), annotation: annotation, stage: .fragment))
        }

        // Varyings: what the vertex program writes; the fragment program reads a subset.
        var varyings = vertexUnit.varyings
        for varying in fragmentUnit.varyings where !varyings.contains(where: { $0.name == varying.name }) {
            varyings.append(varying)
        }

        var msl = prelude
        msl += conversions(usedIn: vertexUnit.body + fragmentUnit.body)
        msl += "struct WEVaryings {\n  float4 we_Position [[position]];\n"
        for varying in varyings {
            let flat = varying.type.hasPrefix("i") || varying.type.hasPrefix("u") ? " [[flat]]" : ""
            for element in varying.elementNames {
                msl += "  \(mslType(varying.type)) \(element)\(flat);\n"
            }
        }
        msl += "};\n\n"

        // Combos are also identifiers in code (`ApplyBlending(BLENDMODE, …)`).
        let comboMacros = defines.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)\n" }.joined()
        let comboUndefs = defines.keys.sorted().map { "#undef \($0)\n" }.joined()
        msl += comboMacros
        msl += "struct WEVertexProgram {\n"
        msl += "  float4 gl_Position;\n"
        msl += vertexUnit.fieldDeclarations()
        msl += vertexUnit.body + "\n};\n\n"
        for macro in Set(vertexPre.emittedMacros) { msl += "#undef \(macro)\n" }
        msl += comboUndefs + preludeMacros + "\n" + comboMacros

        msl += "struct WEFragmentProgram {\n"
        msl += "  float4 gl_FragColor;\n  float4 gl_FragCoord;\n"
        msl += fragmentUnit.fieldDeclarations()
        msl += fragmentUnit.body + "\n};\n\n"
        for macro in Set(fragmentPre.emittedMacros) { msl += "#undef \(macro)\n" }
        msl += comboUndefs + preludeMacros + "\n"

        msl += vertexEntry(unit: vertexUnit, uniforms: uniforms, samplers: samplers.filter { $0.stage == .vertex }, varyings: varyings)
        msl += fragmentEntry(unit: fragmentUnit, uniforms: uniforms, samplers: samplers.filter { $0.stage == .fragment }, varyings: varyings)

        var finalCombos = combos
        for (name, value) in fragmentPre.defines where combos[name] == nil {
            if let number = Int(value) { finalCombos[name] = number }
        }
        return WEShaderProgram(
            source: msl,
            uniforms: uniforms,
            samplers: samplers,
            slotCount: max(slot, 1),
            combos: combos,
            attributes: vertexUnit.attributes.map(\.name)
        )
    }

    // MARK: Entry points

    private static func vertexEntry(unit: Unit, uniforms: [WEUniform], samplers: [WESampler], varyings: [WEVarying]) -> String {
        var code = "vertex WEVaryings we_vertex(uint vid [[vertex_id]], constant float4* U [[buffer(0)]], const device WEVertex* V [[buffer(1)]]"
        for sampler in samplers {
            code += ", texture2d<float> t\(sampler.index) [[texture(\(sampler.index))]], sampler s\(sampler.index) [[sampler(\(sampler.index))]]"
        }
        code += ") {\n  WEVertexProgram p;\n  const device WEVertex& v = V[vid];\n"
        for attribute in unit.attributes {
            code += "  p.\(attribute.name) = \(attributeSource(attribute));\n"
        }
        code += uniformAssignments(unit: unit, uniforms: uniforms)
        for sampler in samplers {
            code += "  p.\(sampler.name).t = t\(sampler.index); p.\(sampler.name).s = s\(sampler.index);\n"
        }
        code += "  p.gl_Position = float4(0, 0, 0, 1);\n  p.main();\n  WEVaryings o;\n"
        code += "  o.we_Position = p.gl_Position;\n  o.we_Position.z = (o.we_Position.z + o.we_Position.w) * 0.5;\n"
        for varying in varyings {
            let written = unit.varyings.first { $0.name == varying.name }
            for (index, element) in varying.elementNames.enumerated() {
                if let written, index < written.count {
                    code += "  o.\(element) = \(convert("p.\(written.element(index))", from: written.type, to: varying.type));\n"
                } else {
                    code += "  o.\(element) = \(mslType(varying.type))(0);\n"
                }
            }
        }
        code += "  return o;\n}\n\n"
        return code
    }

    private static func fragmentEntry(unit: Unit, uniforms: [WEUniform], samplers: [WESampler], varyings: [WEVarying]) -> String {
        var code = "fragment float4 we_fragment(WEVaryings in [[stage_in]], constant float4* U [[buffer(0)]]"
        for sampler in samplers {
            code += ", texture2d<float> t\(sampler.index) [[texture(\(sampler.index))]], sampler s\(sampler.index) [[sampler(\(sampler.index))]]"
        }
        code += ") {\n  WEFragmentProgram p;\n  p.gl_FragCoord = in.we_Position;\n  p.gl_FragColor = float4(0);\n"
        for varying in unit.varyings {
            let declared = varyings.first { $0.name == varying.name } ?? varying
            for index in 0..<varying.count where index < declared.count {
                code += "  p.\(varying.element(index)) = \(convert("in.\(declared.elementNames[index])", from: declared.type, to: varying.type));\n"
            }
        }
        code += uniformAssignments(unit: unit, uniforms: uniforms)
        for sampler in samplers {
            code += "  p.\(sampler.name).t = t\(sampler.index); p.\(sampler.name).s = s\(sampler.index);\n"
        }
        code += "  p.main();\n  return p.gl_FragColor;\n}\n"
        return code
    }

    /// Adapts a varying whose stages disagree on its width (`vec4` written, `vec2` read).
    private static func convert(_ expression: String, from: String, to: String) -> String {
        let source = components(of: from), target = components(of: to)
        if source == target { return expression }
        if target < source { return expression + "." + String("xyzw".prefix(target)) }
        let padding = Array(repeating: "0", count: target - source).joined(separator: ", ")
        return "\(mslType(to))(\(expression), \(padding))"
    }

    private static func uniformAssignments(unit: Unit, uniforms: [WEUniform]) -> String {
        var code = ""
        for declared in unit.uniforms {
            guard let uniform = uniforms.first(where: { $0.name == declared.name }) else { continue }
            if !uniform.isArray && uniform.count == 1 {
                code += "  p.\(uniform.name) = \(unpack(uniform.kind, slot: "\(uniform.slot)"));\n"
            } else {
                let stride = uniform.kind.slots
                code += "  for (int i = 0; i < \(uniform.count); i++) p.\(uniform.name)[i] = \(unpack(uniform.kind, slot: "\(uniform.slot) + i * \(stride)"));\n"
            }
        }
        return code
    }

    private static func unpack(_ kind: WEUniform.Kind, slot s: String) -> String {
        switch kind {
        case .float: "U[\(s)].x"
        case .vec2: "U[\(s)].xy"
        case .vec3: "U[\(s)].xyz"
        case .vec4: "U[\(s)]"
        case .int: "int(U[\(s)].x)"
        case .ivec2: "int2(U[\(s)].xy)"
        case .ivec3: "int3(U[\(s)].xyz)"
        case .ivec4: "int4(U[\(s)])"
        case .uint: "uint(U[\(s)].x)"
        case .uvec2: "uint2(U[\(s)].xy)"
        case .uvec3: "uint3(U[\(s)].xyz)"
        case .uvec4: "uint4(U[\(s)])"
        case .bool: "(U[\(s)].x != 0)"
        case .mat2: "float2x2(U[\(s)].xy, U[\(s) + 1].xy)"
        case .mat3: "float3x3(U[\(s)].xyz, U[\(s) + 1].xyz, U[\(s) + 2].xyz)"
        case .mat4: "float4x4(U[\(s)], U[\(s) + 1], U[\(s) + 2], U[\(s) + 3])"
        case .mat4x3: "float4x3(U[\(s)].xyz, U[\(s) + 1].xyz, U[\(s) + 2].xyz, U[\(s) + 3].xyz)"
        case .mat3x4: "float3x4(U[\(s)], U[\(s) + 1], U[\(s) + 2])"
        }
    }

    /// Where each vertex attribute comes from in the shared vertex layout.
    private static func attributeSource(_ attribute: WEVarying) -> String {
        let width = components(of: attribute.type)
        let field: String
        switch attribute.name {
        case "a_Position", "a_PositionVec4": field = "v.position"
        case "a_TexCoord", "a_TexCoordVec4": field = "v.texcoord"
        case "a_TexCoordC1", "a_TexCoordVec4C1": field = "v.texcoord1"
        case "a_TexCoordC2": field = "v.texcoord2"
        case "a_Color": field = "v.color"
        case "a_Normal": field = "v.normal"
        case "a_Tangent4", "a_Tangent": field = "v.tangent"
        case "a_BlendIndices": return attribute.type.hasPrefix("u") ? "v.indices" : "int4(v.indices)"
        case "a_BlendWeights": field = "v.weights"
        case "a_PositionC1": field = "v.texcoord2"
        default: field = "v.texcoord2"
        }
        switch width {
        case 1: return "\(field).x"
        case 2: return "\(field).xy"
        case 3: return "\(field).xyz"
        default: return field
        }
    }

    private static func components(of type: String) -> Int {
        if let last = type.last, let number = Int(String(last)), type.contains("vec") { return number }
        return 1
    }

    static func mslType(_ glsl: String) -> String {
        switch glsl {
        case "vec2": "float2"
        case "vec3": "float3"
        case "vec4": "float4"
        case "ivec2": "int2"
        case "ivec3": "int3"
        case "ivec4": "int4"
        case "uvec2": "uint2"
        case "uvec3": "uint3"
        case "uvec4": "uint4"
        case "bvec2": "bool2"
        case "bvec3": "bool3"
        case "bvec4": "bool4"
        case "mat2": "float2x2"
        case "mat3": "float3x3"
        case "mat4": "float4x4"
        case "mat4x3": "float4x3"
        case "mat3x4": "float3x4"
        default: glsl
        }
    }

    // MARK: One stage

    fileprivate struct Unit {
        enum Stage { case vertex, fragment }
        let text: String
        let stage: Stage
        let defines: [String: String]
        var uniforms: [WEUniform] = []
        var samplers: [(String, [String: Any]?, String)] = []
        var varyings: [WEVarying] = []
        var attributes: [WEVarying] = []
        var body = ""

        init(text: String, stage: Stage, defines: [String: String]) {
            self.text = text
            self.stage = stage
            self.defines = defines
        }

        func fieldDeclarations() -> String {
            var code = ""
            for uniform in uniforms {
                let suffix = uniform.isArray ? "[\(uniform.count)]" : ""
                code += "  \(WEShaderTranslator.mslType(uniform.kind.rawValue)) \(uniform.name)\(suffix);\n"
            }
            for (name, _, type) in samplers { code += "  \(type == "sampler2DComparison" ? type : "sampler2D") \(name);\n" }
            for varying in varyings {
                let suffix = varying.count > 1 ? "[\(varying.count)]" : ""
                code += "  \(WEShaderTranslator.mslType(varying.type)) \(varying.name)\(suffix);\n"
            }
            for attribute in attributes { code += "  \(WEShaderTranslator.mslType(attribute.type)) \(attribute.name);\n" }
            return code
        }

        /// Pulls global declarations out of the text and rewrites what Metal can't take as-is.
        mutating func extract() {
            var kept: [String] = []
            var depth = 0
            var parenDepth = 0
            for rawLine in text.components(separatedBy: "\n") {
                let line = rawLine
                let code = WEShaderPreprocessor.stripLineComment(line)
                let trimmed = code.trimmingCharacters(in: .whitespaces)
                if depth == 0, parenDepth == 0, !trimmed.hasPrefix("#"), let declaration = declaration(in: trimmed, comment: line) {
                    if declaration { continue }
                }
                if depth == 0, parenDepth == 0, isPrototype(trimmed) || trimmed.hasPrefix("precision ") { continue }
                var output = trimmed.hasPrefix("#") ? line : code
                if depth == 0, parenDepth == 0, trimmed.hasPrefix("const ") {
                    output = code.replacingOccurrences(of: "const ", with: "", options: [], range: code.range(of: "const "))
                }
                for char in code {
                    if char == "{" { depth += 1 } else if char == "}" { depth = max(0, depth - 1) }
                    else if char == "(" { parenDepth += 1 } else if char == ")" { parenDepth = max(0, parenDepth - 1) }
                }
                kept.append(output)
            }
            body = rewrite(kept.joined(separator: "\n"))
        }

        /// Returns true if the line was a uniform/varying/attribute declaration (consumed).
        private mutating func declaration(in code: String, comment line: String) -> Bool? {
            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let qualifier = words.first, ["uniform", "varying", "attribute", "in", "out"].contains(qualifier) else { return nil }
            guard code.hasSuffix(";") else { return nil }
            // Drop precision and interpolation qualifiers.
            let ignored: Set<String> = ["highp", "mediump", "lowp", "flat", "smooth", "noperspective", "centroid", "const"]
            let rest = words.dropFirst().filter { !ignored.contains($0) }
            guard rest.count >= 2 else { return nil }
            let type = rest[rest.startIndex]
            var name = rest.dropFirst().joined(separator: " ").replacingOccurrences(of: ";", with: "").trimmingCharacters(in: .whitespaces)
            var count = 1
            var isArray = false
            if let open = name.firstIndex(of: "["), let close = name.firstIndex(of: "]") {
                isArray = true
                let size = String(name[name.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                count = Int(size) ?? Int(defines[size] ?? "") ?? evaluateSize(size)
                name = String(name[name.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            }
            var inlineDefault: String?
            if let equals = name.firstIndex(of: "=") {
                inlineDefault = String(name[name.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                name = String(name[name.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            }
            if name.contains(",") || name.isEmpty { return nil }
            var annotation: [String: Any]? = {
                guard let range = line.range(of: "//") else { return nil }
                let comment = line[range.upperBound...]
                guard let start = comment.firstIndex(of: "{") else { return nil }
                return LenientJSON.object(from: Data(comment[start...].utf8))
            }()
            if let inlineDefault, annotation?["default"] == nil {
                var merged = annotation ?? [:]
                let numbers = inlineDefault.matches(of: /-?\d+\.?\d*(?:[eE]-?\d+)?/).map { String($0.output) }
                merged["default"] = numbers.count == 1 ? (Double(numbers[0]) as Any) : numbers.joined(separator: " ")
                annotation = merged
            }

            switch qualifier {
            case "uniform":
                if type.hasPrefix("sampler") {
                    if !samplers.contains(where: { $0.0 == name }) { samplers.append((name, annotation, type)) }
                } else if let kind = WEUniform.Kind(rawValue: type) {
                    if !uniforms.contains(where: { $0.name == name }) {
                        uniforms.append(WEUniform(name: name, kind: kind, count: max(count, 1), isArray: isArray, annotation: annotation))
                    }
                } else {
                    return nil
                }
            case "varying":
                if !varyings.contains(where: { $0.name == name }) { varyings.append(WEVarying(name: name, type: type, count: count)) }
            case "attribute":
                if stage == .vertex, !attributes.contains(where: { $0.name == name }) { attributes.append(WEVarying(name: name, type: type)) }
            case "in":
                if stage == .vertex {
                    if !attributes.contains(where: { $0.name == name }) { attributes.append(WEVarying(name: name, type: type)) }
                } else if !varyings.contains(where: { $0.name == name }) {
                    varyings.append(WEVarying(name: name, type: type))
                }
            case "out":
                if stage == .vertex, !varyings.contains(where: { $0.name == name }) { varyings.append(WEVarying(name: name, type: type)) }
            default:
                return nil
            }
            return true
        }

        private func evaluateSize(_ expression: String) -> Int {
            let pre = WEShaderPreprocessor(defines: defines) { _ in nil }
            return max(1, pre.evaluate(expression))
        }

        /// `float foo(vec2 a);` at file scope: a C++ class can't redeclare members.
        private func isPrototype(_ code: String) -> Bool {
            guard code.hasSuffix(");") || code.hasSuffix(") ;"), !code.contains("="), !code.hasPrefix("return") else { return false }
            return code.wholeMatch(of: /[A-Za-z_][\w]*\s+[A-Za-z_]\w*\s*\(.*\)\s*;/) != nil
        }

        /// Source-level fixes that macros can't express.
        func rewrite(_ source: String) -> String {
            var text = source
            // C++ / Metal reserved words used as GLSL identifiers.
            // Simple word boundaries: Unicode ones treat `fragment.x` as a single word.
            text = text.replacing(Self.reservedWords.wordBoundaryKind(.simple)) { match in "we_" + match.output.1 }
            // GLSL parameter qualifiers.
            text = text.replacing(/\b(?:inout|out)\s+((?:highp\s+|mediump\s+|lowp\s+)?[A-Za-z_]\w*)\s+([A-Za-z_]\w*)/) { match in
                "thread \(match.output.1)& \(match.output.2)"
            }
            text = text.replacing(/([(,]\s*)(?:const\s+)?in\s+([A-Za-z_]\w*\s+[A-Za-z_]\w*)/) { match in
                "\(match.output.1)\(match.output.2)"
            }
            // Array constructors: float[3](a, b, c) -> {a, b, c}
            text = Self.replaceArrayConstructors(text)
            // GLSL copies arrays by assignment (`float a[16] = g_AudioSpectrum16Left;`); C++ can't.
            text = Self.copyArrayInitialisers(text)
            // HLSL lets a wider vector initialise, assign or return into a narrower one; Metal wants it explicit.
            let types = knownTypes(in: text)
            text = Self.narrowVec4TexCoordVaryings(text, stage: stage, varyings: varyings)
            text = Self.widenVectorInitialisers(text, types: types)
            text = Self.wrapAssignments(text, types: types)
            text = Self.matchLiteralTypes(text)
            text = Self.wrapReturns(text)
            // HLSL accepts float `%`, float array subscripts, and packed 2D `[i/4][i%4]` on 1D scalar uniform arrays.
            text = Self.rewriteModulo(text)
            text = Self.flattenPackedScalarArrays(text, uniforms: uniforms)
            text = Self.integerSubscripts(text)
            text = Self.templateVectorParameters(text)
            return text
        }

        /// Declared vector type of every name whose type is unambiguous.
        private func knownTypes(in text: String) -> [String: String] {
            var types: [String: String] = [:]
            var conflicting = Set<String>()
            func note(_ name: String, _ type: String) {
                if let existing = types[name], existing != type { conflicting.insert(name) } else { types[name] = type }
            }
            for uniform in uniforms { note(uniform.name, uniform.kind.rawValue) }
            for varying in varyings where varying.count == 1 { note(varying.name, varying.type) }
            for attribute in attributes { note(attribute.name, attribute.type) }
            note("gl_FragColor", "vec4")
            note("gl_Position", "vec4")
            for match in text.matches(of: /\b(vec[234]|ivec[234]|uvec[234]|float|int|uint|mat[234])\s+([A-Za-z_]\w*)\s*[=;,)]/) {
                note(String(match.output.2), String(match.output.1))
            }
            for name in conflicting { types[name] = nil }
            return types
        }

        /// Fragment shaders sometimes declare `varying vec4 v_TexCoord;` from a template and then
        /// use `v_TexCoord` unswizzled in `vec2` arithmetic (valid in HLSL via implicit truncation).
        /// When `.z`/`.w` are never read, rewriting unswizzled occurrences to `.xy` preserves exact semantics.
        static func narrowVec4TexCoordVaryings(_ text: String, stage: Stage, varyings: [WEVarying]) -> String {
            guard stage == .fragment else { return text }
            var result = text
            for varying in varyings where (varying.type == "vec4" || varying.type == "vec3") && varying.count == 1 && varying.name.lowercased().contains("texcoord") {
                let name = varying.name
                guard let zwRegex = try? Regex("\\b\(name)\\.[xyzwrgba]*[zwba]"),
                      result.firstMatch(of: zwRegex) == nil,
                      let bareRegex = try? Regex("\\b\(name)\\b(?!\\.)")
                else { continue }
                result = result.replacing(bareRegex) { _ in "\(name).xy" }
            }
            return result
        }

        static func copyArrayInitialisers(_ text: String) -> String {
            text.replacing(/(?m)(^|[;{}]\s*|\n\s*)((?:vec|ivec|uvec)[234]|float|int|uint)\s+([A-Za-z_]\w*)\s*\[([^\]]+)\]\s*=\s*([A-Za-z_]\w*)\s*;/) { match in
                let (lead, type, name, size, source) = (match.output.1, match.output.2, match.output.3, match.output.4, match.output.5)
                return "\(lead)\(type) \(name)[\(size)]; for (int we_i = 0; we_i < int(\(size)); we_i++) \(name)[we_i] = \(source)[we_i];"
            }
        }

        static func widenVectorInitialisers(_ text: String, types: [String: String] = [:]) -> String {
            text.replacing(/(?m)(^|[;{}(]\s*|\n\s*)((?:vec|ivec|uvec)[234]|float)\s+([A-Za-z_]\w*)\s*=\s*([^;{}=]+?);/) { match in
                var value = match.output.4.trimmingCharacters(in: .whitespacesAndNewlines)
                // `vec3 color = vec3(0.0), other;` declares a second variable after the comma.
                var rest = ""
                if let comma = topLevelComma(in: value) {
                    rest = String(value[comma...])
                    value = String(value[..<comma]).trimmingCharacters(in: .whitespaces)
                }
                let type = String(match.output.2)
                value = truncateWideOperands(value, toWidth: width(of: type), types: types)
                return "\(match.output.1)\(type) \(match.output.3) = we_\(type)(\(value))\(rest);"
            }
        }

        private static func width(of type: String) -> Int {
            type.last.flatMap { Int(String($0)) } ?? 1
        }

        /// The first comma outside parentheses and brackets, if any.
        private static func topLevelComma(in text: String) -> String.Index? {
            var depth = 0
            for index in text.indices {
                switch text[index] {
                case "(", "[": depth += 1
                case ")", "]": depth -= 1
                case "," where depth == 0: return index
                default: break
                }
            }
            return nil
        }

        /// HLSL truncates a wider vector operand to the result's width (`vec2 a = v4 * v2;`).
        /// Swizzling bare top-level operands keeps component-wise maths identical; anything
        /// inside a call is left alone, since `dot`/`length` would change meaning.
        static func truncateWideOperands(_ value: String, toWidth target: Int, types: [String: String]) -> String {
            guard target >= 2, !types.isEmpty else { return value }
            let swizzle = String("xyzw".prefix(target))
            var result = ""
            var depth = 0
            var index = value.startIndex
            while index < value.endIndex {
                let character = value[index]
                if character == "(" || character == "[" { depth += 1 }
                if character == ")" || character == "]" { depth -= 1 }
                let startsName = (character.isLetter || character == "_")
                    && (index == value.startIndex || !(value[value.index(before: index)].isLetter || value[value.index(before: index)].isNumber
                        || value[value.index(before: index)] == "_" || value[value.index(before: index)] == "."))
                guard startsName else {
                    result.append(character)
                    index = value.index(after: index)
                    continue
                }
                var end = index
                while end < value.endIndex, value[end].isLetter || value[end].isNumber || value[end] == "_" { end = value.index(after: end) }
                let name = String(value[index..<end])
                result += name
                let next = value[end...].first { !$0.isWhitespace }
                if depth == 0, next != "(", next != ".", next != "[",
                   let declared = types[name], declared.contains("vec"), width(of: declared) > target {
                    result += "." + swizzle
                }
                index = end
            }
            return result
        }

        /// `clamp(0, 0.15, x)`: Metal won't pick an overload for mixed int and float literals,
        /// so integer literals become floats in calls that already pass a float literal.
        static func matchLiteralTypes(_ text: String) -> String {
            text.replacing(/\b(clamp|min|max|mix|step|smoothstep|pow)\(([^()]*)\)/.wordBoundaryKind(.simple)) { match in
                let arguments = String(match.output.2)
                guard arguments.contains(/\d\.\d|\d\./) else { return String(match.output.0) }
                let fixed = arguments.replacing(/(^|[,(\s])(-?\d+)(?=\s*(?:,|$))/) { "\($0.output.1)\($0.output.2).0" }
                return "\(match.output.1)(\(fixed))"
            }
        }

        static func wrapAssignments(_ text: String, types: [String: String]) -> String {
            text.replacing(/(?m)(^|[;{}]\s*|\n\s*|\)\s*)([A-Za-z_]\w*)(\.[xyzwrgba]{1,4})?\s*(\+=|-=|\*=|\/=|=)(?!=)\s*([^;{}=]+?);/) { match in
                let whole = String(match.output.0)
                guard let declared = types[String(match.output.2)], declared.contains("vec") else { return whole }
                let base = declared.hasPrefix("i") ? "ivec" : declared.hasPrefix("u") ? "uvec" : "vec"
                let width = match.output.3.map { $0.count - 1 } ?? Int(String(declared.last!)) ?? 4
                let value = truncateWideOperands(match.output.5.trimmingCharacters(in: .whitespacesAndNewlines), toWidth: width, types: types)
                let target = width == 1 ? (base == "vec" ? "float" : base == "ivec" ? "int" : "uint") : "\(base)\(width)"
                return "\(match.output.1)\(match.output.2)\(match.output.3 ?? "") \(match.output.4) we_\(target)(\(value));"
            }
        }

        /// `a % b` -> `we_mod(a, b)`, which keeps `%` for integers and uses `fmod` for floats.
        static func rewriteModulo(_ source: String) -> String {
            guard source.contains("%") else { return source }
            var chars = Array(source)
            var index = chars.count - 1
            while index > 0 {
                defer { index -= 1 }
                guard chars[index] == "%", index + 1 < chars.count, chars[index + 1] != "=" else { continue }
                guard let left = operandStart(chars, before: index), let right = operandEnd(chars, after: index) else { continue }
                let lhs = String(chars[left..<index]).trimmingCharacters(in: .whitespaces)
                let rhs = String(chars[(index + 1)...right]).trimmingCharacters(in: .whitespaces)
                guard !lhs.isEmpty, !rhs.isEmpty else { continue }
                let replacement = Array("we_mod(\(lhs), \(rhs))")
                chars.replaceSubrange(left...right, with: replacement)
                index = left
            }
            return String(chars)
        }

        private static func isOperandCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "." }

        private static func operandStart(_ chars: [Character], before index: Int) -> Int? {
            var i = index - 1
            while i >= 0, chars[i] == " " { i -= 1 }
            guard i >= 0 else { return nil }
            if chars[i] == ")" || chars[i] == "]" {
                var depth = 0
                while i >= 0 {
                    if chars[i] == ")" || chars[i] == "]" { depth += 1 }
                    if chars[i] == "(" || chars[i] == "[" { depth -= 1; if depth == 0 { break } }
                    i -= 1
                }
                guard i >= 0 else { return nil }
                i -= 1
            }
            while i >= 0, isOperandCharacter(chars[i]) { i -= 1 }
            return i + 1
        }

        private static func operandEnd(_ chars: [Character], after index: Int) -> Int? {
            var i = index + 1
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count else { return nil }
            if chars[i] == "-" { i += 1 }
            while i < chars.count, isOperandCharacter(chars[i]) { i += 1 }
            if i < chars.count, chars[i] == "(" || chars[i] == "[" {
                var depth = 0
                while i < chars.count {
                    if chars[i] == "(" || chars[i] == "[" { depth += 1 }
                    if chars[i] == ")" || chars[i] == "]" { depth -= 1; if depth == 0 { break } }
                    i += 1
                }
                guard i < chars.count else { return nil }
                i += 1
                while i < chars.count, isOperandCharacter(chars[i]) { i += 1 }
            }
            return i - 1
        }

        /// Some HLSL shaders index 1D float uniform arrays (e.g. `g_AudioSpectrum64Left`) as packed float4s (`[i/4][i%4]`).
        static func flattenPackedScalarArrays(_ text: String, uniforms: [WEUniform]) -> String {
            let names = Set(uniforms.filter { $0.count > 1 && $0.kind == .float }.map(\.name))
            guard !names.isEmpty else { return text }
            return text.replacing(/\b([A-Za-z_]\w*)\s*\[([^\[\]\n]+)\]\s*\[([^\[\]\n]+)\]/) { match in
                let name = String(match.output.1)
                guard names.contains(name) else { return String(match.output.0) }
                let a = match.output.2.trimmingCharacters(in: .whitespaces)
                let b = match.output.3.trimmingCharacters(in: .whitespaces)
                return "\(name)[int(\(a)) * 4 + int(\(b))]"
            }
        }

        /// Wraps `return expr;` in vector/scalar-returning functions so wider vectors truncate like HLSL.
        static func wrapReturns(_ text: String) -> String {
            let headers = text.matches(of: /(?m)^[ \t]*((?:vec[234]|ivec[234]|uvec[234]|float))\s+[A-Za-z_]\w*\s*\([^()]*\)\s*\{/)
            guard !headers.isEmpty else { return text }
            var result = text
            for header in headers.reversed() {
                let returnType = String(header.output.1)
                let openBrace = result.index(before: header.range.upperBound)
                guard let closeBrace = matchingBrace(in: result, from: openBrace) else { continue }
                let bodyRange = result.index(after: openBrace)..<closeBrace
                let body = String(result[bodyRange])
                let wrapped = body.replacing(/\breturn\s+([^;{}]+);/) { match in
                    let expr = match.output.1.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "return we_\(returnType)(\(expr));"
                }
                result.replaceSubrange(bodyRange, with: wrapped)
            }
            return result
        }

        private static func matchingBrace(in text: String, from open: String.Index) -> String.Index? {
            var depth = 0
            var index = open
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { return index }
                }
                index = text.index(after: index)
            }
            return nil
        }

        static func integerSubscripts(_ text: String) -> String {
            var result = text
            for _ in 0..<3 {
                let next = result.replacing(/(\w|\])\s*\[(?!\[)(?!int\()([^\[\]\n]+)\]/) { match in
                    let inner = match.output.2.trimmingCharacters(in: .whitespaces)
                    if inner.allSatisfy(\.isNumber) { return String(match.output.0) }
                    return "\(match.output.1)[int(\(inner))]"
                }
                if next == result { break }
                result = next
            }
            return result
        }

        /// Turns by-value vector parameters of non-overloaded functions into templates, so a call
        /// can pass a wider vector (HLSL truncates implicitly).
        static func templateVectorParameters(_ text: String) -> String {
            let headers = text.matches(of: /(?m)^([ \t]*)((?:vec[234]|float|int|uint|void|bool|mat[234]|ivec[234])\s+([A-Za-z_]\w*)\s*\(([^()]*)\))(\s*\{)/)
            var counts: [String: Int] = [:]
            for header in headers { counts[String(header.output.3), default: 0] += 1 }
            var result = text
            for header in headers.reversed() {
                let name = String(header.output.3)
                guard counts[name] == 1, name != "main" else { continue }
                var templateParams: [String] = []
                var prologue: [String] = []
                var params: [String] = []
                for raw in header.output.4.split(separator: ",") {
                    let param = raw.trimmingCharacters(in: .whitespaces)
                    let parts = param.split(separator: " ", omittingEmptySubsequences: true)
                    if parts.count == 2, parts[0].hasPrefix("vec"), !param.contains("&"), !param.contains("[") {
                        let index = templateParams.count
                        templateParams.append("typename WE_T\(index)")
                        params.append("WE_T\(index) we_arg_\(parts[1])")
                        prologue.append("\(parts[0]) \(parts[1]) = we_\(parts[0])(we_arg_\(parts[1]));")
                    } else {
                        params.append(param)
                    }
                }
                guard !templateParams.isEmpty else { continue }
                let signature = "\(header.output.1)template<\(templateParams.joined(separator: ", "))> "
                    + header.output.2.replacingOccurrences(of: "(\(header.output.4))", with: "(\(params.joined(separator: ", ")))")
                    + header.output.5 + " " + prologue.joined(separator: " ")
                result.replaceSubrange(header.range, with: signature)
            }
            return result
        }

        private static let reservedWords = /\b(kernel|half|vertex|fragment|sampler|constant|device|thread|threadgroup|using|namespace|class|template|this|new|delete|operator|friend|public|private|protected|virtual|typename|auto|register|signed|unsigned|union|enum|goto|extern|volatile|typedef|sizeof|char|short|long|double|explicit|mutable|catch|throw|try|export|and|or|not|xor|nullptr|alignas|alignof|decltype|noexcept|typeid|ref|texture|kernel_t|vec|matrix|vector|array|packed_float2|packed_float3)\b(?!\s*[<(])/

        private static func replaceArrayConstructors(_ text: String) -> String {
            var result = text
            while let match = result.firstMatch(of: /\b[A-Za-z_]\w*\s*\[\s*\d*\s*\]\s*\(/) {
                let open = result.index(before: match.range.upperBound)
                guard let close = matchingParen(in: result, from: open) else { break }
                let inner = result[result.index(after: open)..<close]
                result.replaceSubrange(match.range.lowerBound...close, with: "{" + inner + "}")
            }
            return result
        }

        private static func matchingParen(in text: String, from open: String.Index) -> String.Index? {
            var depth = 0
            var index = open
            while index < text.endIndex {
                if text[index] == "(" { depth += 1 }
                if text[index] == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
                index = text.index(after: index)
            }
            return nil
        }
    }

    // MARK: Prelude

    /// Only the conversion helpers a program calls, so the compiler parses less.
    static func conversions(usedIn body: String) -> String {
        var code = ""
        for (name, block) in conversionBlocks where body.contains(name + "(") { code += block }
        return code
    }

    /// `we_vec2(x)` etc.: HLSL-style conversions that truncate wider vectors and splat scalars.
    static let conversionBlocks: [(String, String)] = {
        var blocks: [(String, String)] = []
        var code = ""
        let families: [(prefix: String, scalar: String)] = [("float", "float"), ("int", "int"), ("uint", "uint")]
        let sources = ["float", "int", "uint", "bool", "half"] + ["float", "int", "uint", "half"].flatMap { base in (2...4).map { "\(base)\($0)" } }
        for family in families {
            for width in 1...4 {
                var code = ""
                let target = width == 1 ? family.scalar : "\(family.prefix)\(width)"
                let name = width == 1 ? "we_\(family.scalar)" : "we_\(family.prefix == "float" ? "vec" : family.prefix == "int" ? "ivec" : "uvec")\(width)"
                for source in sources {
                    let sourceWidth = Int(String(source.last!)) ?? 1
                    let expression: String
                    if sourceWidth == 1 {
                        expression = "\(target)(v)"
                    } else if sourceWidth >= width {
                        expression = width == 1 ? "\(target)(v.x)" : "\(target)(v.\(String("xyzw".prefix(width))))"
                    } else {
                        let parts = "xyzw".prefix(sourceWidth).map { "\(family.scalar)(v.\($0))" }
                            + Array(repeating: "0", count: width - sourceWidth)
                        expression = "\(target)(\(parts.joined(separator: ", ")))"
                    }
                    code += "inline \(target) \(name)(\(source) v) { return \(expression); }\n"
                }
                blocks.append((name, code))
            }
        }
        return blocks
    }()

    /// Macros that map GLSL and Wallpaper Engine names onto Metal; re-emitted after each
    /// program's own `#undef`s in case a shader redefined one.
    static let preludeMacros = """
    #define vec2 float2
    #define vec3 float3
    #define vec4 float4
    #define ivec2 int2
    #define ivec3 int3
    #define ivec4 int4
    #define uvec2 uint2
    #define uvec3 uint3
    #define uvec4 uint4
    #define bvec2 bool2
    #define bvec3 bool3
    #define bvec4 bool4
    #define mat2 float2x2
    #define mat3 float3x3
    #define mat4 float4x4
    #define mat4x3 float4x3
    #define mat3x4 float3x4
    #define highp
    #define mediump
    #define lowp
    #define precision
    #define attribute
    #define varying

    #define mul(x, y) ((y) * (x))
    #define frac fract
    #define lerp mix
    #define CAST2(x) (float2(x))
    #define CAST3(x) (float3(x))
    #define CAST4(x) (float4(x))
    #define CAST3X3(x) we_mat3(x)
    #define CASTU(x) (uint(x))
    #define CASTF(x) (float(x))
    #define CASTI(x) (int(x))
    #define CAST2X2(x) (float2x2(x))
    #define CAST4X4(x) (float4x4(x))
    #define clip(x) if (any((x) < 0.0)) discard_fragment()
    #define texLoad2D texelFetch
    #define texSample2DBackBuffer texture2D
    #define texSample2D texture2D
    #define texSample2DLod texture2DLod
    #define ddx dfdx
    #define ddy(x) dfdy(-(x))
    #define dFdx dfdx
    #define dFdy dfdy
    #define inversesqrt rsqrt
    #define discard discard_fragment()
    """

    static let prelude = """
    #include <metal_stdlib>
    using namespace metal;
    #pragma clang diagnostic ignored "-Wunused-variable"
    #pragma clang diagnostic ignored "-Wunused-function"
    #pragma clang diagnostic ignored "-Wmissing-braces"
    #pragma clang diagnostic ignored "-Wsign-compare"
    #pragma clang diagnostic ignored "-Wconditional-uninitialized"
    #pragma clang diagnostic ignored "-Wuninitialized"
    #pragma clang diagnostic ignored "-Wunused-parameter"

    struct WEVertex {
      float4 position; float4 texcoord; float4 texcoord1; float4 texcoord2;
      float4 color; float4 normal; float4 tangent; uint4 indices; float4 weights;
    };

    struct sampler2D { texture2d<float> t; sampler s; };
    struct sampler2DComparison { texture2d<float> t; sampler s; };

    """ + preludeMacros + """

    inline float4 texture2D(sampler2D s, float2 uv) { return s.t.sample(s.s, uv); }
    inline float4 texture2D(sampler2D s, float2 uv, float bias_) { return s.t.sample(s.s, uv, bias(bias_)); }
    inline float4 texture2DLod(sampler2D s, float2 uv, float lod) { return s.t.sample(s.s, uv, level(lod)); }
    inline float4 texture(sampler2D s, float2 uv) { return s.t.sample(s.s, uv); }
    inline float4 textureLod(sampler2D s, float2 uv, float lod) { return s.t.sample(s.s, uv, level(lod)); }
    inline float4 texture2D(sampler2DComparison s, float2 uv) { return s.t.sample(s.s, uv); }
    inline float texSample2DCompare(sampler2DComparison s, float2 uv, float ref) { return step(ref, s.t.sample(s.s, uv).r); }
    inline float4 texture2D(sampler2D s, float3 uv) { return s.t.sample(s.s, uv.xy); }
    inline float4 texture2D(sampler2D s, float4 uv) { return s.t.sample(s.s, uv.xy); }
    inline float4 texture2DLod(sampler2D s, float4 uv, float lod) { return s.t.sample(s.s, uv.xy, level(lod)); }
    inline float4 texture2DLod(sampler2D s, float3 uv, float lod) { return s.t.sample(s.s, uv.xy, level(lod)); }
    inline int2 textureSize(sampler2D s, int lod) { return int2(s.t.get_width(lod), s.t.get_height(lod)); }
    inline float4 texelFetch(sampler2D s, int2 p, int lod) { return s.t.read(uint2(p), uint(lod)); }

    inline float atan(float y, float x) { return metal::atan2(y, x); }
    inline float2 atan(float2 y, float2 x) { return metal::atan2(y, x); }
    inline float mod(float x, float y) { return x - y * floor(x / y); }
    inline float2 mod(float2 x, float y) { return x - y * floor(x / y); }
    inline float3 mod(float3 x, float y) { return x - y * floor(x / y); }
    inline float4 mod(float4 x, float y) { return x - y * floor(x / y); }
    inline float2 mod(float2 x, float2 y) { return x - y * floor(x / y); }
    inline float3 mod(float3 x, float3 y) { return x - y * floor(x / y); }
    inline float4 mod(float4 x, float4 y) { return x - y * floor(x / y); }
    inline float3x3 we_mat3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }
    inline float3x3 we_mat3(float4x3 m) { return float3x3(m[0], m[1], m[2]); }
    inline float3x3 we_mat3(float3x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }
    inline float3x3 we_mat3(float3x3 m) { return m; }
    inline float3x3 inverse(float3x3 m) {
      float3 a = m[0], b = m[1], c = m[2];
      float3 r0 = cross(b, c), r1 = cross(c, a), r2 = cross(a, b);
      float det = dot(r2, c);
      return transpose(float3x3(r0, r1, r2)) * (1.0 / det);
    }
    inline float2x2 inverse(float2x2 m) {
      float det = m[0][0] * m[1][1] - m[1][0] * m[0][1];
      return float2x2(float2(m[1][1], -m[0][1]), float2(-m[1][0], m[0][0])) * (1.0 / det);
    }
    template<typename T> inline auto lessThan(T a, T b) { return a < b; }
    template<typename T> inline auto lessThanEqual(T a, T b) { return a <= b; }
    template<typename T> inline auto greaterThan(T a, T b) { return a > b; }
    template<typename T> inline auto greaterThanEqual(T a, T b) { return a >= b; }
    template<typename T> inline auto equal(T a, T b) { return a == b; }
    template<typename T> inline auto notEqual(T a, T b) { return a != b; }
    // HLSL mixes int and float arguments freely; route mixed calls to the float overloads.
    template<typename A, typename B, typename = enable_if_t<is_integral_v<B> && !is_same_v<A, B>>> inline A max(A a, B b) { return max(a, A(b)); }
    template<typename A, typename B, typename = enable_if_t<is_integral_v<A> && !is_integral_v<B>>, typename = void> inline B max(A a, B b) { return max(B(a), b); }
    template<typename A, typename B, typename = enable_if_t<is_integral_v<B> && !is_same_v<A, B>>> inline A min(A a, B b) { return min(a, A(b)); }
    template<typename A, typename B, typename = enable_if_t<is_integral_v<A> && !is_integral_v<B>>, typename = void> inline B min(A a, B b) { return min(B(a), b); }
    template<typename T, typename L, typename H, typename = enable_if_t<(is_integral_v<L> || is_integral_v<H>) && !is_integral_v<T>>> inline T clamp(T x, L lo, H hi) { return clamp(x, T(lo), T(hi)); }
    template<typename A, typename B, typename = enable_if_t<is_integral_v<B> && !is_integral_v<A>>> inline A pow(A a, B b) { return pow(a, A(b)); }
    template<typename A, typename B, typename = enable_if_t<is_integral_v<A> && !is_integral_v<B>>> inline B step(A a, B b) { return step(B(a), b); }
    template<typename A, typename B, typename = enable_if_t<is_integral_v<B> && !is_integral_v<A>>, typename = void> inline A step(A a, B b) { return step(a, A(b)); }
    inline float2 mix(float2 a, float3 b, float t) { return mix(a, b.xy, t); }
    inline float2 mix(float2 a, float4 b, float t) { return mix(a, b.xy, t); }
    inline float3 mix(float3 a, float4 b, float t) { return mix(a, b.xyz, t); }
    inline float2 mix(float3 a, float2 b, float t) { return mix(a.xy, b, t); }
    inline float2 mix(float4 a, float2 b, float t) { return mix(a.xy, b, t); }
    inline float3 mix(float4 a, float3 b, float t) { return mix(a.xyz, b, t); }
    template<typename A, typename B> inline auto we_mod_(A a, B b, int) -> decltype(a % b) { return a % b; }
    template<typename A, typename B> inline auto we_mod_(A a, B b, uint) { using R = decltype(a + b); return fmod(R(a), R(b)); }
    template<typename A, typename B> inline auto we_mod(A a, B b) { return we_mod_(a, b, 0); }
    inline float radians_(float d) { return d * 0.01745329252; }

    """
}
