import Foundation
import Metal
import simd

enum SceneBlend: Hashable {
    case translucent, additive, opaque, multiply, max

    init(_ name: String?) {
        switch name?.lowercased() {
        case "translucent": self = .translucent
        case "additive": self = .additive
        case "multiply": self = .multiply
        default: self = .opaque
        }
    }

    func configure(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        switch self {
        case .opaque:
            attachment.isBlendingEnabled = false
        case .translucent:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
        case .multiply:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one
        case .max:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .max
            attachment.alphaBlendOperation = .max
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
    }
}

/// One pass of a Wallpaper Engine material JSON.
struct MaterialPass {
    var shader: String
    var blend: SceneBlend
    var textures: [String?]
    var constants: [String: Any]
    var combos: [String: Int]

    /// Reads `materials/….json`. `base` is the effect folder its paths may be relative to.
    static func load(_ path: String, near base: String?, files: SceneFileSystem, values: SceneValues) -> [MaterialPass]? {
        guard let json = files.json(path, near: base) else { return nil }
        return (json["passes"] as? [Any] ?? []).compactMap { raw -> MaterialPass? in
            guard let pass = raw as? [String: Any], let shader = pass["shader"] as? String else { return nil }
            var combos: [String: Int] = [:]
            for (name, value) in pass["combos"] as? [String: Any] ?? [:] { combos[name] = values.int(value, default: 0) }
            return MaterialPass(
                shader: shader,
                blend: SceneBlend(pass["blending"] as? String),
                textures: (pass["textures"] as? [Any] ?? []).map { $0 as? String },
                constants: pass["constantshadervalues"] as? [String: Any] ?? [:],
                combos: combos
            )
        }
    }
}

/// A translated shader with its Metal library; pipelines are made per blend mode on demand.
final class CompiledProgram: @unchecked Sendable {
    let info: WEShaderProgram
    private let vertex: MTLFunction
    private let fragment: MTLFunction
    private let device: MTLDevice
    private let lock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    init(info: WEShaderProgram, library: MTLLibrary, device: MTLDevice) throws {
        guard let vertex = library.makeFunction(name: WEShaderProgram.vertexFunction),
              let fragment = library.makeFunction(name: WEShaderProgram.fragmentFunction)
        else { throw SceneLoadError.unsupported("a shader without entry points") }
        self.info = info
        self.vertex = vertex
        self.fragment = fragment
        self.device = device
    }

    func pipeline(blend: SceneBlend, format: MTLPixelFormat = .rgba8Unorm) throws -> MTLRenderPipelineState {
        let key = "\(blend)-\(format.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = pipelines[key] { return existing }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        blend.configure(descriptor.colorAttachments[0])
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = state
        return state
    }
}

/// Translates and compiles Wallpaper Engine shaders, caching results for the whole app so a
/// scene that's applied again (or previewed) doesn't pay for compilation twice.
final class SceneShaderLibrary: @unchecked Sendable {
    let device: MTLDevice
    let files: SceneFileSystem

    private static let lock = NSLock()
    private static var compiled: [String: CompiledProgram] = [:]
    private static var order: [String] = []
    private static var failures: [String: Error] = [:]
    private static var pending: [String: DispatchGroup] = [:]

    init(device: MTLDevice, files: SceneFileSystem) {
        self.device = device
        self.files = files
    }

    struct Source {
        let vertex: String
        let fragment: String
        let base: String?
        /// Every line reachable through includes, for reading annotations before compiling.
        let flattened: String
    }

    /// Loads `shaders/<name>.vert/.frag`, preferring the effect's own folder.
    func source(for shader: String, near base: String?) throws -> Source {
        let path = "shaders/" + shader
        guard let vertex = files.text(path + ".vert", near: base), let fragment = files.text(path + ".frag", near: base) else {
            throw SceneLoadError.missingFile(path + ".frag")
        }
        var seen = Set<String>()
        let flattened = WEShaderPreprocessor.flatten(vertex + "\n" + fragment, resolveInclude: include(near: base), seen: &seen)
        return Source(vertex: vertex, fragment: fragment, base: base, flattened: flattened)
    }

    func include(near base: String?) -> (String) -> String? {
        let files = files
        return { name in files.text("shaders/" + name, near: base) }
    }

    nonisolated(unsafe) static var translateTime: Double = 0
    nonisolated(unsafe) static var compileTime: Double = 0
    nonisolated(unsafe) static var compileCount = 0

    func program(_ source: Source, combos: [String: Int]) throws -> CompiledProgram {
        let t0 = CFAbsoluteTimeGetCurrent()
        // Same shader text and combos give the same program: skip translating it again.
        let comboKey = combos.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let key = StableHash.hex(Data((source.flattened + "|" + comboKey).utf8))
        Self.lock.lock()
        if let cached = Self.compiled[key] {
            Self.lock.unlock()
            return cached
        }
        if let failure = Self.failures[key] {
            Self.lock.unlock()
            throw failure
        }
        // Another layer is compiling the same program right now: wait for it.
        if let pending = Self.pending[key] {
            Self.lock.unlock()
            pending.wait()
            return try program(source, combos: combos)
        }
        let group = DispatchGroup()
        group.enter()
        Self.pending[key] = group
        Self.lock.unlock()
        defer {
            Self.lock.lock()
            Self.pending[key] = nil
            Self.lock.unlock()
            group.leave()
        }
        let info = WEShaderTranslator.translate(
            vertex: source.vertex, fragment: source.fragment, combos: combos, resolveInclude: include(near: source.base)
        )
        Self.translateTime += CFAbsoluteTimeGetCurrent() - t0
        defer { Self.compileTime += CFAbsoluteTimeGetCurrent() - t0 }

        let options = MTLCompileOptions()
        options.mathMode = .fast
        // Pinned so translated shaders behave the same on every macOS the app supports
        // (`out` parameters become `thread T&`, which this version requires).
        options.languageVersion = .version3_2
        do {
            Self.compileCount += 1
            let library = try device.makeLibrary(source: info.source, options: options)
            let program = try CompiledProgram(info: info, library: library, device: device)
            Self.lock.lock()
            Self.compiled[key] = program
            Self.order.append(key)
            if Self.order.count > 160 { Self.compiled[Self.order.removeFirst()] = nil }
            Self.lock.unlock()
            return program
        } catch {
            Self.lock.lock()
            Self.failures[key] = error
            Self.lock.unlock()
            #if DEBUG
            let lines = "\(error)".components(separatedBy: "\n").filter { $0.contains("error:") }.prefix(3)
            Log.engine.error("Shader failed: \(lines.joined(separator: " | "), privacy: .public)")
            #endif
            throw error
        }
    }
}

// MARK: - Uniforms

/// Values the engine supplies to shaders by name.
enum EngineUniform {
    case time, daytime
    case modelMatrix, modelMatrixInverse, viewProjection, modelViewProjection, modelViewProjectionInverse
    case effectTextureProjection, effectTextureProjectionInverse, effectModelViewProjection
    case eyePosition, screen, texelSize, texelSizeHalf
    case textureResolution(Int), textureRotation(Int), textureTranslation(Int), textureMipInfo(Int)
    case pointer, pointerLast, parallax
    case color4, color, alpha, userAlpha, brightness
    case lightAmbient, lightSkylight
    case orientationUp, orientationRight, orientationForward, viewUp, viewRight
    case renderVar0, renderVar1
    case bones, bonesAlpha
    /// `g_AudioSpectrum16Left`…`g_AudioSpectrum64Right`.
    case audio(resolution: Int, right: Bool)
    case zero

    static func classify(_ name: String) -> EngineUniform? {
        switch name {
        case "g_Time": return .time
        case "g_Daytime": return .daytime
        case "g_ModelMatrix": return .modelMatrix
        case "g_ModelMatrixInverse": return .modelMatrixInverse
        case "g_ViewProjectionMatrix": return .viewProjection
        case "g_ModelViewProjectionMatrix": return .modelViewProjection
        case "g_ModelViewProjectionMatrixInverse": return .modelViewProjectionInverse
        case "g_EffectTextureProjectionMatrix": return .effectTextureProjection
        case "g_EffectTextureProjectionMatrixInverse": return .effectTextureProjectionInverse
        case "g_EffectModelViewProjectionMatrix": return .effectModelViewProjection
        case "g_EyePosition": return .eyePosition
        case "g_Screen": return .screen
        case "g_TexelSize": return .texelSize
        case "g_TexelSizeHalf": return .texelSizeHalf
        case "g_PointerPosition": return .pointer
        case "g_PointerPositionLast": return .pointerLast
        case "g_ParallaxPosition": return .parallax
        case "g_Color4": return .color4
        case "g_Color": return .color
        case "g_Alpha": return .alpha
        case "g_UserAlpha": return .userAlpha
        case "g_Brightness": return .brightness
        case "g_LightAmbientColor": return .lightAmbient
        case "g_LightSkylightColor": return .lightSkylight
        case "g_OrientationUp": return .orientationUp
        case "g_OrientationRight": return .orientationRight
        case "g_OrientationForward": return .orientationForward
        case "g_ViewUp": return .viewUp
        case "g_ViewRight": return .viewRight
        case "g_RenderVar0": return .renderVar0
        case "g_RenderVar1": return .renderVar1
        case "g_Bones": return .bones
        case "g_BonesAlpha": return .bonesAlpha
        default: break
        }
        if let match = name.wholeMatch(of: /g_AudioSpectrum(16|32|64)(Left|Right)/), let resolution = Int(match.1) {
            return .audio(resolution: resolution, right: match.2 == "Right")
        }
        if let match = name.wholeMatch(of: /g_Texture(\d+)Resolution/), let index = Int(match.1) { return .textureResolution(index) }
        if let match = name.wholeMatch(of: /g_Texture(\d+)Rotation/), let index = Int(match.1) { return .textureRotation(index) }
        if let match = name.wholeMatch(of: /g_Texture(\d+)Translation/), let index = Int(match.1) { return .textureTranslation(index) }
        if let match = name.wholeMatch(of: /g_Texture(\d+)MipMapInfo/), let index = Int(match.1) { return .textureMipInfo(index) }
        return nil
    }
}

/// Everything a draw needs to fill engine uniforms.
struct DrawState {
    var time: Float = 0
    var daytime: Float = 0
    var model = matrix_identity_float4x4
    var viewProjection = matrix_identity_float4x4
    var targetSize = SIMD2<Float>(1, 1)
    var screen = SIMD2<Float>(1, 1)
    var pointer = SIMD2<Float>(0.5, 0.5)
    var pointerLast = SIMD2<Float>(0.5, 0.5)
    var parallax = SIMD2<Float>(0, 0)
    var color = SIMD3<Float>(1, 1, 1)
    var alpha: Float = 1
    var brightness: Float = 1
    var ambient = SIMD3<Float>(repeating: 0.3)
    var skylight = SIMD3<Float>(repeating: 0.3)
    /// Per texture slot: (texture width, height, image width, height).
    var resolutions: [Int: SIMD4<Float>] = [:]
    /// Sprite-sheet frame for slot 0: rotation (x axis, y axis) and translation.
    var spriteRotation = SIMD4<Float>(1, 0, 0, 1)
    var spriteTranslation = SIMD2<Float>(0, 0)
    /// Camera position in world space (scene canvas units, in front of the canvas plane).
    var eye = SIMD3<Float>(960, 540, 2000)
    var renderVar0 = SIMD4<Float>.zero
    var renderVar1 = SIMD4<Float>.zero
    var bones: [simd_float4x4] = []
    var bonesAlpha: [Float] = []
    var audio = AudioBands.silent
}

/// A compiled pass with its static uniform values filled in; dynamic engine values are
/// written per draw.
struct UniformBlock {
    private(set) var slots: [SIMD4<Float>]
    private var dynamic: [(EngineUniform, WEUniform)] = []
    /// Material constants with keyframes.
    private var animated: [(SceneAnimation, WEUniform)] = []

    init(program: WEShaderProgram, constants: [[String: Any]], values: SceneValues) {
        slots = Array(repeating: .zero, count: program.slotCount)
        for uniform in program.uniforms {
            let engine = EngineUniform.classify(uniform.name)
            let objectDriven: Bool = {
                switch engine {
                case .userAlpha, .alpha, .brightness, .color4: return true
                default: return false
                }
            }()
            if let engine, uniform.materialKey == nil || objectDriven {
                dynamic.append((engine, uniform))
                continue
            }
            var raw: Any?
            if let key = uniform.materialKey {
                for table in constants {
                    if let value = table[key] ?? table.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                        raw = value
                        break
                    }
                }
            }
            if let animation = SceneAnimation(raw) {
                animated.append((animation, uniform))
                write(animation.values(at: 0), to: uniform)
                continue
            }
            let components = SceneValues.components(values.resolve(raw)) ?? SceneValues.components(values.resolve(uniform.defaultValue)) ?? []
            write(components, to: uniform)
        }
    }

    private mutating func write(_ components: [Float], to uniform: WEUniform) {
        guard !components.isEmpty else { return }
        switch uniform.kind {
        case .mat2, .mat3, .mat4, .mat4x3, .mat3x4:
            let rows = uniform.kind == .mat2 ? 2 : uniform.kind == .mat3 || uniform.kind == .mat3x4 ? 3 : 4
            let columns = uniform.kind.slots
            for column in 0..<columns where uniform.slot + column < slots.count {
                var value = SIMD4<Float>.zero
                for row in 0..<4 where row < rows {
                    let index = column * rows + row
                    if index < components.count { value[row] = components[index] }
                }
                slots[uniform.slot + column] = value
            }
        default:
            var value = SIMD4<Float>.zero
            for index in 0..<min(4, uniform.kind.components) {
                value[index] = index < components.count ? components[index] : (index == 3 ? 1 : 0)
            }
            if uniform.slot < slots.count { slots[uniform.slot] = value }
        }
    }

    var hasDynamicValues: Bool { !dynamic.isEmpty || !animated.isEmpty }

    /// Whether the shader reads the audio spectrum (so capture should run).
    var usesAudio: Bool {
        dynamic.contains { engine, _ in
            if case .audio = engine { return true }
            return false
        }
    }

    mutating func update(_ state: DrawState) {
        for (animation, uniform) in animated { write(animation.values(at: state.time), to: uniform) }
        for (engine, uniform) in dynamic {
            let s = uniform.slot
            guard s < slots.count else { continue }
            switch engine {
            case .time: slots[s].x = state.time
            case .daytime: slots[s].x = state.daytime
            case .modelMatrix: setMatrix(state.model, at: s, kind: uniform.kind)
            case .modelMatrixInverse: setMatrix(state.model.inverse, at: s, kind: uniform.kind)
            case .viewProjection: setMatrix(state.viewProjection, at: s, kind: uniform.kind)
            case .modelViewProjection, .effectModelViewProjection: setMatrix(state.viewProjection * state.model, at: s, kind: uniform.kind)
            case .modelViewProjectionInverse: setMatrix((state.viewProjection * state.model).inverse, at: s, kind: uniform.kind)
            case .effectTextureProjection, .effectTextureProjectionInverse: setMatrix(matrix_identity_float4x4, at: s, kind: uniform.kind)
            case .eyePosition: slots[s] = SIMD4(state.eye, 1)
            case .screen: slots[s] = SIMD4(state.screen.x, state.screen.y, state.screen.x / max(state.screen.y, 1), 0)
            case .texelSize: slots[s] = SIMD4(1 / state.targetSize.x, 1 / state.targetSize.y, 0, 0)
            case .texelSizeHalf: slots[s] = SIMD4(0.5 / state.targetSize.x, 0.5 / state.targetSize.y, 0, 0)
            case .textureResolution(let index): slots[s] = state.resolutions[index] ?? SIMD4(1, 1, 1, 1)
            case .textureRotation(let index): slots[s] = index == 0 ? state.spriteRotation : SIMD4(1, 0, 0, 1)
            case .textureTranslation(let index): slots[s] = index == 0 ? SIMD4(lowHalf: state.spriteTranslation, highHalf: .zero) : .zero
            case .textureMipInfo: slots[s] = SIMD4(1, 0, 0, 0)
            case .pointer: slots[s] = SIMD4(lowHalf: state.pointer, highHalf: .zero)
            case .pointerLast: slots[s] = SIMD4(lowHalf: state.pointerLast, highHalf: .zero)
            case .parallax: slots[s] = SIMD4(lowHalf: state.parallax, highHalf: .zero)
            case .color4: slots[s] = SIMD4(state.color * state.brightness, state.alpha)
            case .color: slots[s] = SIMD4(state.color, 1)
            case .alpha, .userAlpha: slots[s].x = state.alpha
            case .brightness: slots[s].x = state.brightness
            case .lightAmbient: slots[s] = SIMD4(state.ambient, 1)
            case .lightSkylight: slots[s] = SIMD4(state.skylight, 1)
            case .orientationUp, .viewUp: slots[s] = SIMD4(0, 1, 0, 0)
            case .orientationRight, .viewRight: slots[s] = SIMD4(1, 0, 0, 0)
            case .orientationForward: slots[s] = SIMD4(0, 0, 1, 0)
            case .renderVar0: slots[s] = state.renderVar0
            case .renderVar1: slots[s] = state.renderVar1
            case .bones:
                let stride = uniform.kind.slots
                for index in 0..<uniform.count {
                    let matrix = index < state.bones.count ? state.bones[index] : matrix_identity_float4x4
                    setMatrix(matrix, at: s + index * stride, kind: uniform.kind)
                }
            case .bonesAlpha:
                for index in 0..<uniform.count where s + index < slots.count {
                    slots[s + index].x = index < state.bonesAlpha.count ? state.bonesAlpha[index] : 1
                }
            case .audio(let resolution, let right):
                let bands = state.audio.channel(right: right, resolution: resolution)
                let stride = uniform.kind.slots
                for index in 0..<uniform.count where s + index * stride < slots.count {
                    slots[s + index * stride] = SIMD4(index < bands.count ? bands[index] : 0, 0, 0, 0)
                }
            case .zero:
                for index in 0..<(uniform.count * uniform.kind.slots) where s + index < slots.count { slots[s + index] = .zero }
            }
        }
    }

    private mutating func setMatrix(_ matrix: simd_float4x4, at slot: Int, kind: WEUniform.Kind) {
        switch kind {
        case .mat4, .mat4x3:
            guard slot + 3 < slots.count else { return }
            slots[slot] = matrix.columns.0
            slots[slot + 1] = matrix.columns.1
            slots[slot + 2] = matrix.columns.2
            slots[slot + 3] = matrix.columns.3
        case .mat3x4:
            guard slot + 2 < slots.count else { return }
            slots[slot] = SIMD4(matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x, matrix.columns.3.x)
            slots[slot + 1] = SIMD4(matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y, matrix.columns.3.y)
            slots[slot + 2] = SIMD4(matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z, matrix.columns.3.z)
        case .mat3:
            guard slot + 2 < slots.count else { return }
            slots[slot] = matrix.columns.0
            slots[slot + 1] = matrix.columns.1
            slots[slot + 2] = matrix.columns.2
        default:
            break
        }
    }
}
