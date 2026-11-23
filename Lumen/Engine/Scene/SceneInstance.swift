import Foundation
import Metal
import simd

/// Matches `WEVertex` in the translated shaders.
struct SceneVertex {
    var position: SIMD4<Float>
    var texcoord: SIMD4<Float>
    var texcoord1 = SIMD4<Float>.zero
    var texcoord2 = SIMD4<Float>.zero
    var color = SIMD4<Float>(1, 1, 1, 1)
    var normal = SIMD4<Float>(0, 0, 1, 0)
    var tangent = SIMD4<Float>(1, 0, 0, 1)
    var indices = SIMD4<UInt32>.zero
    var weights = SIMD4<Float>(1, 0, 0, 0)

    /// A quad as a 4-vertex triangle strip: top-left, bottom-left, top-right, bottom-right.
    static func quad(halfSize: SIMD2<Float>, center: SIMD2<Float> = .zero, uv: SIMD2<Float> = SIMD2(1, 1)) -> [SceneVertex] {
        [
            SceneVertex(position: SIMD4(center.x - halfSize.x, center.y + halfSize.y, 0, 1), texcoord: SIMD4(0, 0, 0, 0)),
            SceneVertex(position: SIMD4(center.x - halfSize.x, center.y - halfSize.y, 0, 1), texcoord: SIMD4(0, uv.y, 0, 0)),
            SceneVertex(position: SIMD4(center.x + halfSize.x, center.y + halfSize.y, 0, 1), texcoord: SIMD4(uv.x, 0, 0, 0)),
            SceneVertex(position: SIMD4(center.x + halfSize.x, center.y - halfSize.y, 0, 1), texcoord: SIMD4(uv.x, uv.y, 0, 0)),
        ]
    }
}

/// Where a pass's texture comes from at draw time.
enum TextureSource {
    case texture(SceneTexture)
    /// The previous pass's output in an effect chain.
    case previous
    /// An effect's own render target.
    case named(String)
    /// What the scene has drawn so far (`_rt_FullFrameBuffer`).
    case frameBuffer
    /// Another layer's offscreen composite buffer (`_rt_imageLayerComposite_<id>_a/b`).
    case layerComposite(Int)
    /// Per-layer MDL clipping mask buffer (`g_Texture8`).
    case clippingMask
}

/// A material pass, compiled, with its textures and constants resolved. A class, so the
/// per-frame uniform update writes in place instead of copying arrays.
final class PreparedPass {
    let program: CompiledProgram
    let pipeline: MTLRenderPipelineState
    var uniforms: UniformBlock
    let textures: [Int: TextureSource]
    /// The texture whose sprite-sheet frame drives `g_Texture0Translation`/`Rotation`.
    let spriteSheet: SceneTexture?
    let usesFrameBuffer: Bool
    /// Reusable shared buffers for uniform blocks exceeding Metal's 4 KB inline limit (e.g. skeletal `g_Bones`).
    private var uniformBuffers: [MTLBuffer] = []
    private var uniformRing = 0

    init(program: CompiledProgram, pipeline: MTLRenderPipelineState, uniforms: UniformBlock,
         textures: [Int: TextureSource], spriteSheet: SceneTexture?) {
        self.program = program
        self.pipeline = pipeline
        self.uniforms = uniforms
        self.textures = textures
        self.spriteSheet = spriteSheet
        // Only trigger framebuffer copies when a compiled sampler actually reads the slot.
        let activeSlots = Set(program.info.samplers.map(\.index))
        usesFrameBuffer = textures.contains { slot, source in
            guard activeSlots.contains(slot) else { return false }
            if case .frameBuffer = source { return true }
            return false
        }
    }

    func uniformBuffer(device: MTLDevice, bytes: UnsafeRawBufferPointer) -> MTLBuffer? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        let ringSize = 6
        if uniformBuffers.count < ringSize {
            guard let buf = device.makeBuffer(length: bytes.count, options: .storageModeShared) else { return nil }
            uniformBuffers.append(buf)
        }
        let buf = uniformBuffers[uniformRing % uniformBuffers.count]
        uniformRing &+= 1
        memcpy(buf.contents(), base, bytes.count)
        return buf
    }
}

/// One step of an image's effect chain.
struct EffectStep {
    enum Kind {
        case draw(PreparedPass)
        case copy(source: String, target: String)
    }
    let kind: Kind
    /// Render target name, or nil to write the next buffer in the chain.
    let target: String?
}

/// An image object, with its effect chain if it has one.
final class ImageLayer {
    let object: SceneDocument.Object
    let size: SIMD2<Float>
    let localModel: simd_float4x4
    var parentModel: simd_float4x4 = matrix_identity_float4x4
    let base: PreparedPass
    let steps: [EffectStep]
    let blend: SceneBlend
    let isPassthrough: Bool
    let isFullscreen: Bool
    /// For passthrough composition layers, whether Pass 0 copies the scene background (default `true`).
    let copyBackground: Bool
    /// Child drawables grouped into this composition layer's offscreen buffer.
    var children: [SceneDrawable] = []
    /// Another layer reads this layer's composite buffer (`_rt_imageLayerComposite_<id>_a/b`).
    let isCompositeSource: Bool
    /// Optional `BLENDMODE` composite pass used when a chained layer has `colorBlendMode != 0`.
    let compositePass: PreparedPass?
    let imageExtent: SIMD2<Float>
    let puppet: PuppetAnimator?
    let puppetClipping: PuppetClipping?
    var clippingMaskTarget: MTLTexture?
    /// Local-space centre and extent of Pass 0's offscreen buffer (equals `.zero`/`size` for normal layers).
    let chainCenter: SIMD2<Float>
    let chainSize: SIMD2<Float>
    var bufferSize = SIMD2<Int>(1, 1)
    var buffers: [MTLTexture] = []
    var targets: [String: MTLTexture] = [:]
    let targetScales: [String: Float]

    init(object: SceneDocument.Object, size: SIMD2<Float>, base: PreparedPass, steps: [EffectStep], blend: SceneBlend,
         isPassthrough: Bool, isFullscreen: Bool, copyBackground: Bool = true, isCompositeSource: Bool = false,
         compositePass: PreparedPass? = nil, imageExtent: SIMD2<Float>, targetScales: [String: Float],
         puppet: PuppetAnimator? = nil, puppetClipping: PuppetClipping? = nil,
         chainCenter: SIMD2<Float> = .zero, chainSize: SIMD2<Float>? = nil, anchorOverride: SIMD2<Float>? = nil) {
        self.object = object
        self.size = size
        self.base = base
        self.steps = steps
        self.blend = blend
        self.isPassthrough = isPassthrough
        self.isFullscreen = isFullscreen
        self.copyBackground = copyBackground
        self.isCompositeSource = isCompositeSource
        self.compositePass = compositePass
        self.imageExtent = imageExtent
        self.targetScales = targetScales
        self.puppet = puppet
        self.puppetClipping = puppetClipping
        self.chainCenter = chainCenter
        self.chainSize = chainSize ?? size
        anchor = SceneMath.translation(anchorOverride ?? SceneMath.anchorOffset(object.raw["alignment"] as? String, size: size))
        localModel = SceneMath.model(origin: object.origin, angles: object.angles, scale: object.scale) * anchor
    }

    private let anchor: simd_float4x4
    var model: simd_float4x4 { parentModel * localModel }

    /// The model matrix for this frame's state under its parent's world transform.
    func model(for state: SceneDocument.State, parent: simd_float4x4) -> simd_float4x4 {
        parent * SceneMath.model(origin: state.origin, angles: state.angles, scale: state.scale) * anchor
    }
    var needsChain: Bool { !steps.isEmpty || isPassthrough || isCompositeSource || compositePass != nil }
    /// Set for text layers; scripts update its string.
    var text: SceneTextTexture?
}

/// An indexed 3D mesh with its own surface material and depth state.
struct ModelLayer {
    struct Pass {
        let draw: PreparedPass
        let depth: MTLDepthStencilState?
        let cull: MTLCullMode
    }

    let object: SceneDocument.Object
    let mesh: PuppetModel
    let passes: [Pass]
}

/// Something the scene draws, in scene order.
enum SceneDrawable {
    case image(ImageLayer)
    case particles(ParticleLayer)
    case model(ModelLayer)

    var usesModelDepth: Bool {
        guard case .model(let model) = self else { return false }
        return model.passes.contains { $0.depth != nil }
    }
}

/// Everything needed to draw a scene frame: layers, render targets, shared pipelines.
final class SceneInstance: @unchecked Sendable {
    let document: SceneDocument
    let canvas: SIMD2<Float>
    let renderSize: SIMD2<Int>
    let drawables: [SceneDrawable]
    /// Top-level drawables not grouped under a passthrough composition layer.
    private let rootDrawables: [SceneDrawable]
    var layers: [ImageLayer] { drawables.compactMap { if case .image(let layer) = $0 { layer } else { nil } } }
    var particleLayers: [ParticleLayer] { drawables.compactMap { if case .particles(let layer) = $0 { layer } else { nil } } }
    let textures: SceneTextureCache
    let device: MTLDevice
    let unsupported: [String]

    private let modelCamera: SceneModelCamera?
    private let pointLights: [ScenePointLight]
    private let pointVolume: ScenePointVolume?
    private var framePointLights: [ScenePointLightSample] = []
    private var eyePosition: SIMD3<Float> { SIMD3(canvas.x / 2, canvas.y / 2, 2000) }

    private let sceneTexture: MTLTexture
    private let frameCopy: MTLTexture
    private let bloomTargets: [MTLTexture]
    private let utility: SceneUtilityPipelines
    private var frameCopyValid = false
    private var modelDepthTargets: [ObjectIdentifier: MTLTexture] = [:]
    private var placeholder: SceneTexture { textures.clear }
    private var indices: MTLBuffer?
    private let objects: [Int: SceneDocument.Object]
    private let puppetsByID: [Int: PuppetAnimator]
    let scripts: SceneScriptRuntime?
    private var scriptChanges: [Int: SceneScriptRuntime.Change] = [:]
    private var cursorTracker = SceneCursorTracker()
    private lazy var cursorLayers: [ImageLayer] = {
        guard let ids = scripts?.cursorLayerIDs, !ids.isEmpty else { return [] }
        // Some Workshop projects omit Solid for their scripted hit areas. An explicit false
        // still opts out, and a transparent but visible layer can be a click target.
        return layers.reversed().filter { ids.contains($0.object.id) && $0.object.raw["solid"] as? Bool != false }
    }()
    private var frameStates: [Int: SceneDocument.State] = [:]
    private var frameWorlds: [Int: simd_float4x4] = [:]
    private var compositeTextures: [Int: MTLTexture] = [:]
    private var frameTime: Float = 0
    /// Text layers whose string scripts set this frame, by object id.
    var scriptTexts: [Int: String] { scriptChanges.compactMapValues(\.text) }

    let sounds: SceneSoundPlayer?

    init(document: SceneDocument, renderSize: SIMD2<Int>, drawables: [SceneDrawable], rootDrawables: [SceneDrawable]? = nil,
         textures: SceneTextureCache, utility: SceneUtilityPipelines, queue: MTLCommandQueue? = nil, unsupported: [String],
         scripts: SceneScriptRuntime? = nil, sounds: SceneSoundPlayer? = nil,
         modelCamera: SceneModelCamera? = nil, pointLights: [ScenePointLight] = []) throws {
        self.document = document
        self.sounds = sounds
        self.scripts = scripts
        var objects: [Int: SceneDocument.Object] = [:]
        for object in document.objects where objects[object.id] == nil { objects[object.id] = object }
        self.objects = objects
        var puppets: [Int: PuppetAnimator] = [:]
        for drawable in drawables {
            if case .image(let layer) = drawable {
                if let puppet = layer.puppet { puppets[layer.object.id] = puppet }
            }
        }
        self.puppetsByID = puppets
        canvas = document.canvas
        self.renderSize = renderSize
        self.drawables = drawables
        self.rootDrawables = rootDrawables ?? drawables
        self.textures = textures
        self.utility = utility
        self.modelCamera = modelCamera
        self.pointLights = pointLights
        device = textures.device
        let hasPointVolume = pointLights.contains { $0.density > 0 }
        pointVolume = hasPointVolume && document.isOrthographic ? try? ScenePointVolume(device: device) : nil
        self.unsupported = hasPointVolume && pointVolume == nil ? unsupported + ["point-light volumes"] : unsupported
        sceneTexture = try Self.makeTarget(device, renderSize)
        frameCopy = try Self.makeTarget(device, renderSize)
        if document.bloomEnabled, document.bloomStrength > 0.001 {
            let bloomSize = SIMD2(max(1, renderSize.x / 4), max(1, renderSize.y / 4))
            bloomTargets = [
                try Self.makeTarget(device, bloomSize, format: .rgba16Float),
                try Self.makeTarget(device, bloomSize, format: .rgba16Float),
            ]
        } else {
            bloomTargets = []
        }
        if self.rootDrawables.contains(where: \.usesModelDepth) {
            modelDepthTargets[ObjectIdentifier(sceneTexture)] = try Self.makeModelDepthTarget(device, matching: sceneTexture)
        }
        let scale = Float(renderSize.x) / max(canvas.x, 1)
        indices = ParticleLayer.sharedIndices(device: device)
        for layer in layers {
            if layer.needsChain {
                let pixels = SIMD2<Int>(max(1, Int((layer.chainSize.x * scale).rounded())), max(1, Int((layer.chainSize.y * scale).rounded())))
                layer.bufferSize = SIMD2(min(pixels.x, 8192), min(pixels.y, 8192))
                layer.buffers = [try Self.makeTarget(device, layer.bufferSize), try Self.makeTarget(device, layer.bufferSize)]
                if layer.children.contains(where: \.usesModelDepth) {
                    let target = layer.buffers[0]
                    modelDepthTargets[ObjectIdentifier(target)] = try Self.makeModelDepthTarget(device, matching: target)
                }
                for (name, divisor) in layer.targetScales {
                    let size = SIMD2(max(1, Int(Float(layer.bufferSize.x) / divisor)), max(1, Int(Float(layer.bufferSize.y) / divisor)))
                    layer.targets[name] = try Self.makeTarget(device, size)
                }
            }
            if layer.puppetClipping != nil {
                let maskSize = layer.needsChain ? layer.bufferSize : renderSize
                layer.clippingMaskTarget = try Self.makeTarget(device, maskSize)
            }
        }
        clearTargets(on: queue)
    }

    /// New private textures hold whatever was in memory; effects that read a target before
    /// writing it (feedback trails, simulations) must start from transparent black.
    private func clearTargets(on queue: MTLCommandQueue?) {
        var targets = [sceneTexture, frameCopy] + bloomTargets
        for layer in layers {
            targets += layer.buffers
            targets += Array(layer.targets.values)
            if let mask = layer.clippingMaskTarget { targets.append(mask) }
        }
        guard let queue = queue ?? SceneQueues.queue(for: device), let buffer = queue.makeCommandBuffer() else { return }
        for texture in targets {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        buffer.commit()
        // Wait so a feedback effect on the first frame can never race an in-flight clear.
        buffer.waitUntilCompleted()
    }

    static func makeTarget(_ device: MTLDevice, _ size: SIMD2<Int>, format: MTLPixelFormat = .rgba8Unorm) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, size.x), height: max(1, size.y), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SceneLoadError.renderTargetAllocation }
        return texture
    }

    private static func makeModelDepthTarget(_ device: MTLDevice, matching target: MTLTexture) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: target.width,
                                                                   height: target.height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let depth = device.makeTexture(descriptor: descriptor) else {
            throw SceneLoadError.renderTargetAllocation
        }
        return depth
    }

    var outputTexture: MTLTexture { sceneTexture }

    /// Video textures play only while the scene does.
    func setPlaying(_ playing: Bool) {
        for texture in textures.videoTextures { texture.setPlaying(playing) }
        sounds?.setPlaying(playing)
    }

    // MARK: Frame

    struct Frame {
        var time: Float
        /// Seconds since the previous frame (0 while paused).
        var delta: Float = 0
        /// The pointer in canvas units (origin bottom-left), when it's over the scene.
        var pointerCanvas: SIMD2<Float>?
        var daytime: Float
        var pointer: SIMD2<Float>
        var pointerLast: SIMD2<Float>
        /// Camera offset in canvas units from parallax.
        var cameraOffset: SIMD2<Float>
        var parallax: SIMD2<Float>
        /// The system audio spectrum, for audio-reactive shaders, emitters and scripts.
        var audio: AudioBands = .silent
        var cursorInput = SceneCursorInput()
    }

    /// Whether anything in the scene reacts to the pointer (parallax, pointer shaders, cursor scripts, or mouse particles).
    private(set) lazy var usesPointer: Bool = {
        if document.parallaxEnabled { return true }
        if scripts?.usesPointer == true { return true }
        func passUses(_ pass: PreparedPass?) -> Bool { pass?.uniforms.usesPointer ?? false }
        for drawable in drawables {
            switch drawable {
            case .image(let layer):
                if passUses(layer.base) || passUses(layer.compositePass) { return true }
                for step in layer.steps { if case .draw(let pass) = step.kind, passUses(pass) { return true } }
            case .particles(let layer):
                if layer.systems.contains(where: { $0.usesPointer || $0.pass.uniforms.usesPointer }) { return true }
            case .model(let layer):
                if layer.passes.contains(where: { passUses($0.draw) }) { return true }
            }
        }
        return false
    }()

    /// Whether anything in the scene follows the music, so system audio capture is worth running.
    private(set) lazy var usesAudio: Bool = {
        if scripts?.wantsAudio == true { return true }
        func passUses(_ pass: PreparedPass?) -> Bool { pass?.uniforms.usesAudio ?? false }
        for drawable in drawables {
            switch drawable {
            case .image(let layer):
                if passUses(layer.base) || passUses(layer.compositePass) { return true }
                for step in layer.steps { if case .draw(let pass) = step.kind, passUses(pass) { return true } }
            case .particles(let layer):
                if layer.systems.contains(where: { $0.usesAudio || $0.pass.uniforms.usesAudio }) { return true }
            case .model(let layer):
                if layer.passes.contains(where: { passUses($0.draw) }) { return true }
            }
        }
        return false
    }()

    /// This frame's state of an object: keyframes, script changes, then inherited visibility.
    /// A transparent container can have visible children; a composition group applies alpha to its output.
    func state(of id: Int) -> SceneDocument.State? {
        if let cached = frameStates[id] { return cached }
        guard let object = objects[id] else { return nil }
        let change = scriptChanges[id]
        var state = object.state(at: frameTime, animationFrames: change?.animationFrames ?? [:])
        if let change {
            // Only take what the script actually changed, so keyframes keep running.
            if change.origin != object.origin { state.origin = change.origin }
            if change.scale != object.scale { state.scale = change.scale }
            if change.angles != object.angles { state.angles = change.angles }
            if change.alpha != object.alpha { state.alpha = change.alpha }
            if change.visible != object.visible { state.visible = change.visible }
            if change.color != object.color { state.color = change.color }
        }
        if let parentID = object.parent, parentID != id, let parent = objects[parentID],
           parent.raw["disablepropagation"] as? Bool != true, let parentState = self.state(of: parentID) {
            state.visible = state.visible && parentState.visible
        }
        frameStates[id] = state
        return state
    }

    /// Parent world transform for `object`, including any puppet bone attachment (`MDAT0001`).
    private func parentWorld(of object: SceneDocument.Object) -> simd_float4x4 {
        guard let parentID = object.parent, parentID != object.id else { return matrix_identity_float4x4 }
        var parent = world(of: parentID)
        if let attName = object.raw["attachment"] as? String,
           let attMatrix = puppetsByID[parentID]?.attachmentTransform(named: attName) {
            parent = parent * attMatrix
        }
        return parent
    }

    /// World transform of an object (without its alignment offset), for its children.
    func world(of id: Int?) -> simd_float4x4 {
        guard let id else { return matrix_identity_float4x4 }
        if let cached = frameWorlds[id] { return cached }
        guard let object = objects[id], let state = state(of: id) else { return matrix_identity_float4x4 }
        frameWorlds[id] = matrix_identity_float4x4
        let parent = parentWorld(of: object)
        let result = parent * SceneMath.model(origin: state.origin, angles: state.angles, scale: state.scale)
        frameWorlds[id] = result
        return result
    }

    /// Whether this object's parent chain is visible (for hidden composite capture layers).
    private func parentVisible(of id: Int) -> Bool {
        guard let object = objects[id], let parentID = object.parent, parentID != id,
              let parent = objects[parentID], parent.raw["disablepropagation"] as? Bool != true
        else { return true }
        return state(of: parentID)?.visible ?? true
    }

    private func cursorEvents(for frame: Frame) -> [SceneCursorEvent] {
        let input = frame.cursorInput
        guard input.reset || !input.samples.isEmpty, !cursorLayers.isEmpty else { return [] }
        let targets: [SceneCursorTarget] = input.samples.contains(where: { $0.world != nil })
            ? cursorLayers.compactMap { layer in
                let object = layer.object
                guard let state = self.state(of: object.id), state.visible else { return nil }
                let offset = document.parallaxEnabled ? frame.cameraOffset * object.parallaxDepth : .zero
                return SceneCursorTarget(layerID: object.id, size: layer.size,
                                         model: layer.model(for: state, parent: world(of: object.parent)), cameraOffset: offset)
            }
            : []
        return cursorTracker.events(for: input, targets: targets)
    }

    /// Draws the whole scene into `outputTexture`.
    func encode(into buffer: MTLCommandBuffer, frame: Frame) {
        frameCopyValid = false
        frameTime = frame.time
        frameStates.removeAll(keepingCapacity: true)
        frameWorlds.removeAll(keepingCapacity: true)
        compositeTextures.removeAll(keepingCapacity: true)
        if let scripts {
            let events = cursorEvents(for: frame)
            scriptChanges = scripts.update(time: Double(frame.time), delta: Double(frame.delta), daytime: Double(frame.daytime),
                                           cursor: frame.pointerCanvas, cursorDown: frame.cursorInput.isDown,
                                           cursorScreen: frame.cursorInput.screen, cursorEvents: events, audio: frame.audio)
            if !frameStates.isEmpty {
                // Hit testing used the last script state. Draw with changes from this frame's callbacks.
                frameStates.removeAll(keepingCapacity: true)
                frameWorlds.removeAll(keepingCapacity: true)
            }
        }
        // Evaluate all puppet skeletons up front so bone attachments are ready in any layer order.
        for (_, puppet) in puppetsByID { puppet.evaluate(at: frame.time) }
        samplePointLights()
        var session = SceneSession(target: sceneTexture, clear: document.clearColor,
                                   modelDepth: modelDepthTargets[ObjectIdentifier(sceneTexture)])
        // Clear up front: a layer may copy the background before anything has drawn.
        _ = session.encoder(buffer)
        let sceneTargetSize = SIMD2(Float(renderSize.x), Float(renderSize.y))

        for drawable in rootDrawables {
            encodeDrawable(drawable, into: buffer, session: &session, viewProjectionOverride: nil,
                           targetSize: sceneTargetSize, frame: frame)
        }
        if let pointVolume {
            for light in framePointLights where light.density > 0 {
                guard let encoder = session.encoder(buffer) else { break }
                let offset = document.parallaxEnabled ? frame.cameraOffset * light.parallaxDepth : .zero
                pointVolume.draw(encoder: encoder, viewProjection: SceneMath.orthographic(canvas: canvas, offset: offset),
                                 positionRadius: light.positionRadius, radiance: SIMD3(light.colorFalloff.x, light.colorFalloff.y, light.colorFalloff.z),
                                 density: light.density, falloff: light.volumeFalloff, eyeZ: eyePosition.z)
            }
        }
        session.end(clearIfUnused: buffer)
        if bloomTargets.count == 2 { encodeBloom(into: buffer) }
    }

    /// Scene-wide `general.bloom` post-process: quarter-res bright-pass extract, separable
    /// 9-tap Gaussian blur, and additive composite tinted by `bloomTint * bloomStrength`.
    private func encodeBloom(into buffer: MTLCommandBuffer) {
        let a = bloomTargets[0], b = bloomTargets[1]
        let sampler = textures.samplers.state(nearest: false, clamp: true)
        let texel = SIMD2<Float>(1 / Float(a.width), 1 / Float(a.height))

        if let enc = beginPass(buffer, target: a, clear: false) {
            var params = SIMD4<Float>(document.bloomThreshold, 1 / Float(sceneTexture.width), 1 / Float(sceneTexture.height), 0)
            enc.setRenderPipelineState(utility.bloomExtract)
            enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setFragmentTexture(sceneTexture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        if let enc = beginPass(buffer, target: b, clear: false) {
            var dir = SIMD2<Float>(texel.x, 0)
            enc.setRenderPipelineState(utility.bloomBlur)
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.setFragmentTexture(a, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        if let enc = beginPass(buffer, target: a, clear: false) {
            var dir = SIMD2<Float>(0, texel.y)
            enc.setRenderPipelineState(utility.bloomBlur)
            enc.setFragmentBytes(&dir, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            enc.setFragmentTexture(b, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = sceneTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        if let enc = buffer.makeRenderCommandEncoder(descriptor: pass) {
            // Scale WE's SDR bloom strength gently so bright accents glow without clipping to flat white.
            let gain = min(document.bloomStrength, 6) * 0.25
            var tint = SIMD4<Float>(document.bloomTint * gain, 1)
            enc.setRenderPipelineState(utility.bloomComposite)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setFragmentTexture(a, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
    }

    private func samplePointLights() {
        framePointLights.removeAll(keepingCapacity: true)
        for light in pointLights {
            guard let state = state(of: light.id), state.visible, state.alpha > 0, state.brightness > 0 else { continue }
            let radiance = state.color * (state.alpha * state.brightness * light.intensity)
            let position = world(of: light.id).columns.3
            guard radiance.x.isFinite, radiance.y.isFinite, radiance.z.isFinite,
                  position.x.isFinite, position.y.isFinite, position.z.isFinite else { continue }
            let color = simd_max(radiance, .zero)
            guard simd_reduce_max(color) > 0 else { continue }
            framePointLights.append(ScenePointLightSample(
                positionRadius: SIMD4(position.x, position.y, position.z, light.radius),
                colorFalloff: SIMD4(color.x, color.y, color.z, light.falloff),
                density: light.density, volumeFalloff: light.volumeFalloff, parallaxDepth: light.parallaxDepth
            ))
        }
    }

    private func encodeDrawable(_ drawable: SceneDrawable, into buffer: MTLCommandBuffer, session: inout SceneSession,
                                viewProjectionOverride: simd_float4x4?, targetSize: SIMD2<Float>, frame: Frame) {
        let isSceneTarget = (session.target === sceneTexture)
        let layer: ImageLayer
        switch drawable {
        case .image(let image):
            layer = image
        case .model(let model):
            encodeModel(model, into: buffer, session: &session, viewProjectionOverride: viewProjectionOverride,
                        targetSize: targetSize, frame: frame)
            return
        case .particles(let particles):
            guard let particleState = state(of: particles.object.id) else { return }
            particles.parentModel = parentWorld(of: particles.object)
            particles.localModel = SceneMath.model(origin: particleState.origin, angles: particleState.angles, scale: particleState.scale)
            let offset = document.parallaxEnabled ? frame.cameraOffset * particles.object.parallaxDepth : .zero
            let pointerWorld = frame.pointerCanvas.map { $0 + offset }
            particles.update(delta: frame.delta, pointerCanvas: pointerWorld, audio: frame.audio)
            guard particleState.visible else { return }
            if let encoder = session.encoder(buffer) {
                if isSceneTarget { frameCopyValid = false }
                let vp = viewProjectionOverride ?? SceneMath.orthographic(canvas: canvas, offset: offset)
                encodeParticles(particles, encoder: encoder, viewProjection: vp, targetSize: targetSize, frame: frame)
            }
            return
        }
        if let text = layer.text, let newText = scriptChanges[layer.object.id]?.text { text.update(newText) }
        guard let objectState = state(of: layer.object.id) else { return }
        let drawsToTarget = objectState.visible && objectState.alpha > 0.001
            && (!layer.isPassthrough || !layer.steps.isEmpty || !layer.children.isEmpty)
        let capturesForOthers = layer.isCompositeSource && parentVisible(of: layer.object.id)
        guard drawsToTarget || capturesForOthers else { return }
        let parentTransform = parentWorld(of: layer.object)
        // Parallax moves each layer by its depth (background layers usually less than 1).
        let offset = document.parallaxEnabled ? frame.cameraOffset * layer.object.parallaxDepth : .zero
        let screenVP = SceneMath.orthographic(canvas: canvas, offset: offset)
        let layerVP = viewProjectionOverride ?? screenVP
        if layer.needsChain {
            encodeChain(layer, state: objectState, parent: parentTransform, buffer: buffer, session: &session,
                        viewProjection: layerVP, screenViewProjection: screenVP, targetSize: targetSize,
                        frame: frame, compositeToTarget: drawsToTarget)
        } else {
            let needsFB = layer.base.usesFrameBuffer || (layer.puppetClipping?.clippedBase.usesFrameBuffer == true)
            if needsFB { session.end(); copyFrame(buffer) }
            var state = drawState(frame: frame, object: objectState)
            let model = layer.model(for: objectState, parent: parentTransform)
            let (etp, etpInv) = Self.effectTextureProjection(for: layer, model: model, screenViewProjection: screenVP)
            state.model = model
            state.viewProjection = layerVP
            state.effectTextureProjection = etp
            state.effectTextureProjectionInverse = etpInv
            state.targetSize = targetSize
            encodeImageBase(
                layer: layer, state: state, buffer: buffer,
                openEncoder: {
                    if isSceneTarget { frameCopyValid = false }
                    return session.encoder(buffer)
                },
                closeEncoder: { session.end() }
            )
        }
    }

    private func encodeModel(_ layer: ModelLayer, into buffer: MTLCommandBuffer, session: inout SceneSession,
                             viewProjectionOverride: simd_float4x4?, targetSize: SIMD2<Float>, frame: Frame) {
        guard let object = state(of: layer.object.id), object.visible, object.alpha > 0.001 else { return }
        var state = drawState(frame: frame, object: object)
        state.model = parentWorld(of: layer.object) * SceneMath.model(origin: object.origin, angles: object.angles, scale: object.scale)
        if let viewProjectionOverride {
            state.viewProjection = viewProjectionOverride
        } else if let modelCamera {
            state.eye = modelCamera.eye
            state.viewProjection = modelCamera.viewProjection
        } else {
            let offset = document.parallaxEnabled ? frame.cameraOffset * layer.object.parallaxDepth : .zero
            state.viewProjection = SceneMath.orthographic(canvas: canvas, offset: offset)
        }
        state.targetSize = targetSize
        let mesh = MeshRange(vertexBuffer: layer.mesh.vertexBuffer, indexBuffer: layer.mesh.indexBuffer,
                             indexStart: 0, indexCount: layer.mesh.indexCount)
        for pass in layer.passes {
            if pass.draw.usesFrameBuffer {
                session.end()
                copyFrame(buffer)
            }
            guard let encoder = session.encoder(buffer, withModelDepth: pass.depth != nil) else { continue }
            if session.target === sceneTexture { frameCopyValid = false }
            if let depth = pass.depth { encoder.setDepthStencilState(depth) }
            encoder.setFrontFacing(.counterClockwise)
            encoder.setCullMode(pass.cull)
            draw(pass.draw, encoder: encoder, vertices: [], state: state, previous: nil, layer: nil, mesh: mesh)
            encoder.setCullMode(.none)
        }
    }

    private struct MeshRange {
        let vertexBuffer: MTLBuffer
        let indexBuffer: MTLBuffer
        let indexStart: Int
        let indexCount: Int
    }

    /// Draws an image layer's base geometry (quad or puppet mesh, with optional MDL clipping masks).
    private func encodeImageBase(layer: ImageLayer, state: DrawState, buffer: MTLCommandBuffer,
                                 openEncoder: () -> MTLRenderCommandEncoder?, closeEncoder: () -> Void) {
        guard let puppet = layer.puppet else {
            guard let encoder = openEncoder() else { return }
            let uv = layer.base.spriteSheet != nil || layer.isPassthrough ? SIMD2<Float>(1, 1) : layer.imageExtent
            draw(layer.base, encoder: encoder, vertices: SceneVertex.quad(halfSize: layer.size / 2, uv: uv),
                 state: state, previous: nil, layer: layer)
            return
        }
        let model = puppet.model
        guard let clipping = layer.puppetClipping, let maskTarget = layer.clippingMaskTarget else {
            guard let encoder = openEncoder() else { return }
            let range = MeshRange(vertexBuffer: model.vertexBuffer, indexBuffer: model.indexBuffer,
                                  indexStart: 0, indexCount: model.indexCount)
            draw(layer.base, encoder: encoder, vertices: [], state: state, previous: nil, layer: layer, mesh: range)
            return
        }

        var renderedMaskEntry: Int?
        var encoder: MTLRenderCommandEncoder?
        for (submeshIndex, submesh) in model.submeshes.enumerated() where submesh.indexCount > 0 {
            let pass: PreparedPass
            if let entryIndex = clipping.submeshToEntry[submeshIndex] {
                if renderedMaskEntry != entryIndex {
                    if encoder != nil {
                        closeEncoder()
                        encoder = nil
                    }
                    let entry = clipping.entries[entryIndex]
                    if let maskEncoder = beginPass(buffer, target: maskTarget) {
                        var maskState = state
                        maskState.color = SIMD3(1, 1, 1)
                        maskState.alpha = 1
                        maskState.brightness = 1
                        maskState.renderVar0 = .zero
                        for maskSubIdx in entry.maskSubmeshes where maskSubIdx >= 0 && maskSubIdx < model.submeshes.count {
                            let maskSub = model.submeshes[maskSubIdx]
                            guard maskSub.indexCount > 0 else { continue }
                            let maskRange = MeshRange(vertexBuffer: model.vertexBuffer, indexBuffer: model.indexBuffer,
                                                      indexStart: maskSub.indexStart, indexCount: maskSub.indexCount)
                            draw(entry.maskPass, encoder: maskEncoder, vertices: [], state: maskState,
                                 previous: nil, layer: layer, mesh: maskRange)
                        }
                        maskEncoder.endEncoding()
                    }
                    renderedMaskEntry = entryIndex
                }
                pass = clipping.clippedBase
            } else {
                pass = layer.base
            }
            if encoder == nil { encoder = openEncoder() }
            guard let activeEncoder = encoder else { continue }
            let range = MeshRange(vertexBuffer: model.vertexBuffer, indexBuffer: model.indexBuffer,
                                  indexStart: submesh.indexStart, indexCount: submesh.indexCount)
            draw(pass, encoder: activeEncoder, vertices: [], state: state, previous: nil, layer: layer, mesh: range)
        }
    }

    /// Maps a layer's effect-texture NDC `[-1, 1]^2` into screen NDC `[-1, 1]^2`, and its inverse.
    /// Pointer-driven effects (`iris_movement`, `xray`, `cursorripple`, `depthparallax`) unproject
    /// screen-space cursor NDC through the inverse so the effect centers on the layer's true screen rect.
    private static func effectTextureProjection(
        for layer: ImageLayer,
        model: simd_float4x4,
        screenViewProjection: simd_float4x4
    ) -> (simd_float4x4, simd_float4x4) {
        let projection = screenViewProjection
            * model
            * SceneMath.translation(layer.chainCenter)
            * SceneMath.scale(layer.chainSize / 2)
        let det = simd_determinant(projection)
        let inverse = det.isFinite && abs(det) > 1e-12 ? projection.inverse : matrix_identity_float4x4
        return (projection, inverse)
    }

    private func encodeChain(_ layer: ImageLayer, state objectState: SceneDocument.State, parent: simd_float4x4, buffer: MTLCommandBuffer,
                             session: inout SceneSession, viewProjection: simd_float4x4, screenViewProjection: simd_float4x4,
                             targetSize: SIMD2<Float>, frame: Frame, compositeToTarget: Bool) {
        let isSceneTarget = (session.target === sceneTexture)
        let model = layer.model(for: objectState, parent: parent)
        guard layer.buffers.count == 2 else { return }
        let (etp, etpInv) = Self.effectTextureProjection(for: layer, model: model, screenViewProjection: screenViewProjection)
        let base = layer.base
        // The chain renders into its own buffers, so the caller's encoder has to close first.
        session.end()
        let copyBg = layer.isPassthrough && layer.copyBackground
        if base.usesFrameBuffer || (layer.puppetClipping?.clippedBase.usesFrameBuffer == true) || copyBg {
            copyFrame(buffer)
        }
        // Pass 0: the object's own material into the first buffer (or transparent black when
        // a composition layer opts out of `copybackground`).
        var state = drawState(frame: frame, object: objectState)
        if base.uniforms.usesPointLighting { state.worldModel = model }
        state.effectTextureProjection = etp
        state.effectTextureProjectionInverse = etpInv
        state.targetSize = SIMD2(Float(layer.bufferSize.x), Float(layer.bufferSize.y))
        if layer.isPassthrough {
            state.model = model
            state.viewProjection = viewProjection
        } else {
            state.model = matrix_identity_float4x4
            state.viewProjection = SceneMath.localOrthographic(center: layer.chainCenter, size: layer.chainSize)
        }
        var current = 0
        if layer.isPassthrough, !layer.copyBackground {
            beginPass(buffer, target: layer.buffers[0], clear: true)?.endEncoding()
        } else {
            var pass0Encoder: MTLRenderCommandEncoder?
            var pass0Cleared = false
            encodeImageBase(
                layer: layer, state: state, buffer: buffer,
                openEncoder: {
                    if let existing = pass0Encoder { return existing }
                    let enc = beginPass(buffer, target: layer.buffers[0], clear: !pass0Cleared)
                    pass0Cleared = true
                    pass0Encoder = enc
                    return enc
                },
                closeEncoder: {
                    pass0Encoder?.endEncoding()
                    pass0Encoder = nil
                }
            )
            if !pass0Cleared, let enc = beginPass(buffer, target: layer.buffers[0], clear: true) {
                enc.endEncoding()
            } else {
                pass0Encoder?.endEncoding()
            }
        }

        // Grouped composition layer children draw into Pass 0's buffer before parent effects run.
        if layer.isPassthrough, !layer.children.isEmpty, abs(simd_determinant(model)) > 1e-10 {
            let groupVP = SceneMath.localOrthographic(center: layer.chainCenter, size: layer.chainSize) * model.inverse
            let groupTargetSize = SIMD2(Float(layer.bufferSize.x), Float(layer.bufferSize.y))
            let groupTarget = layer.buffers[0]
            var groupSession = SceneSession(target: groupTarget, clear: .zero, cleared: true,
                                            modelDepth: modelDepthTargets[ObjectIdentifier(groupTarget)])
            for child in layer.children {
                encodeDrawable(child, into: buffer, session: &groupSession, viewProjectionOverride: groupVP,
                               targetSize: groupTargetSize, frame: frame)
            }
            groupSession.end()
        }

        // Effects, ping-ponging between the two buffers.
        for step in layer.steps {
            switch step.kind {
            case .copy(let sourceName, let targetName):
                let source = sourceName == "previous" ? layer.buffers[current] : layer.targets[sourceName]
                if let source, let target = layer.targets[targetName] ?? (targetName == "previous" ? layer.buffers[current] : nil),
                   source.width == target.width, source.height == target.height, let blit = buffer.makeBlitCommandEncoder() {
                    blit.copy(from: source, to: target)
                    blit.endEncoding()
                }
            case .draw(let pass):
                if pass.usesFrameBuffer, !frameCopyValid { copyFrame(buffer) }
                let destination: MTLTexture
                if let name = step.target, let named = layer.targets[name] {
                    destination = named
                } else {
                    destination = layer.buffers[1 - current]
                }
                var effectState = drawState(frame: frame, object: objectState)
                effectState.targetSize = SIMD2(Float(destination.width), Float(destination.height))
                effectState.model = matrix_identity_float4x4
                effectState.viewProjection = matrix_identity_float4x4
                effectState.effectTextureProjection = etp
                effectState.effectTextureProjectionInverse = etpInv
                if let encoder = beginPass(buffer, target: destination) {
                    draw(pass, encoder: encoder, vertices: SceneVertex.quad(halfSize: SIMD2(1, 1)), state: effectState,
                         previous: layer.buffers[current], layer: layer)
                    encoder.endEncoding()
                }
                if step.target == nil { current = 1 - current }
            }
        }

        if layer.isCompositeSource {
            compositeTextures[layer.object.id] = layer.buffers[current]
        }
        guard compositeToTarget else { return }

        // Composite the result onto the target with the object's transform.
        let compositeQuad = SceneVertex.quad(halfSize: layer.chainSize / 2, center: layer.chainCenter)
        if let composite = layer.compositePass {
            if composite.usesFrameBuffer, !frameCopyValid { copyFrame(buffer) }
            guard let encoder = session.encoder(buffer) else { return }
            if isSceneTarget { frameCopyValid = false }
            var compState = drawState(frame: frame, object: objectState)
            // Colour, brightness and alpha were already applied in Pass 0 for non-passthrough layers.
            compState.color = SIMD3(1, 1, 1)
            compState.alpha = layer.isPassthrough ? objectState.alpha : 1
            compState.brightness = 1
            compState.model = model
            compState.viewProjection = viewProjection
            compState.effectTextureProjection = etp
            compState.effectTextureProjectionInverse = etpInv
            compState.targetSize = targetSize
            draw(composite, encoder: encoder, vertices: compositeQuad,
                 state: compState, previous: layer.buffers[current], layer: layer)
            return
        }
        guard let encoder = session.encoder(buffer), let pipeline = utility.composite[layer.blend] ?? utility.composite[.translucent] else { return }
        if isSceneTarget { frameCopyValid = false }
        var mvp = viewProjection * model
        var compositeAlpha: Float = layer.isPassthrough ? objectState.alpha : 1
        encoder.setRenderPipelineState(pipeline)
        compositeQuad.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 0)
        encoder.setFragmentBytes(&compositeAlpha, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentTexture(layer.buffers[current], index: 0)
        encoder.setFragmentSamplerState(textures.samplers.state(nearest: false, clamp: true), index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawState(frame: Frame, object: SceneDocument.State) -> DrawState {
        var state = DrawState()
        state.eye = eyePosition
        state.pointLights = framePointLights
        state.time = frame.time
        state.daytime = frame.daytime
        state.screen = SIMD2(Float(renderSize.x), Float(renderSize.y))
        state.pointer = frame.pointer
        state.pointerLast = frame.pointerLast
        state.parallax = frame.parallax
        state.color = object.color
        state.alpha = object.alpha
        state.brightness = object.brightness
        state.ambient = document.ambientColor
        state.skylight = document.skylightColor
        state.audio = frame.audio
        return state
    }

    private func beginPass(_ buffer: MTLCommandBuffer, target: MTLTexture, clear: Bool = true) -> MTLRenderCommandEncoder? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = clear ? .clear : .load
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        return buffer.makeRenderCommandEncoder(descriptor: descriptor)
    }

    private func copyFrame(_ buffer: MTLCommandBuffer) {
        guard !frameCopyValid, let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: sceneTexture, to: frameCopy)
        blit.endEncoding()
        frameCopyValid = true
    }

    private func draw(_ pass: PreparedPass, encoder: MTLRenderCommandEncoder, vertices: [SceneVertex],
                      state: DrawState, previous: MTLTexture?, layer: ImageLayer?,
                      particleBuffer: (MTLBuffer, Int)? = nil, mesh: MeshRange? = nil) {
        var state = state
        if mesh != nil, let puppet = layer?.puppet {
            state.bones = puppet.skinMatrices
            state.bonesAlpha = puppet.boneAlphas
        }
        // Texture sizes for g_TextureNResolution, and the current sprite frame.
        for (index, source) in pass.textures {
            switch source {
            case .texture(let texture):
                state.resolutions[index] = texture.resolution
            case .previous:
                if let previous { state.resolutions[index] = SIMD4(Float(previous.width), Float(previous.height), Float(previous.width), Float(previous.height)) }
            case .named(let name):
                if let target = layer?.targets[name] { state.resolutions[index] = SIMD4(Float(target.width), Float(target.height), Float(target.width), Float(target.height)) }
            case .frameBuffer:
                state.resolutions[index] = SIMD4(Float(renderSize.x), Float(renderSize.y), Float(renderSize.x), Float(renderSize.y))
            case .layerComposite(let sourceID):
                if let source = compositeTextures[sourceID] {
                    state.resolutions[index] = SIMD4(Float(source.width), Float(source.height), Float(source.width), Float(source.height))
                }
            case .clippingMask:
                if let mask = layer?.clippingMaskTarget {
                    state.resolutions[index] = SIMD4(Float(mask.width), Float(mask.height), Float(mask.width), Float(mask.height))
                }
            }
        }
        var frameImage = 0
        if let sheet = pass.spriteSheet, let frame = sheet.frame(at: state.time) {
            state.spriteTranslation = frame.origin
            state.spriteRotation = SIMD4(lowHalf: frame.xAxis, highHalf: frame.yAxis)
            frameImage = frame.image
        }
        pass.uniforms.update(state)

        encoder.setRenderPipelineState(pass.pipeline)
        pass.uniforms.slots.withUnsafeBytes { bytes in
            if bytes.count <= 4096 {
                encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            } else if let buffer = pass.uniformBuffer(device: device, bytes: bytes) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            }
        }
        if let mesh {
            encoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 1)
        } else if let (vertexBuffer, _) = particleBuffer {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
        } else {
            vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        }

        for sampler in pass.program.info.samplers {
            var texture: MTLTexture = placeholder.texture
            var samplerState = placeholder.sampler
            switch pass.textures[sampler.index] {
            case .texture(let scene)?:
                texture = sampler.index == 0 && scene.video == nil && frameImage < scene.images.count ? scene.images[frameImage] : scene.texture
                samplerState = scene.sampler
            case .previous?:
                if let previous { texture = previous }
                samplerState = textures.samplers.state(nearest: false, clamp: true)
            case .named(let name)?:
                if let target = layer?.targets[name] { texture = target }
                samplerState = textures.samplers.state(nearest: false, clamp: true)
            case .frameBuffer?:
                texture = frameCopy
                samplerState = textures.samplers.state(nearest: false, clamp: true)
            case .layerComposite(let sourceID)?:
                if let source = compositeTextures[sourceID] { texture = source }
                samplerState = textures.samplers.state(nearest: false, clamp: true)
            case .clippingMask?:
                if let mask = layer?.clippingMaskTarget { texture = mask }
                samplerState = textures.samplers.state(nearest: false, clamp: true)
            case nil:
                break
            }
            switch sampler.stage {
            case .vertex:
                encoder.setVertexTexture(texture, index: sampler.index)
                encoder.setVertexSamplerState(samplerState, index: sampler.index)
            case .fragment:
                encoder.setFragmentTexture(texture, index: sampler.index)
                encoder.setFragmentSamplerState(samplerState, index: sampler.index)
            }
        }
        if let mesh {
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: mesh.indexCount, indexType: .uint16,
                indexBuffer: mesh.indexBuffer, indexBufferOffset: mesh.indexStart * MemoryLayout<UInt16>.stride
            )
        } else if let (_, quads) = particleBuffer {
            guard let indices, quads > 0 else { return }
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: quads * 6, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        } else {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Simulated particles, drawn as quads with each system's own material.
    private func encodeParticles(_ layer: ParticleLayer, encoder: MTLRenderCommandEncoder,
                                 viewProjection: simd_float4x4, targetSize: SIMD2<Float>, frame: Frame) {
        for system in layer.systems {
            guard case .none = system.renderer else {
                guard let buffer = layer.vertexBuffer(for: system, device: device) else { continue }
                let capacity = buffer.length / (MemoryLayout<SceneVertex>.stride * 4)
                let textureRatio: Float = {
                    if let sheet = system.pass.spriteSheet, let first = sheet.frames.first {
                        let width = max(first.xAxis.x, 0.0001), height = max(first.yAxis.y, 0.0001)
                        return (height * sheet.textureSize.y) / max(width * sheet.textureSize.x, 0.0001)
                    }
                    if case .texture(let tex)? = system.pass.textures[0] {
                        return tex.resolution.y / max(tex.resolution.x, 1)
                    }
                    return 1
                }()
                let count = system.writeVertices(
                    into: buffer.contents().bindMemory(to: SceneVertex.self, capacity: capacity * 4),
                    capacity: capacity,
                    textureRatio: textureRatio
                )
                guard count > 0 else { continue }
                var state = drawState(frame: frame, object: self.state(of: layer.object.id) ?? layer.object.state(at: frame.time))
                state.model = system.childKind == .independent && system !== layer.root ? layer.model * system.localTransform : layer.model
                state.viewProjection = viewProjection
                state.targetSize = targetSize
                // Particle colour and alpha come from the simulation, not the object.
                state.color = SIMD3(1, 1, 1)
                state.alpha = 1
                switch system.renderer {
                case .trail(let length, let maxLength, let minLength):
                    state.renderVar0 = SIMD4(length, maxLength, minLength, 0)
                case .rope, .ropeTrail:
                    state.renderVar0 = SIMD4(1, 10_000, 0, 0)
                case .sprite, .none:
                    break
                }
                if let sheet = system.pass.spriteSheet, let first = sheet.frames.first {
                    let width = max(first.xAxis.x, 0.0001), height = max(first.yAxis.y, 0.0001)
                    let ratio = (height * sheet.textureSize.y) / max(width * sheet.textureSize.x, 0.0001)
                    state.renderVar1 = SIMD4(width, height, Float(sheet.frames.count), ratio)
                }
                draw(system.pass, encoder: encoder, vertices: [], state: state, previous: nil, layer: nil, particleBuffer: (buffer, count))
                continue
            }
        }
        layer.advanceFrame()
    }
}

/// Keeps one render encoder on the scene target open across consecutive direct draws.
private struct SceneSession {
    let target: MTLTexture
    let clear: SIMD3<Float>
    private let modelDepth: MTLTexture?
    private var encoder: MTLRenderCommandEncoder?
    private var cleared = false
    private var depthCleared = false
    private var encodingModelDepth = false

    init(target: MTLTexture, clear: SIMD3<Float>, cleared: Bool = false, modelDepth: MTLTexture? = nil) {
        self.target = target
        self.clear = clear
        self.cleared = cleared
        self.modelDepth = modelDepth
    }

    mutating func encoder(_ buffer: MTLCommandBuffer, withModelDepth: Bool = false) -> MTLRenderCommandEncoder? {
        if let encoder {
            if encodingModelDepth == withModelDepth { return encoder }
            end()
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = cleared ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1)
        if withModelDepth {
            guard let modelDepth else { return nil }
            descriptor.depthAttachment.texture = modelDepth
            descriptor.depthAttachment.clearDepth = 1
            descriptor.depthAttachment.loadAction = depthCleared ? .load : .clear
            // A 2D layer or framebuffer copy may interrupt a series of 3D draws.
            descriptor.depthAttachment.storeAction = .store
        }
        guard let next = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }
        cleared = true
        encodingModelDepth = withModelDepth
        if withModelDepth { depthCleared = true }
        encoder = next
        return next
    }

    mutating func end() {
        if encoder == nil, !cleared { return }
        encoder?.endEncoding()
        encoder = nil
    }

    /// Ends the frame; a scene with nothing visible still gets its clear colour.
    mutating func end(clearIfUnused buffer: MTLCommandBuffer) {
        if !cleared { _ = encoder(buffer) }
        end()
    }
}

/// Built-in pipelines that aren't Wallpaper Engine shaders: compositing an effect chain onto
/// the scene, and presenting the scene on the display.
final class SceneUtilityPipelines: @unchecked Sendable {
    let composite: [SceneBlend: MTLRenderPipelineState]
    let present: MTLRenderPipelineState
    /// Catmull-Rom filtering for when the scene is shown larger than it was rendered.
    let presentSharp: MTLRenderPipelineState
    let bloomExtract: MTLRenderPipelineState
    let bloomBlur: MTLRenderPipelineState
    let bloomComposite: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        var composite: [SceneBlend: MTLRenderPipelineState] = [:]
        for blend in [SceneBlend.translucent, .additive, .opaque, .multiply] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "lumen_scene_composite_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "lumen_scene_composite_fragment")
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            blend.configure(descriptor.colorAttachments[0])
            composite[blend] = try device.makeRenderPipelineState(descriptor: descriptor)
        }
        self.composite = composite
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "lumen_scene_present_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "lumen_scene_present_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        present = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "lumen_scene_present_sharp_fragment")
        presentSharp = try device.makeRenderPipelineState(descriptor: descriptor)

        let bloom = MTLRenderPipelineDescriptor()
        bloom.vertexFunction = library.makeFunction(name: "lumen_bloom_vertex")
        bloom.fragmentFunction = library.makeFunction(name: "lumen_bloom_extract_fragment")
        bloom.colorAttachments[0].pixelFormat = .rgba16Float
        bloomExtract = try device.makeRenderPipelineState(descriptor: bloom)
        bloom.fragmentFunction = library.makeFunction(name: "lumen_bloom_blur_fragment")
        bloomBlur = try device.makeRenderPipelineState(descriptor: bloom)
        bloom.fragmentFunction = library.makeFunction(name: "lumen_bloom_composite_fragment")
        bloom.colorAttachments[0].pixelFormat = .rgba8Unorm
        bloom.colorAttachments[0].isBlendingEnabled = true
        bloom.colorAttachments[0].sourceRGBBlendFactor = .one
        bloom.colorAttachments[0].destinationRGBBlendFactor = .one
        bloom.colorAttachments[0].sourceAlphaBlendFactor = .zero
        bloom.colorAttachments[0].destinationAlphaBlendFactor = .one
        bloomComposite = try device.makeRenderPipelineState(descriptor: bloom)
    }

    private static var cached: SceneUtilityPipelines?
    private static let lock = NSLock()

    static func shared(device: MTLDevice) throws -> SceneUtilityPipelines {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let made = try SceneUtilityPipelines(device: device)
        cached = made
        return made
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct WEVertex { float4 position; float4 texcoord; float4 texcoord1; float4 texcoord2; float4 color; float4 normal; float4 tangent; uint4 indices; float4 weights; };
    struct CompositeOut { float4 position [[position]]; float2 uv; };

    vertex CompositeOut lumen_scene_composite_vertex(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]], const device WEVertex* V [[buffer(1)]]) {
        CompositeOut o;
        o.position = mvp * float4(V[vid].position.xyz, 1.0);
        o.position.z = (o.position.z + o.position.w) * 0.5;
        o.uv = V[vid].texcoord.xy;
        return o;
    }

    fragment float4 lumen_scene_composite_fragment(CompositeOut in [[stage_in]], constant float& alpha [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 c = t.sample(s, in.uv);
        c.a *= alpha;
        return c;
    }

    struct PresentOut { float4 position [[position]]; float2 uv; };

    // `rect` is the scene's placement in normalised device coordinates (x, y, width, height).
    vertex PresentOut lumen_scene_present_vertex(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        PresentOut o;
        o.position = float4(rect.x + corner.x * rect.z, rect.y + rect.w - corner.y * rect.w, 0, 1);
        o.uv = corner;
        return o;
    }

    fragment float4 lumen_scene_present_fragment(PresentOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(t.sample(s, in.uv).rgb, 1.0);
    }

    // Catmull-Rom upscaling from nine bilinear taps: much crisper edges and line art than
    // plain bilinear for about the same cost as a few texture reads.
    fragment float4 lumen_scene_present_sharp_fragment(PresentOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 size = float2(t.get_width(), t.get_height());
        float2 position = in.uv * size;
        float2 center = floor(position - 0.5) + 0.5;
        float2 f = position - center;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 offset12 = w2 / w12;
        float2 uv0 = (center - 1.0) / size;
        float2 uv3 = (center + 2.0) / size;
        float2 uv12 = (center + offset12) / size;
        float3 c = float3(0);
        c += t.sample(s, float2(uv0.x, uv0.y)).rgb * w0.x * w0.y;
        c += t.sample(s, float2(uv12.x, uv0.y)).rgb * w12.x * w0.y;
        c += t.sample(s, float2(uv3.x, uv0.y)).rgb * w3.x * w0.y;
        c += t.sample(s, float2(uv0.x, uv12.y)).rgb * w0.x * w12.y;
        c += t.sample(s, float2(uv12.x, uv12.y)).rgb * w12.x * w12.y;
        c += t.sample(s, float2(uv3.x, uv12.y)).rgb * w3.x * w12.y;
        c += t.sample(s, float2(uv0.x, uv3.y)).rgb * w0.x * w3.y;
        c += t.sample(s, float2(uv12.x, uv3.y)).rgb * w12.x * w3.y;
        c += t.sample(s, float2(uv3.x, uv3.y)).rgb * w3.x * w3.y;
        return float4(saturate(c), 1.0);
    }

    vertex PresentOut lumen_bloom_vertex(uint vid [[vertex_id]]) {
        float2 corner = float2(vid & 1, vid >> 1);
        PresentOut o;
        o.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0, 1);
        o.uv = corner;
        return o;
    }

    fragment float4 lumen_bloom_extract_fragment(PresentOut in [[stage_in]], constant float4& params [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 d = params.yz;
        float3 c = 0.25 * (
            t.sample(s, in.uv + float2(-d.x, -d.y)).rgb +
            t.sample(s, in.uv + float2( d.x, -d.y)).rgb +
            t.sample(s, in.uv + float2(-d.x,  d.y)).rgb +
            t.sample(s, in.uv + float2( d.x,  d.y)).rgb
        );
        float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
        float knee = 0.15;
        float soft = clamp(luma - params.x + knee, 0.0, 2.0 * knee);
        float contrib = max(luma - params.x, (soft * soft) / (4.0 * knee + 1e-4)) / max(luma, 1e-4);
        return float4(c * contrib, 1.0);
    }

    fragment float4 lumen_bloom_blur_fragment(PresentOut in [[stage_in]], constant float2& dir [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        const float w[5] = { 0.22702703, 0.19459459, 0.12162162, 0.05405405, 0.01621622 };
        float3 sum = t.sample(s, in.uv).rgb * w[0];
        for (int i = 1; i < 5; i++) {
            float2 o = dir * float(i) * 1.5;
            sum += (t.sample(s, in.uv + o).rgb + t.sample(s, in.uv - o).rgb) * w[i];
        }
        return float4(sum, 1.0);
    }

    fragment float4 lumen_bloom_composite_fragment(PresentOut in [[stage_in]], constant float4& tint [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(t.sample(s, in.uv).rgb * tint.rgb, 0.0);
    }
    """
}

/// A queue for one-off GPU work during loading (off the main actor).
enum SceneQueues {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [UInt64: MTLCommandQueue] = [:]

    static func queue(for device: MTLDevice) -> MTLCommandQueue? {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[device.registryID] { return queue }
        let queue = device.makeCommandQueue()
        queues[device.registryID] = queue
        return queue
    }
}

enum SceneMath {
    /// Canvas units (origin bottom-left, y up) to clip space.
    static func orthographic(canvas: SIMD2<Float>, offset: SIMD2<Float> = .zero) -> simd_float4x4 {
        let sx = 2 / max(canvas.x, 1), sy = 2 / max(canvas.y, 1)
        return simd_float4x4(columns: (
            SIMD4(sx, 0, 0, 0),
            SIMD4(0, sy, 0, 0),
            SIMD4(0, 0, -0.0001, 0),
            SIMD4(-1 - offset.x * sx, -1 - offset.y * sy, 0, 1)
        ))
    }

    /// Local-space offscreen buffer projection (Pass 0 and composition groups): maps XY from
    /// `center ± size/2` to `[-1, 1]` and scales local Z into `[-1, 1]` so puppet bones or 3D-tilted
    /// layers with non-zero Z are never clipped by Metal's `[0, 1]` depth planes.
    static func localOrthographic(center: SIMD2<Float>, size: SIMD2<Float>) -> simd_float4x4 {
        let sx = 2 / max(size.x, 1), sy = 2 / max(size.y, 1)
        return simd_float4x4(columns: (
            SIMD4(sx, 0, 0, 0),
            SIMD4(0, sy, 0, 0),
            SIMD4(0, 0, -0.0001, 0),
            SIMD4(-center.x * sx, -center.y * sy, 0, 1)
        ))
    }

    static func translation(_ offset: SIMD2<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset.x, offset.y, 0, 1)
        return matrix
    }

    /// `alignment` says which point of the layer its origin is: "top" puts the origin at the
    /// layer's top centre, so the quad hangs below it.
    static func anchorOffset(_ alignment: String?, size: SIMD2<Float>) -> SIMD2<Float> {
        guard let alignment = alignment?.lowercased(), alignment != "center" else { return .zero }
        var offset = SIMD2<Float>.zero
        if alignment.contains("left") { offset.x = size.x / 2 }
        if alignment.contains("right") { offset.x = -size.x / 2 }
        if alignment.contains("top") { offset.y = -size.y / 2 }
        if alignment.contains("bottom") { offset.y = size.y / 2 }
        return offset
    }

    static func scale(_ factors: SIMD2<Float>) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(factors.x, factors.y, 1, 1))
    }

    static func model(origin: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(origin, 1)
        let rotation = rotationZ(angles.z) * rotationY(angles.y) * rotationX(angles.x)
        let scaling = simd_float4x4(diagonal: SIMD4(scale, 1))
        return translation * rotation * scaling
    }

    static func rotationZ(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }

    static func rotationY(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }

    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }
}
