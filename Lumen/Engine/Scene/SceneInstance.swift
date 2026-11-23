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
    static func quad(halfSize: SIMD2<Float>, uv: SIMD2<Float> = SIMD2(1, 1)) -> [SceneVertex] {
        [
            SceneVertex(position: SIMD4(-halfSize.x, halfSize.y, 0, 1), texcoord: SIMD4(0, 0, 0, 0)),
            SceneVertex(position: SIMD4(-halfSize.x, -halfSize.y, 0, 1), texcoord: SIMD4(0, uv.y, 0, 0)),
            SceneVertex(position: SIMD4(halfSize.x, halfSize.y, 0, 1), texcoord: SIMD4(uv.x, 0, 0, 0)),
            SceneVertex(position: SIMD4(halfSize.x, -halfSize.y, 0, 1), texcoord: SIMD4(uv.x, uv.y, 0, 0)),
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
    /// Another layer reads this layer's composite buffer (`_rt_imageLayerComposite_<id>_a/b`).
    let isCompositeSource: Bool
    /// Optional `BLENDMODE` composite pass used when a chained layer has `colorBlendMode != 0`.
    let compositePass: PreparedPass?
    let imageExtent: SIMD2<Float>
    var bufferSize = SIMD2<Int>(1, 1)
    var buffers: [MTLTexture] = []
    var targets: [String: MTLTexture] = [:]
    let targetScales: [String: Float]

    init(object: SceneDocument.Object, size: SIMD2<Float>, base: PreparedPass, steps: [EffectStep], blend: SceneBlend,
         isPassthrough: Bool, isFullscreen: Bool, isCompositeSource: Bool = false, compositePass: PreparedPass? = nil,
         imageExtent: SIMD2<Float>, targetScales: [String: Float]) {
        self.object = object
        self.size = size
        self.base = base
        self.steps = steps
        self.blend = blend
        self.isPassthrough = isPassthrough
        self.isFullscreen = isFullscreen
        self.isCompositeSource = isCompositeSource
        self.compositePass = compositePass
        self.imageExtent = imageExtent
        self.targetScales = targetScales
        anchor = SceneMath.translation(SceneMath.anchorOffset(object.raw["alignment"] as? String, size: size))
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

/// Something the scene draws, in scene order.
enum SceneDrawable {
    case image(ImageLayer)
    case particles(ParticleLayer)
}

/// Everything needed to draw a scene frame: layers, render targets, shared pipelines.
final class SceneInstance: @unchecked Sendable {
    let document: SceneDocument
    let canvas: SIMD2<Float>
    let renderSize: SIMD2<Int>
    let drawables: [SceneDrawable]
    var layers: [ImageLayer] { drawables.compactMap { if case .image(let layer) = $0 { layer } else { nil } } }
    var particleLayers: [ParticleLayer] { drawables.compactMap { if case .particles(let layer) = $0 { layer } else { nil } } }
    let textures: SceneTextureCache
    let device: MTLDevice
    let unsupported: [String]

    private let sceneTexture: MTLTexture
    private let frameCopy: MTLTexture
    private let utility: SceneUtilityPipelines
    private var frameCopyValid = false
    private var placeholder: SceneTexture { textures.clear }
    private var indices: MTLBuffer?
    private let objects: [Int: SceneDocument.Object]
    let scripts: SceneScriptRuntime?
    private var scriptChanges: [Int: SceneScriptRuntime.Change] = [:]
    private var frameStates: [Int: SceneDocument.State] = [:]
    private var frameWorlds: [Int: simd_float4x4] = [:]
    private var compositeTextures: [Int: MTLTexture] = [:]
    private var frameTime: Float = 0
    /// Text layers whose string scripts set this frame, by object id.
    var scriptTexts: [Int: String] { scriptChanges.compactMapValues(\.text) }

    let sounds: SceneSoundPlayer?

    init(document: SceneDocument, renderSize: SIMD2<Int>, drawables: [SceneDrawable], textures: SceneTextureCache,
         utility: SceneUtilityPipelines, queue: MTLCommandQueue? = nil, unsupported: [String],
         scripts: SceneScriptRuntime? = nil, sounds: SceneSoundPlayer? = nil) throws {
        self.document = document
        self.sounds = sounds
        self.scripts = scripts
        var objects: [Int: SceneDocument.Object] = [:]
        for object in document.objects where objects[object.id] == nil { objects[object.id] = object }
        self.objects = objects
        canvas = document.canvas
        self.renderSize = renderSize
        self.drawables = drawables
        self.textures = textures
        self.utility = utility
        self.unsupported = unsupported
        device = textures.device
        sceneTexture = try Self.makeTarget(device, renderSize)
        frameCopy = try Self.makeTarget(device, renderSize)
        let scale = Float(renderSize.x) / max(canvas.x, 1)
        indices = ParticleLayer.sharedIndices(device: device)
        for layer in layers where layer.needsChain {
            let pixels = SIMD2<Int>(max(1, Int((layer.size.x * scale).rounded())), max(1, Int((layer.size.y * scale).rounded())))
            layer.bufferSize = SIMD2(min(pixels.x, 8192), min(pixels.y, 8192))
            layer.buffers = [try Self.makeTarget(device, layer.bufferSize), try Self.makeTarget(device, layer.bufferSize)]
            for (name, divisor) in layer.targetScales {
                let size = SIMD2(max(1, Int(Float(layer.bufferSize.x) / divisor)), max(1, Int(Float(layer.bufferSize.y) / divisor)))
                layer.targets[name] = try Self.makeTarget(device, size)
            }
        }
        clearTargets(on: queue)
    }

    /// New private textures hold whatever was in memory; effects that read a target before
    /// writing it (feedback trails, simulations) must start from transparent black.
    private func clearTargets(on queue: MTLCommandQueue?) {
        var targets = [sceneTexture, frameCopy]
        for layer in layers {
            targets += layer.buffers
            targets += Array(layer.targets.values)
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

    static func makeTarget(_ device: MTLDevice, _ size: SIMD2<Int>) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: max(1, size.x), height: max(1, size.y), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw SceneLoadError.unsupported("a render target this large") }
        return texture
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
    }

    /// This frame's state of an object: keyframes, then script changes, then what its
    /// parents pass down (visibility and opacity propagate unless a parent opts out).
    func state(of id: Int) -> SceneDocument.State? {
        if let cached = frameStates[id] { return cached }
        guard let object = objects[id] else { return nil }
        var state = object.state(at: frameTime)
        if let change = scriptChanges[id] {
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
            state.alpha *= parentState.alpha
        }
        frameStates[id] = state
        return state
    }

    /// World transform of an object (without its alignment offset), for its children.
    func world(of id: Int?) -> simd_float4x4 {
        guard let id else { return matrix_identity_float4x4 }
        if let cached = frameWorlds[id] { return cached }
        guard let object = objects[id], let state = state(of: id) else { return matrix_identity_float4x4 }
        frameWorlds[id] = matrix_identity_float4x4
        let parent = object.parent == id ? matrix_identity_float4x4 : world(of: object.parent)
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

    /// Draws the whole scene into `outputTexture`.
    func encode(into buffer: MTLCommandBuffer, frame: Frame) {
        frameCopyValid = false
        frameTime = frame.time
        frameStates.removeAll(keepingCapacity: true)
        frameWorlds.removeAll(keepingCapacity: true)
        compositeTextures.removeAll(keepingCapacity: true)
        if let scripts {
            scriptChanges = scripts.update(time: Double(frame.time), delta: Double(frame.delta), daytime: Double(frame.daytime),
                                           cursor: frame.pointerCanvas, cursorDown: false)
        }
        var session = SceneSession(target: sceneTexture, clear: document.clearColor)
        // Clear up front: a layer may copy the background before anything has drawn.
        _ = session.encoder(buffer)

        for drawable in drawables {
            let layer: ImageLayer
            switch drawable {
            case .image(let image):
                layer = image
            case .particles(let particles):
                guard let particleState = state(of: particles.object.id) else { continue }
                particles.parentModel = world(of: particles.object.parent)
                particles.localModel = SceneMath.model(origin: particleState.origin, angles: particleState.angles, scale: particleState.scale)
                particles.update(delta: frame.delta, pointerCanvas: frame.pointerCanvas)
                guard particleState.visible else { continue }
                if let encoder = session.encoder(buffer) {
                    frameCopyValid = false
                    encodeParticles(particles, encoder: encoder, frame: frame)
                }
                continue
            }
            if let text = layer.text, let newText = scriptChanges[layer.object.id]?.text { text.update(newText) }
            guard let objectState = state(of: layer.object.id) else { continue }
            let drawsToScene = objectState.visible && objectState.alpha > 0.001 && (!layer.isPassthrough || !layer.steps.isEmpty)
            let capturesForOthers = layer.isCompositeSource && parentVisible(of: layer.object.id)
            guard drawsToScene || capturesForOthers else { continue }
            let parentWorld = world(of: layer.object.parent)
            // Parallax moves each layer by its depth (background layers usually less than 1).
            let offset = document.parallaxEnabled ? frame.cameraOffset * layer.object.parallaxDepth : .zero
            let layerVP = SceneMath.orthographic(canvas: canvas, offset: offset)
            if layer.needsChain {
                encodeChain(layer, state: objectState, parent: parentWorld, buffer: buffer, session: &session,
                            viewProjection: layerVP, frame: frame, compositeToScene: drawsToScene)
            } else {
                let pass = layer.base
                if pass.usesFrameBuffer { session.end(); copyFrame(buffer) }
                guard let encoder = session.encoder(buffer) else { continue }
                frameCopyValid = false
                var state = drawState(frame: frame, object: objectState)
                state.model = layer.model(for: objectState, parent: parentWorld)
                state.viewProjection = layerVP
                state.targetSize = SIMD2(Float(renderSize.x), Float(renderSize.y))
                draw(pass, encoder: encoder, vertices: SceneVertex.quad(halfSize: layer.size / 2, uv: pass.spriteSheet != nil ? SIMD2(1, 1) : layer.imageExtent),
                     state: state, previous: nil, layer: layer)
            }
        }
        session.end(clearIfUnused: buffer)
    }

    private func encodeChain(_ layer: ImageLayer, state objectState: SceneDocument.State, parent: simd_float4x4, buffer: MTLCommandBuffer,
                             session: inout SceneSession, viewProjection: simd_float4x4, frame: Frame, compositeToScene: Bool) {
        let model = layer.model(for: objectState, parent: parent)
        guard layer.buffers.count == 2 else { return }
        let base = layer.base
        // The chain renders into its own buffers, so the scene's encoder has to close first.
        session.end()
        if base.usesFrameBuffer || layer.isPassthrough { copyFrame(buffer) }
        // Pass 0: the object's own material into the first buffer.
        var state = drawState(frame: frame, object: objectState)
        state.targetSize = SIMD2(Float(layer.bufferSize.x), Float(layer.bufferSize.y))
        if layer.isPassthrough {
            state.model = model
            state.viewProjection = viewProjection
        } else {
            state.model = matrix_identity_float4x4
            state.viewProjection = SceneMath.scale(SIMD2(2 / max(layer.size.x, 1), 2 / max(layer.size.y, 1)))
        }
        var current = 0
        if let encoder = beginPass(buffer, target: layer.buffers[0]) {
            let uv = base.spriteSheet != nil || layer.isPassthrough ? SIMD2<Float>(1, 1) : layer.imageExtent
            draw(base, encoder: encoder, vertices: SceneVertex.quad(halfSize: layer.size / 2, uv: uv), state: state, previous: nil, layer: layer)
            encoder.endEncoding()
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
        guard compositeToScene else { return }

        // Composite the result onto the scene with the object's transform.
        if let composite = layer.compositePass {
            if composite.usesFrameBuffer, !frameCopyValid { copyFrame(buffer) }
            guard let encoder = session.encoder(buffer) else { return }
            frameCopyValid = false
            var compState = drawState(frame: frame, object: objectState)
            // Colour, brightness and alpha were already applied in Pass 0.
            compState.color = SIMD3(1, 1, 1)
            compState.alpha = 1
            compState.brightness = 1
            compState.model = model
            compState.viewProjection = viewProjection
            compState.targetSize = SIMD2(Float(renderSize.x), Float(renderSize.y))
            draw(composite, encoder: encoder, vertices: SceneVertex.quad(halfSize: layer.size / 2),
                 state: compState, previous: layer.buffers[current], layer: layer)
            return
        }
        guard let encoder = session.encoder(buffer), let pipeline = utility.composite[layer.blend] ?? utility.composite[.translucent] else { return }
        frameCopyValid = false
        var mvp = viewProjection * model
        let vertices = SceneVertex.quad(halfSize: layer.size / 2)
        encoder.setRenderPipelineState(pipeline)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 0)
        encoder.setFragmentTexture(layer.buffers[current], index: 0)
        encoder.setFragmentSamplerState(textures.samplers.state(nearest: false, clamp: true), index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func drawState(frame: Frame, object: SceneDocument.State) -> DrawState {
        var state = DrawState()
        state.eye = SIMD3(canvas.x / 2, canvas.y / 2, 2000)
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
        return state
    }

    private func beginPass(_ buffer: MTLCommandBuffer, target: MTLTexture) -> MTLRenderCommandEncoder? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
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
                      state: DrawState, previous: MTLTexture?, layer: ImageLayer?, particleBuffer: (MTLBuffer, Int)? = nil) {
        var state = state
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
            } else if let buffer = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            }
        }
        if let (vertexBuffer, _) = particleBuffer {
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
        if let (_, quads) = particleBuffer {
            guard let indices, quads > 0 else { return }
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: quads * 6, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 0)
        } else {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// Simulated particles, drawn as quads with each system's own material.
    private func encodeParticles(_ layer: ParticleLayer, encoder: MTLRenderCommandEncoder, frame: Frame) {
        let offset = document.parallaxEnabled ? frame.cameraOffset * layer.object.parallaxDepth : .zero
        let viewProjection = SceneMath.orthographic(canvas: canvas, offset: offset)
        for system in layer.systems {
            guard case .none = system.renderer else {
                guard let buffer = layer.vertexBuffer(for: system, device: device) else { continue }
                let capacity = buffer.length / (MemoryLayout<SceneVertex>.stride * 4)
                let count = system.writeVertices(into: buffer.contents().bindMemory(to: SceneVertex.self, capacity: capacity * 4), capacity: capacity)
                guard count > 0 else { continue }
                var state = drawState(frame: frame, object: self.state(of: layer.object.id) ?? layer.object.state(at: frame.time))
                state.model = system.childKind == .independent && system !== layer.root ? layer.model * system.localTransform : layer.model
                state.viewProjection = viewProjection
                state.targetSize = SIMD2(Float(renderSize.x), Float(renderSize.y))
                // Particle colour and alpha come from the simulation, not the object.
                state.color = SIMD3(1, 1, 1)
                state.alpha = 1
                if case .trail(let length, let maxLength, let minLength) = system.renderer {
                    state.renderVar0 = SIMD4(length, maxLength, minLength, 0)
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
    private var encoder: MTLRenderCommandEncoder?
    private var cleared = false

    init(target: MTLTexture, clear: SIMD3<Float>) {
        self.target = target
        self.clear = clear
    }

    mutating func encoder(_ buffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        if let encoder { return encoder }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = cleared ? .load : .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y), blue: Double(clear.z), alpha: 1)
        cleared = true
        encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        return encoder
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

    fragment float4 lumen_scene_composite_fragment(CompositeOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return t.sample(s, in.uv);
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
