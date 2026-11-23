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
        let values = SceneValues(properties: request.values)
        let document = SceneDocument(json: json, values: values)
        let renderSize = Self.renderSize(canvas: document.canvas, display: request.displaySize, budget: request.pixelBudget)
        let maxDimension = min(8192, max(2048, Int(Float(max(renderSize.x, renderSize.y)) * 1.6)))

        let textures = SceneTextureCache(device: request.device, files: files, maxDimension: maxDimension)
        let shaders = SceneShaderLibrary(device: request.device, files: files)
        let textScale = min(3, Float(renderSize.x) / max(document.canvas.x, 1) * 1.5)
        let builder = Builder(files: files, values: values, textures: textures, shaders: shaders,
                              assetsAvailable: request.assets != nil, textScale: textScale)

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
            case .image, .particle, .text: objects.append(object)
            case .model: unsupported.append("3D models")
            default: break
            }
        }

        // Layers build independently; compiling their shaders on every core is what makes
        // a 40-layer scene load in a couple of seconds instead of ten.
        var built = [SceneDrawable?](repeating: nil, count: objects.count)
        var missingFiles = 0
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
                } else if let layer = try builder.imageLayer(object) {
                    layer.parentModel = parent
                    drawable = .image(layer)
                }
                lock.lock()
                built[index] = drawable
                lock.unlock()
            } catch {
                Log.engine.info("Scene layer “\(object.name, privacy: .public)” skipped: \(error.localizedDescription, privacy: .public)")
                if (error as? SceneLoadError).map({ if case .missingFile = $0 { return true } else { return false } }) == true {
                    lock.lock()
                    missingFiles += 1
                    lock.unlock()
                }
            }
        }
        let drawables = built.compactMap { $0 }
        if missingFiles > 0, request.assets == nil, drawables.count < objects.count / 2 { throw SceneLoadError.noAssets }
        if drawables.isEmpty, request.assets == nil { throw SceneLoadError.noAssets }
        textures.flushUploads(queue: request.queue)
        let utility = try SceneUtilityPipelines.shared(device: request.device)
        let scripts = Self.scripts(for: document, json: json, values: values, userProperties: request.values,
                                   storageKey: request.folder.lastPathComponent)
        let sounds = SceneSoundPlayer(document: document, files: files, values: values)
        return try SceneInstance(
            document: document, renderSize: renderSize, drawables: drawables, textures: textures,
            utility: utility, unsupported: Array(Set(unsupported)).sorted(), scripts: scripts,
            sounds: sounds.isEmpty ? nil : sounds
        )
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
                angles: object.angles, alpha: object.alpha, visible: object.visible, color: object.color, text: text, size: object.size
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

    /// The scene renders at the canvas aspect, at most as large as the part shown on the
    /// display (fill), and within the pixel budget; the presenter scales it up.
    static func renderSize(canvas: SIMD2<Float>, display: SIMD2<Float>, budget: Double) -> SIMD2<Int> {
        let cover = max(display.x / max(canvas.x, 1), display.y / max(canvas.y, 1))
        var scale = min(Double(cover), 1.5)
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

        /// Text layers draw a Core Text texture with Wallpaper Engine's image shader, so
        /// colour, opacity and effects work as on image layers.
        func textLayer(_ object: SceneDocument.Object) throws -> ImageLayer? {
            let raw = object.raw
            let text = values.resolve(raw["text"]).map { "\($0)" } ?? ""
            let pointSize = values.float(raw["pointsize"], default: 32)
            let font = SceneTextTexture.font(named: raw["font"] as? String ?? "systemfont_arial", size: CGFloat(pointSize * Self.pointScale), files: files)
            let padding = values.vec2(raw["padding"], default: SIMD2(32, 32))
            let horizontal: CTTextAlignment = {
                switch raw["horizontalalign"] as? String {
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
            // `size` is the text's own box; padding is margin around it (room for effects).
            let box: SIMD2<Float> = {
                if let size = object.size, size.x > 1, size.y > 1 { return size }
                let measured = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(NSAttributedString(
                    string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )), []).size
                return SIMD2(Float(measured.width), Float(measured.height))
            }()
            let overflow = box.x
            let size = box + padding * 2 + SIMD2(overflow * 2, 0)
            let style = SceneTextTexture.Style(font: font, horizontal: horizontal, vertical: raw["verticalalign"] as? String ?? "center",
                                               padding: padding, background: background, overflow: overflow)
            let rendered = SceneTextTexture(device: textures.device, text: text, size: size, scale: textScale, style: style)
            let sceneTexture = SceneTexture(texture: rendered.texture() ?? textures.clear.texture,
                                            sampler: textures.samplers.state(nearest: false, clamp: true), dynamic: rendered)
            let material = MaterialPass(shader: "genericimage2", blend: .translucent, textures: [], constants: [:], combos: ["VERSION": 2])
            let base = try prepare(material, overrides: nil, combos: [:], base: nil, effect: false, textureOverrides: [0: sceneTexture])
            var steps: [EffectStep] = []
            var targetScales: [String: Float] = [:]
            for effect in object.effects where effect.visible {
                if let built = try? effectSteps(effect) {
                    steps += built.steps
                    targetScales.merge(built.targets) { a, _ in a }
                }
            }
            let layer = ImageLayer(object: object, size: size, base: base, steps: steps, blend: .translucent,
                                   isPassthrough: false, isFullscreen: false, imageExtent: SIMD2(1, 1), targetScales: targetScales)
            layer.text = rendered
            return layer
        }

        /// Wallpaper Engine lays text out at 300 dpi: one point is 300/72 canvas units.
        static let pointScale: Float = 300.0 / 72.0

        func imageLayer(_ object: SceneDocument.Object) throws -> ImageLayer? {
            guard let modelPath = object.image, let model = files.json(modelPath) else {
                throw SceneLoadError.missingFile(object.image ?? "model")
            }
            // Solid colour layers draw with the flat shader so the object's colour applies.
            var materialPath = model["material"] as? String
            if model["solidlayer"] as? Bool == true, files.exists("materials/util/solidlayer.json") {
                materialPath = "materials/util/solidlayer.json"
            }
            guard let materialPath,
                  let pass = MaterialPass.load(materialPath, near: nil, files: files, values: values)?.first
            else { throw SceneLoadError.missingFile(model["material"] as? String ?? "material") }

            let isFullscreen = model["fullscreen"] as? Bool ?? false
            let isPassthrough = model["passthrough"] as? Bool ?? false

            // The base pass: the object's own material.
            var baseCombos: [String: Int] = [:]
            if object.colorBlendMode != 0 { baseCombos["BLENDMODE"] = object.colorBlendMode }
            let base = try prepare(pass, overrides: nil, combos: baseCombos, base: nil, effect: false)

            let mainTexture: SceneTexture? = {
                if case .texture(let texture)? = base.textures[0] { return texture }
                return nil
            }()
            var size = object.size ?? mainTexture?.imageSize ?? SIMD2(Float(model["width"] as? Double ?? 0), Float(model["height"] as? Double ?? 0))
            if isFullscreen || size.x <= 0 || size.y <= 0 {
                size = SIMD2(max(size.x, 1), max(size.y, 1))
            }

            var steps: [EffectStep] = []
            var targetScales: [String: Float] = [:]
            for effect in object.effects where effect.visible {
                do {
                    let built = try effectSteps(effect)
                    steps += built.steps
                    targetScales.merge(built.targets) { a, _ in a }
                } catch {
                    Log.engine.info("Effect \(effect.file, privacy: .public) skipped: \(error.localizedDescription, privacy: .public)")
                }
            }
            // A composition layer without effects copies the background and paints it back
            // unchanged; Wallpaper Engine projects use them as group markers.
            if isPassthrough, steps.isEmpty { return nil }
            return ImageLayer(
                object: object, size: size, base: base, steps: steps, blend: pass.blend,
                isPassthrough: isPassthrough, isFullscreen: isFullscreen,
                imageExtent: mainTexture?.imageExtent ?? SIMD2(1, 1), targetScales: targetScales
            )
        }

        func particleLayer(_ object: SceneDocument.Object) throws -> ParticleLayer? {
            guard let path = object.particle else { return nil }
            let overrides = ParticleSystem.Overrides(object.raw["instanceoverride"] as? [String: Any], values: values)
            guard let root = try particleSystem(path, overrides: overrides, kind: .independent, transform: matrix_identity_float4x4,
                                                maxCount: nil, seed: UInt64(truncatingIfNeeded: object.id &* 7919), depth: 0)
            else { return nil }
            root.prewarm(values.float((files.json(path))?["starttime"], default: 0))
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
            if rendererName == "spritetrail" { combos["TRAILRENDERER"] = 1 }
            let pass = try prepare(material, overrides: nil, combos: combos, base: nil, effect: false)
            let system = ParticleSystem(json: json, pass: pass, values: values, overrides: overrides, childKind: kind,
                                        localTransform: transform, childMaxCount: maxCount, seed: seed)
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

        func effectSteps(_ effect: SceneDocument.Effect) throws -> (steps: [EffectStep], targets: [String: Float]) {
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
                let pass = try prepare(material, overrides: override, combos: [:], base: base, effect: true, binds: binds)
                steps.append(EffectStep(kind: .draw(pass), target: target))
            }
            return (steps, targets)
        }

        /// Resolves textures and combos for a material pass and compiles it.
        func prepare(_ material: MaterialPass, overrides: SceneDocument.PassOverride?, combos extra: [String: Int],
                     base: String?, effect: Bool, binds: [Int: String] = [:], textureOverrides: [Int: SceneTexture] = [:]) throws -> PreparedPass {
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
                    resolved = bind == "previous" ? .previous : .named(bind)
                } else if let name = names[slot] {
                    resolved = textureSource(name)
                    if resolved != nil, let combo = samplerCombos[slot] { combos[combo] = 1 }
                } else if effect, slot == 0 {
                    resolved = .previous
                } else if let fallback = samplerDefaults[slot] {
                    resolved = textureSource(fallback)
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
            let pipeline = try program.pipeline(blend: effect ? .opaque : material.blend)
            let constants = [overrides?.constants ?? [:], material.constants]
            let uniforms = UniformBlock(program: program.info, constants: constants, values: values)
            return PreparedPass(program: program, pipeline: pipeline, uniforms: uniforms, textures: sources, spriteSheet: sheet)
        }

        private func textureSource(_ name: String) -> TextureSource? {
            if name.hasPrefix("_rt_FullFrameBuffer") || name == "_rt_MipMappedFrameBuffer" { return .frameBuffer }
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
