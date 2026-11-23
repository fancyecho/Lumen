import CoreText
import Foundation
import Metal
import simd

/// Builds a drawable `SceneInstance` from a Wallpaper Engine project. Runs off the main
/// thread: parsing, texture decoding and shader compilation are the slow parts.
enum SceneLoader {
    #if DEBUG
    /// Draws only these object ids; for tracking down a misbehaving layer.
    nonisolated(unsafe) static var debugLayerFilter: Set<Int>?
    #endif

    struct Request: @unchecked Sendable {
        let folder: URL
        let entry: String
        let assets: URL?
        let values: [String: PropertyValue]
        /// Pixel size of the display the scene fills.
        let displaySize: SIMD2<Float>
        let pixelBudget: Double
        let device: MTLDevice
        let queue: MTLCommandQueue
    }

    static func load(_ request: Request) throws -> SceneInstance {
        let files = try SceneFileSystem(projectFolder: request.folder, assets: request.assets)
        guard let json = files.json(request.entry) ?? files.json("scene.json") else {
            throw SceneLoadError.missingFile(request.entry)
        }
        let comboOffValues = SceneValues.comboOffValues(from: files.json("project.json"))
        let values = SceneValues(properties: request.values, comboOffValues: comboOffValues)
        let document = SceneDocument(json: json, values: values)
        let renderSize = Self.renderSize(canvas: document.canvas, display: request.displaySize, budget: request.pixelBudget)
        // Textures keep a little more detail than the render scale needs: layers are often
        // scaled up, and parallax and framing zoom in further.
        let renderScale = Float(renderSize.x) / max(document.canvas.x, 1)
        let textures = SceneTextureCache(device: request.device, files: files, detail: min(1, max(0.25, renderScale * 1.3)))
        let shaders = SceneShaderLibrary(device: request.device, files: files)
        let textScale = min(3, Float(renderSize.x) / max(document.canvas.x, 1) * 1.5)
        // Layers whose rendered composite buffer is read by another layer (clipping masks, blend frames).
        var compositeSources: Set<Int> = []
        var passthroughIDs: Set<Int> = []
        var objectsByID: [Int: SceneDocument.Object] = [:]
        for object in document.objects {
            if objectsByID[object.id] == nil { objectsByID[object.id] = object }
            if object.kind == .image, let path = object.image, let model = files.json(path),
               model["passthrough"] as? Bool == true {
                passthroughIDs.insert(object.id)
            }
            for effect in object.effects where effect.visible {
                for pass in effect.passes {
                    for case let name? in pass.textures {
                        if let sourceID = Self.compositeTargetID(name), sourceID != object.id {
                            compositeSources.insert(sourceID)
                        }
                    }
                }
            }
        }
        // Map each drawable descendant to its nearest passthrough (composelayer) ancestor so
        // grouped children render into the parent's offscreen buffer instead of directly to the scene.
        var groupOwner: [Int: Int] = [:]
        var groupParents: Set<Int> = []
        if !passthroughIDs.isEmpty {
            for object in document.objects {
                switch object.kind {
                case .image, .particle, .text, .model: break
                default: continue
                }
                var cursor = object.parent
                var visited: Set<Int> = [object.id]
                while let pid = cursor, visited.insert(pid).inserted {
                    if passthroughIDs.contains(pid) {
                        groupOwner[object.id] = pid
                        groupParents.insert(pid)
                        break
                    }
                    cursor = objectsByID[pid]?.parent
                }
            }
        }
        let builder = Builder(files: files, values: values, textures: textures, shaders: shaders,
                              assetsAvailable: request.assets != nil, textScale: textScale,
                              compositeSources: compositeSources, groupParents: groupParents)

        var models: [Int: simd_float4x4] = [:]
        var parents: [Int: simd_float4x4] = [:]
        var unsupported: [String] = []
        var objects: [SceneDocument.Object] = []
        for object in document.objects {
            #if DEBUG
            if let filter = debugLayerFilter, !filter.contains(object.id) { continue }
            #endif
            let local = SceneMath.model(origin: object.origin, angles: object.angles, scale: object.scale)
            let parentModel = object.parent.flatMap { models[$0] } ?? matrix_identity_float4x4
            models[object.id] = parentModel * local
            parents[object.id] = parentModel
            switch object.kind {
            case .image, .particle, .text, .model: objects.append(object)
            default: break
            }
            if object.kind == .model, object.effects.contains(where: \.visible) {
                unsupported.append("3D model effects")
            }
        }

        // Layers build independently; compiling their shaders on every core is what makes
        // a 40-layer scene load in a couple of seconds instead of ten.
        var built = [SceneDrawable?](repeating: nil, count: objects.count)
        var missingFiles = 0
        var failedModel = false
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: objects.count) { index in
            let object = objects[index]
            do {
                let parent = parents[object.id] ?? matrix_identity_float4x4
                var drawable: SceneDrawable?
                if object.kind == .particle {
                    if let layer = try builder.particleLayer(object) {
                        layer.parentModel = parent
                        drawable = .particles(layer)
                    }
                } else if object.kind == .text {
                    if let layer = try builder.textLayer(object) {
                        layer.parentModel = parent
                        drawable = .image(layer)
                    }
                } else if object.kind == .model {
                    drawable = .model(try builder.modelLayer(object))
                } else if let layer = try builder.imageLayer(object) {
                    layer.parentModel = parent
                    drawable = .image(layer)
                }
                lock.lock()
                built[index] = drawable
                lock.unlock()
            } catch {
                Log.engine.info("Scene layer “\(object.name, privacy: .public)” skipped: \(error.localizedDescription, privacy: .public)")
                lock.lock()
                if object.kind == .model { failedModel = true }
                if let error = error as? SceneLoadError, case .missingFile = error { missingFiles += 1 }
                lock.unlock()
            }
        }
        if failedModel { unsupported.append("3D models") }
        let drawables = built.compactMap { $0 }
        if missingFiles > 0, request.assets == nil, drawables.count < objects.count / 2 { throw SceneLoadError.noAssets }
        if drawables.isEmpty, request.assets == nil { throw SceneLoadError.noAssets }
        var imageByID: [Int: ImageLayer] = [:]
        for drawable in drawables {
            if case .image(let layer) = drawable { imageByID[layer.object.id] = layer }
        }
        var rootDrawables: [SceneDrawable] = []
        rootDrawables.reserveCapacity(drawables.count)
        for drawable in drawables {
            let id: Int = switch drawable {
            case .image(let layer): layer.object.id
            case .particles(let layer): layer.object.id
            case .model(let layer): layer.object.id
            }
            if let ownerID = groupOwner[id], let owner = imageByID[ownerID] {
                owner.children.append(drawable)
            } else {
                rootDrawables.append(drawable)
            }
        }
        textures.flushUploads(queue: request.queue)
        let utility = try SceneUtilityPipelines.shared(device: request.device)
        let scripts = Self.scripts(for: document, json: json, values: values, userProperties: request.values,
                                   storageKey: request.folder.lastPathComponent)
        let sounds = SceneSoundPlayer(document: document, files: files, values: values)
        let pointLights = Array(document.objects.lazy.compactMap { ScenePointLight(object: $0, values: values) }
            .prefix(WESceneShader.pointLightLimit))
        let modelCamera = document.isOrthographic ? nil : SceneModelCamera(json: json, values: values, canvas: document.canvas)
        return try SceneInstance(
            document: document, renderSize: renderSize, drawables: drawables, rootDrawables: rootDrawables,
            textures: textures, utility: utility, queue: request.queue,
            unsupported: Array(Set(unsupported)).sorted(), scripts: scripts,
            sounds: sounds.isEmpty ? nil : sounds, modelCamera: modelCamera, pointLights: pointLights
        )
    }

    /// Parses `_rt_imageLayerComposite_<id>_a` / `_b` into its layer id.
    static func compositeTargetID(_ name: String) -> Int? {
        guard let match = name.wholeMatch(of: /_rt_imageLayerComposite_(\d+)_[ab]/) else { return nil }
        return Int(match.1)
    }

    /// Collects every `{"script": …}` property and starts them in one runtime.
    private static func scripts(for document: SceneDocument, json: [String: Any], values: SceneValues,
                                userProperties: [String: PropertyValue], storageKey: String) -> SceneScriptRuntime? {
        let scriptable = ["visible", "alpha", "origin", "scale", "angles", "color", "text", "brightness"]
        var found: [(Int, String, [String: Any])] = []
        for object in document.objects {
            for key in scriptable {
                if let entry = object.raw[key] as? [String: Any], entry["script"] is String { found.append((object.id, key, entry)) }
            }
        }
        guard !found.isEmpty else { return nil }
        let layers = document.objects.map { object -> SceneScriptRuntime.LayerInfo in
            let text: String? = object.kind == .text ? (values.resolve(object.raw["text"]).map { "\($0)" }) : nil
            return SceneScriptRuntime.LayerInfo(
                id: object.id, name: object.name, parent: object.parent, origin: object.origin, scale: object.scale,
                angles: object.angles, alpha: object.alpha, visible: object.visible, color: object.color, text: text, size: object.size,
                animations: object.animations
            )
        }
        guard let runtime = SceneScriptRuntime(layers: layers, canvas: document.canvas, userProperties: userProperties, storageKey: storageKey) else { return nil }
        for (id, key, entry) in found {
            var scriptProperties: [String: Any] = [:]
            for (name, value) in entry["scriptproperties"] as? [String: Any] ?? [:] {
                scriptProperties[name] = values.resolve(value) ?? NSNull()
            }
            let value = values.resolve(entry["user"] != nil ? entry : entry["value"])
            runtime.addScript(layer: id, property: key, source: entry["script"] as? String ?? "", value: value, scriptProperties: scriptProperties)
        }
        runtime.start()
        return runtime
    }

    /// The scene's offscreen size: what covers the display at native pixels, but no larger than
    /// the canvas (its art has no more detail) unless that would need more than a 2× upscale,
    /// then shrunk to the pixel budget. The renderer upscales the rest with a bicubic filter
    /// (MetalFX was measured at 2–5 ms a frame on an M4, too much for an always-on wallpaper).
    static func renderSize(canvas: SIMD2<Float>, display: SIMD2<Float>, budget: Double) -> SIMD2<Int> {
        let cover = Double(max(display.x / max(canvas.x, 1), display.y / max(canvas.y, 1)))
        var scale = max(min(cover, 1), cover / 2)
        let pixels = Double(canvas.x * canvas.y) * scale * scale
        if pixels > budget { scale *= (budget / pixels).squareRoot() }
        return SIMD2(max(16, Int((Double(canvas.x) * scale).rounded())), max(16, Int((Double(canvas.y) * scale).rounded())))
    }

    // MARK: Building layers

    private struct Builder {
        let files: SceneFileSystem
        let values: SceneValues
        let textures: SceneTextureCache
        let shaders: SceneShaderLibrary
        let assetsAvailable: Bool
        let textScale: Float
        let compositeSources: Set<Int>
        let groupParents: Set<Int>

        /// Text layers draw a Core Text texture with Wallpaper Engine's image shader, so
        /// colour, opacity and effects work as on image layers.
        func textLayer(_ object: SceneDocument.Object) throws -> ImageLayer? {
            let raw = object.raw
            let text = values.resolve(raw["text"]).map { "\($0)" } ?? ""
            let pointSize = values.float(raw["pointsize"], default: 32)
            let font = SceneTextTexture.font(named: raw["font"] as? String ?? "systemfont_arial", size: CGFloat(pointSize * Self.pointScale), files: files)
            let padding = values.vec2(raw["padding"], default: SIMD2(32, 32))
            let horizontalName = (raw["horizontalalign"] as? String)?.lowercased() ?? "center"
            let verticalName = (raw["verticalalign"] as? String)?.lowercased() ?? "center"
            let horizontal: CTTextAlignment = {
                switch horizontalName {
                case "left": return .left
                case "right": return .right
                default: return .center
                }
            }()
            var background: SIMD4<Float>?
            if values.bool(raw["opaquebackground"], default: false) {
                let color = values.vec3(raw["backgroundcolor"], default: .zero) * values.float(raw["backgroundbrightness"], default: 1)
                background = SIMD4(color, 1)
            }
            let limitWidth = values.bool(raw["limitwidth"], default: false)
            let maxWidthValue = values.float(raw["maxwidth"], default: 0)
            let maxWidth: Float? = limitWidth && maxWidthValue > 0 ? maxWidthValue : nil
            let limitRows = values.bool(raw["limitrows"], default: false)
            let maxRows: Int? = limitRows ? max(1, values.int(raw["maxrows"], default: 1)) : nil
            let ellipsis = values.bool(raw["limituseellipsis"], default: false)

            // `size` is the text's own box; padding is margin around it (room for effects).
            let box: SIMD2<Float> = {
                if let size = object.size, size.x > 1, size.y > 1 { return size }
                let measured = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(NSAttributedString(
                    string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )), []).size
                return SIMD2(Float(measured.width), Float(measured.height))
            }()
            // Unwrapped text gets extra horizontal room so dynamic strings aren't clipped; wrapped
            // (`limitwidth`) text stays tight to its box so scroll/mask effects align cleanly.
            let overflow: Float = maxWidth != nil ? 0 : box.x
            let size = box + padding * 2 + SIMD2(overflow * 2, 0)
            let style = SceneTextTexture.Style(font: font, horizontal: horizontal, vertical: verticalName,
                                               padding: padding, background: background, overflow: overflow,
                                               maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis)
            let rendered = SceneTextTexture(device: textures.device, text: text, size: size, scale: textScale, style: style)
            let sceneTexture = SceneTexture(texture: rendered.texture() ?? textures.clear.texture,
                                            sampler: textures.samplers.state(nearest: false, clamp: true), dynamic: rendered)
            var steps: [EffectStep] = []
            var targetScales: [String: Float] = [:]
            for effect in object.effects where effect.visible {
                if let built = try? effectSteps(effect, ownerID: object.id) {
                    steps += built.steps
                    targetScales.merge(built.targets) { a, _ in a }
                }
            }
            let isCompositeSource = compositeSources.contains(object.id)
            let needsChain = !steps.isEmpty || isCompositeSource
            let material = MaterialPass(shader: "genericimage2", blend: .translucent, textures: [], constants: [:], combos: ["VERSION": 2])
            var baseCombos: [String: Int] = [:]
            if !needsChain, object.colorBlendMode != 0 { baseCombos["BLENDMODE"] = object.colorBlendMode }
            let base = try prepare(material, overrides: nil, combos: baseCombos, base: nil, effect: false,
                                   textureOverrides: [0: sceneTexture], ownerID: object.id)
            let compositePass = needsChain && object.colorBlendMode != 0 ? blendCompositePass(mode: object.colorBlendMode, ownerID: object.id) : nil
            // Wallpaper Engine anchors text layers by `horizontalalign` and `verticalalign` on the text box.
            let textAnchor = SIMD2<Float>(
                horizontalName == "left" ? box.x / 2 : (horizontalName == "right" ? -box.x / 2 : 0),
                verticalName == "top" ? -box.y / 2 : (verticalName == "bottom" ? box.y / 2 : 0)
            )
            let layer = ImageLayer(object: object, size: size, base: base, steps: steps, blend: .translucent,
                                   isPassthrough: false, isFullscreen: false, isCompositeSource: isCompositeSource,
                                   compositePass: compositePass, imageExtent: SIMD2(1, 1), targetScales: targetScales,
                                   anchorOverride: raw["alignment"] == nil ? textAnchor : nil)
            layer.text = rendered
            return layer
        }

        /// Wallpaper Engine lays text out at 300 dpi: one point is 300/72 canvas units.
        static let pointScale: Float = 300.0 / 72.0

        func modelLayer(_ object: SceneDocument.Object) throws -> ModelLayer {
            guard let path = object.raw["model"] as? String, let data = files.data(path) else {
                throw SceneLoadError.missingFile(object.raw["model"] as? String ?? "model")
            }
            guard let materialPath = PuppetModel.materialPath(in: data),
                  let materials = MaterialPass.load(materialPath, near: nil, files: files, values: values),
                  !materials.isEmpty
            else { throw SceneLoadError.unsupported("a 3D model without a material") }

            let passes = try materials.map { material in
                let needsDepth = material.depthTest || material.depthWrite
                let depth: MTLDepthStencilState?
                if needsDepth {
                    let descriptor = MTLDepthStencilDescriptor()
                    descriptor.depthCompareFunction = material.depthTest ? .lessEqual : .always
                    descriptor.isDepthWriteEnabled = material.depthWrite
                    guard let state = textures.device.makeDepthStencilState(descriptor: descriptor)
                    else { throw SceneLoadError.unsupported("3D depth testing") }
                    depth = state
                } else {
                    depth = nil
                }
                let draw = try prepare(material, overrides: nil, combos: [:], base: nil, effect: false,
                                       ownerID: object.id, depth: needsDepth ? .depth32Float : .invalid)
                return ModelLayer.Pass(draw: draw, depth: depth, cull: material.cullMode)
            }
            let extent: SIMD2<Float>
            if case .texture(let texture)? = passes.first?.draw.textures[0] { extent = texture.imageExtent }
            else { extent = SIMD2(1, 1) }
            guard let mesh = PuppetModel.parse(data, imageExtent: extent, device: textures.device),
                  mesh.meshCount == 1, !mesh.isSkinned else {
                throw SceneLoadError.unsupported("a skinned or multi-mesh 3D model")
            }
            return ModelLayer(object: object, mesh: mesh, passes: passes)
        }

        func imageLayer(_ object: SceneDocument.Object) throws -> ImageLayer? {
            guard let modelPath = object.image, let model = files.json(modelPath) else {
                throw SceneLoadError.missingFile(object.image ?? "model")
            }
            // Solid colour layers draw with the flat shader so the object's colour applies.
            var materialPath = model["material"] as? String
            let isSolid = model["solidlayer"] as? Bool == true
            if isSolid, files.exists("materials/util/solidlayer.json") {
                materialPath = "materials/util/solidlayer.json"
            }
            guard let materialPath,
                  let pass = MaterialPass.load(materialPath, near: nil, files: files, values: values)?.first
            else { throw SceneLoadError.missingFile(model["material"] as? String ?? "material") }

            let isFullscreen = model["fullscreen"] as? Bool ?? false
            let isPassthrough = model["passthrough"] as? Bool ?? false
            let isCompositeSource = compositeSources.contains(object.id)
            let hasGroupChildren = groupParents.contains(object.id)
            let copyBackground = values.bool(object.raw["copybackground"], default: true)

            var steps: [EffectStep] = []
            var targetScales: [String: Float] = [:]
            for effect in object.effects where effect.visible {
                do {
                    let built = try effectSteps(effect, ownerID: object.id)
                    steps += built.steps
                    targetScales.merge(built.targets) { a, _ in a }
                } catch {
                    Log.engine.info("Effect \(effect.file, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
            // A composition layer without effects copies the background and paints it back
            // unchanged; keep it when another layer samples it or when it groups child layers.
            if isPassthrough, steps.isEmpty, !isCompositeSource, !hasGroupChildren { return nil }

            // Solid layers use `flat` (which lacks BLENDMODE), and chained layers must apply
            // `colorBlendMode` at final composite rather than baking the scene into Pass 0.
            let needsChain = !steps.isEmpty || isPassthrough || isCompositeSource || (isSolid && object.colorBlendMode != 0)

            // Pre-resolve slot 0 texture so puppet mesh UVs can scale by its imageExtent.
            let slot0Texture: SceneTexture? = {
                guard let first = pass.textures.first, let name = first,
                      !name.hasPrefix("_rt_"), !name.hasPrefix("_alias_")
                else { return nil }
                return textures.texture(named: name)
            }()

            var puppetModel: PuppetModel?
            if let puppetPath = model["puppet"] as? String, let data = files.data(puppetPath) {
                puppetModel = PuppetModel.parse(data, imageExtent: slot0Texture?.imageExtent ?? SIMD2(1, 1), device: textures.device)
            }

            var skinCombos: [String: Int] = [:]
            if let puppetModel, puppetModel.isSkinned {
                skinCombos["SKINNING"] = 1
                skinCombos["BONECOUNT"] = puppetModel.boneCountBucket
                if puppetModel.hasBoneAlpha { skinCombos["SKINNING_ALPHA"] = 1 }
            }

            // The base pass: the object's own material.
            var baseCombos = skinCombos
            if !needsChain, object.colorBlendMode != 0 { baseCombos["BLENDMODE"] = object.colorBlendMode }
            let base = try prepare(pass, overrides: nil, combos: baseCombos, base: nil, effect: false, ownerID: object.id)
            let compositePass = needsChain && object.colorBlendMode != 0 ? blendCompositePass(mode: object.colorBlendMode, ownerID: object.id) : nil

            let mainTexture: SceneTexture? = {
                if case .texture(let texture)? = base.textures[0] { return texture }
                return slot0Texture
            }()
            var size = object.size ?? mainTexture?.imageSize ?? SIMD2(Float(model["width"] as? Double ?? 0), Float(model["height"] as? Double ?? 0))
            if isFullscreen || size.x <= 0 || size.y <= 0 {
                size = SIMD2(max(size.x, 1), max(size.y, 1))
            }

            let puppet = puppetModel.map { PuppetAnimator(model: $0, rawLayers: object.raw["animationlayers"], values: values) }
            let puppetClipping: PuppetClipping? = {
                guard let puppetModel, !puppetModel.clippingMasks.isEmpty, !puppetModel.submeshes.isEmpty,
                      let mainTexture
                else { return nil }
                return buildPuppetClipping(model: puppetModel, basePass: pass, baseCombos: baseCombos,
                                           skinCombos: skinCombos, mainTexture: mainTexture, ownerID: object.id)
            }()

            var chainCenter = SIMD2<Float>.zero
            var chainSize = size
            if let puppetModel, !isPassthrough, !isFullscreen {
                let bSize = puppetModel.boundsSize
                let bCenter = puppetModel.boundsCenter
                if bSize.x > 1, bSize.y > 1 {
                    if abs(bCenter.x) < size.x * 0.1 && abs(bCenter.y) < size.y * 0.1 {
                        let halfExtent = simd_max(simd_abs(puppetModel.boundsMin), simd_abs(puppetModel.boundsMax))
                        chainSize = simd_max(size, halfExtent * 2)
                    } else {
                        // Off-center PSD-imported puppet: centre the chain buffer on the mesh with sway margin.
                        chainCenter = bCenter
                        chainSize = simd_max(bSize * 1.15, SIMD2(16, 16))
                    }
                }
            }

            return ImageLayer(
                object: object, size: size, base: base, steps: steps, blend: pass.blend,
                isPassthrough: isPassthrough, isFullscreen: isFullscreen, copyBackground: copyBackground,
                isCompositeSource: isCompositeSource, compositePass: compositePass,
                imageExtent: mainTexture?.imageExtent ?? SIMD2(1, 1), targetScales: targetScales,
                puppet: puppet, puppetClipping: puppetClipping, chainCenter: chainCenter, chainSize: chainSize
            )
        }

        /// Builds `clippingmaskimage4` mask passes and a `CLIPPINGTARGET` base pass for MDL clipping masks.
        private func buildPuppetClipping(model: PuppetModel, basePass: MaterialPass, baseCombos: [String: Int],
                                         skinCombos: [String: Int], mainTexture: SceneTexture, ownerID: Int) -> PuppetClipping? {
            var clippedCombos = baseCombos
            clippedCombos["CLIPPINGUVS"] = 1
            clippedCombos["CLIPPINGTARGET"] = 1
            guard let clippedBase = try? prepare(basePass, overrides: nil, combos: clippedCombos, base: nil,
                                                 effect: false, binds: [8: "_clippingMask"], ownerID: ownerID)
            else { return nil }

            struct MaskKey: Hashable { let texture: String; let submeshes: [Int] }
            var keyToIndex: [MaskKey: Int] = [:]
            var entries: [PuppetClipping.Entry] = []
            var submeshToEntry: [Int: Int] = [:]

            for spec in model.clippingMasks {
                let key = MaskKey(texture: spec.maskTextureName, submeshes: spec.maskSubmeshes)
                let entryIndex: Int
                if let existing = keyToIndex[key] {
                    entryIndex = existing
                } else {
                    guard let maskTexture = textures.texture(named: spec.maskTextureName) else { continue }
                    let maskMaterial = MaterialPass(shader: "clippingmaskimage4", blend: .max, textures: [], constants: [:], combos: [:])
                    guard let maskPass = try? prepare(maskMaterial, overrides: nil, combos: skinCombos, base: nil,
                                                      effect: false, textureOverrides: [0: mainTexture, 1: maskTexture], ownerID: ownerID)
                    else { continue }
                    entryIndex = entries.count
                    entries.append(PuppetClipping.Entry(maskPass: maskPass, maskSubmeshes: spec.maskSubmeshes))
                    keyToIndex[key] = entryIndex
                }
                for targetSubmesh in spec.targetSubmeshes {
                    submeshToEntry[targetSubmesh] = entryIndex
                }
            }
            guard !entries.isEmpty, !submeshToEntry.isEmpty else { return nil }
            return PuppetClipping(clippedBase: clippedBase, submeshToEntry: submeshToEntry, entries: entries)
        }

        /// Final composite pass for chained layers that use Wallpaper Engine's `colorBlendMode`.
        private func blendCompositePass(mode: Int, ownerID: Int) -> PreparedPass? {
            let material = MaterialPass(
                shader: "genericimage4",
                blend: .opaque,
                textures: [],
                constants: [:],
                combos: ["BLENDMODE": mode, "LIGHTING": 0, "REFLECTION": 0, "FOG": 0, "VERSION": 2]
            )
            return try? prepare(material, overrides: nil, combos: [:], base: nil, effect: false,
                                binds: [0: "previous"], ownerID: ownerID)
        }

        func particleLayer(_ object: SceneDocument.Object) throws -> ParticleLayer? {
            guard let path = object.particle else { return nil }
            let overrides = ParticleSystem.Overrides(object.raw["instanceoverride"] as? [String: Any], values: values)
            guard let root = try particleSystem(path, overrides: overrides, kind: .independent, transform: matrix_identity_float4x4,
                                                maxCount: nil, seed: UInt64(truncatingIfNeeded: object.id &* 7919), depth: 0)
            else { return nil }
            let localInverse = SceneMath.model(origin: object.origin, angles: object.angles, scale: object.scale).inverse
            root.prewarm(values.float((files.json(path))?["starttime"], default: 0), worldToLocal: localInverse)
            return ParticleLayer(object: object, root: root)
        }

        private func particleSystem(_ path: String, overrides: ParticleSystem.Overrides, kind: ParticleSystem.ChildKind,
                                    transform: simd_float4x4, maxCount: Int?, seed: UInt64, depth: Int) throws -> ParticleSystem? {
            guard depth < 4 else { return nil }
            guard let json = files.json(path) else { throw SceneLoadError.missingFile(path) }
            guard let materialPath = json["material"] as? String,
                  let material = MaterialPass.load(materialPath, near: nil, files: files, values: values)?.first
            else { throw SceneLoadError.missingFile(json["material"] as? String ?? "particle material") }
            let rendererName = ((json["renderer"] as? [Any])?.first as? [String: Any])?["name"] as? String
            var combos = ["THICKFORMAT": 1]
            if rendererName == "spritetrail" || rendererName == "ropetrail" || rendererName == "rope" {
                combos["TRAILRENDERER"] = 1
            }
            let pass = try prepare(material, overrides: nil, combos: combos, base: nil, effect: false)
            let system = ParticleSystem(json: json, pass: pass, values: values, overrides: overrides, childKind: kind,
                                        localTransform: transform, childMaxCount: maxCount, seed: seed,
                                        applyControlPointOverrides: depth == 0)
            for (index, raw) in (json["children"] as? [Any] ?? []).enumerated() {
                guard let child = raw as? [String: Any], let name = child["name"] as? String else { continue }
                let childKind: ParticleSystem.ChildKind
                switch child["type"] as? String {
                case "eventfollow": childKind = .follow
                case "eventdeath": childKind = .death
                case "eventspawn": childKind = .spawn
                default: childKind = .independent
                }
                let local = SceneMath.model(
                    origin: values.vec3(child["origin"], default: .zero),
                    angles: values.vec3(child["angles"], default: .zero),
                    scale: values.vec3(child["scale"], default: SIMD3(1, 1, 1))
                )
                let childMax = (child["maxcount"] as? NSNumber)?.intValue
                do {
                    if let built = try particleSystem(name, overrides: overrides, kind: childKind, transform: local,
                                                      maxCount: childMax, seed: seed &+ UInt64(index + 1) &* 104_729, depth: depth + 1) {
                        system.children.append(built)
                    }
                } catch {
                    Log.engine.info("Particle child \(name, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
            return system
        }

        func effectSteps(_ effect: SceneDocument.Effect, ownerID: Int) throws -> (steps: [EffectStep], targets: [String: Float]) {
            guard let json = files.json(effect.file) else { throw SceneLoadError.missingFile(effect.file) }
            let base = (effect.file as NSString).deletingLastPathComponent
            // Render targets are named per effect; prefix them so two effects can't collide.
            let prefix = "\(effect.file)#"
            var targets: [String: Float] = [:]
            for case let fbo as [String: Any] in json["fbos"] as? [Any] ?? [] {
                guard let name = fbo["name"] as? String else { continue }
                targets[prefix + name] = max(1, Float((fbo["scale"] as? NSNumber)?.doubleValue ?? 1))
            }
            var steps: [EffectStep] = []
            let passes = json["passes"] as? [Any] ?? []
            for (index, raw) in passes.enumerated() {
                guard let passJSON = raw as? [String: Any] else { continue }
                let target = (passJSON["target"] as? String).map { prefix + $0 }
                if let command = passJSON["command"] as? String, command == "copy" {
                    let source = passJSON["source"] as? String ?? "previous"
                    steps.append(EffectStep(kind: .copy(source: source == "previous" ? source : prefix + source, target: target ?? "previous"), target: nil))
                    continue
                }
                guard let materialPath = passJSON["material"] as? String,
                      let material = MaterialPass.load(materialPath, near: base, files: files, values: values)?.first
                else { throw SceneLoadError.missingFile(passJSON["material"] as? String ?? "effect material") }
                let override = index < effect.passes.count ? effect.passes[index] : nil
                var binds: [Int: String] = [:]
                for case let bind as [String: Any] in passJSON["bind"] as? [Any] ?? [] {
                    guard let name = bind["name"] as? String, let slot = (bind["index"] as? NSNumber)?.intValue else { continue }
                    binds[slot] = name == "previous" ? name : prefix + name
                }
                let pass = try prepare(material, overrides: override, combos: [:], base: base, effect: true, binds: binds, ownerID: ownerID)
                steps.append(EffectStep(kind: .draw(pass), target: target))
            }
            return (steps, targets)
        }

        /// Resolves textures and combos for a material pass and compiles it.
        func prepare(_ material: MaterialPass, overrides: SceneDocument.PassOverride?, combos extra: [String: Int],
                     base: String?, effect: Bool, binds: [Int: String] = [:], textureOverrides: [Int: SceneTexture] = [:],
                     ownerID: Int = -1, depth: MTLPixelFormat = .invalid) throws -> PreparedPass {
            let source = try shaders.source(for: material.shader, near: base)
            let samplerDefaults = WEShaderTranslator.textureDefaults(in: source.flattened)
            let samplerCombos = WEShaderTranslator.textureCombos(in: source.flattened)

            // Explicit textures: the instance's overrides on top of the material's own.
            var names: [Int: String] = [:]
            for (slot, name) in material.textures.enumerated() { if let name { names[slot] = name } }
            for (slot, name) in (overrides?.textures ?? []).enumerated() { if let name { names[slot] = name } }

            var sources: [Int: TextureSource] = [:]
            var combos = WEShaderTranslator.comboDefaults(in: source.flattened)
            combos.merge(material.combos) { _, new in new }
            combos.merge(overrides?.combos ?? [:]) { _, new in new }
            combos.merge(extra) { _, new in new }

            for slot in 0..<16 {
                var resolved: TextureSource?
                if let texture = textureOverrides[slot] {
                    resolved = .texture(texture)
                } else if let bind = binds[slot] {
                    if bind == "previous" { resolved = .previous }
                    else if bind == "_clippingMask" { resolved = .clippingMask }
                    else { resolved = .named(bind) }
                } else if let name = names[slot] {
                    resolved = textureSource(name, ownerID: ownerID)
                    if resolved != nil, let combo = samplerCombos[slot] { combos[combo] = 1 }
                } else if effect, slot == 0 {
                    resolved = .previous
                } else if let fallback = samplerDefaults[slot] {
                    resolved = textureSource(fallback, ownerID: ownerID)
                }
                guard let resolved else { continue }
                sources[slot] = resolved
                // Only one- and two-channel textures change how shaders read them; leaving other
                // formats out keeps one compiled variant for every RGBA or DXT texture.
                if case .texture(let texture) = resolved, texture.format == .r8 || texture.format == .rg88 {
                    combos["TEX\(slot)FORMAT"] = texture.formatCode
                }
            }
            var sheet: SceneTexture?
            if case .texture(let texture)? = sources[0], texture.isAnimated {
                sheet = texture
                combos["SPRITESHEET"] = 1
            }

            let program = try shaders.program(source, combos: combos)
            // Effect passes write a whole buffer; only the base and final draws blend.
            let pipeline = try program.pipeline(blend: effect ? .opaque : material.blend, depth: depth)
            let constants = [overrides?.constants ?? [:], material.constants]
            let uniforms = UniformBlock(program: program.info, constants: constants, values: values, isEffect: effect)
            return PreparedPass(program: program, pipeline: pipeline, uniforms: uniforms, textures: sources, spriteSheet: sheet)
        }

        private func textureSource(_ name: String, ownerID: Int) -> TextureSource? {
            if name.hasPrefix("_rt_FullFrameBuffer") || name == "_rt_MipMappedFrameBuffer" { return .frameBuffer }
            if let sourceID = SceneLoader.compositeTargetID(name) {
                return sourceID == ownerID ? .previous : .layerComposite(sourceID)
            }
            if name.hasPrefix("_rt_") || name.hasPrefix("_alias_") { return nil }
            return textures.texture(named: name).map { .texture($0) }
        }
    }
}

private extension SceneTextureCache {
    func clearTexture() -> SceneTexture { clear }
}

extension WETexture.Format {
    /// Value for the `TEXnFORMAT` combos in Wallpaper Engine's `common_fragment.h`.
    var code: Int { rawValue }
}

extension SceneTexture {
    var formatCode: Int { format.code }
}
