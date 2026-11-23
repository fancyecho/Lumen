import Foundation
import Metal
import simd

/// Parsed Wallpaper Engine puppet model (`.mdl`: `MDLV`, `MDLS`, `MDAT`, `MDLA`).
final class PuppetModel: @unchecked Sendable {
    struct Bone {
        let name: String
        let parent: Int
        let localRest: simd_float4x4
        let restPosition: SIMD3<Float>
        let restAngles: SIMD3<Float>
        let restScale: SIMD3<Float>
        let inverseBind: simd_float4x4
    }

    struct Attachment {
        let name: String
        let boneIndex: Int
        let localTransform: simd_float4x4
    }

    struct KeyFrame {
        var position: SIMD3<Float>
        var angles: SIMD3<Float>
        var scale: SIMD3<Float>
    }

    enum PlayMode { case loop, mirror, single }

    struct Animation {
        let id: Int
        let name: String
        let mode: PlayMode
        let fps: Float
        let frameCount: Int
        /// One frame array per bone (indexed by bone index).
        let tracks: [[KeyFrame]]
        /// Optional per-bone alpha tracks (`SKINNING_ALPHA`).
        let alphaTracks: [[Float]]?
    }

    struct Submesh {
        let id: Int
        let indexStart: Int
        let indexCount: Int
    }

    struct ClippingMask {
        let maskTextureName: String
        let targetSubmeshes: [Int]
        let maskSubmeshes: [Int]
    }

    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let isSkinned: Bool
    let bones: [Bone]
    let boneCountBucket: Int
    let attachments: [String: Attachment]
    let animations: [Int: Animation]
    let hasBoneAlpha: Bool
    let submeshes: [Submesh]
    let clippingMasks: [ClippingMask]
    let boundsMin: SIMD2<Float>
    let boundsMax: SIMD2<Float>

    var boundsCenter: SIMD2<Float> { (boundsMin + boundsMax) * 0.5 }
    var boundsSize: SIMD2<Float> { boundsMax - boundsMin }

    private init(vertexBuffer: MTLBuffer, indexBuffer: MTLBuffer, indexCount: Int, isSkinned: Bool,
                 bones: [Bone], attachments: [String: Attachment], animations: [Int: Animation],
                 submeshes: [Submesh], clippingMasks: [ClippingMask],
                 boundsMin: SIMD2<Float>, boundsMax: SIMD2<Float>) {
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indexCount
        self.isSkinned = isSkinned && !bones.isEmpty
        self.bones = bones
        // Bucket BONECOUNT so models with similar bone counts share one compiled shader variant.
        let count = max(1, bones.count)
        let buckets = [16, 32, 64, 96, 128]
        self.boneCountBucket = buckets.first { $0 >= count } ?? (((count + 15) / 16) * 16)
        self.attachments = attachments
        self.animations = animations
        self.hasBoneAlpha = animations.values.contains { $0.alphaTracks != nil }
        self.submeshes = submeshes
        self.clippingMasks = clippingMasks
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
    }

    /// Parses a Wallpaper Engine `.mdl` binary (`MDLV0016`–`MDLV0023`).
    static func parse(_ data: Data, imageExtent: SIMD2<Float>, device: MTLDevice) -> PuppetModel? {
        var reader = BinaryReader(data)
        guard let magic = reader.cString(), magic.hasPrefix("MDLV"), let version = Int(magic.dropFirst(4)) else { return nil }

        // Header: flags, unk, meshCount, material path, extra flags, optional bounding box.
        guard reader.skip(12) else { return nil }
        guard reader.cString() != nil else { return nil }
        guard reader.skip(4) else { return nil }
        if version >= 19 { guard reader.skip(24) else { return nil } }

        guard let vfmt = reader.u32(), let vbytes = reader.u32() else { return nil }
        let hasPos = (vfmt & 0x1) != 0
        let hasNormal = (vfmt & 0x2) != 0
        let hasTangent = (vfmt & 0x4) != 0
        let hasUV = (vfmt & 0x8) != 0
        let hasSkin = (vfmt & 0x0180_0000) != 0
        let stride = (hasPos ? 12 : 0) + (hasNormal ? 12 : 0) + (hasTangent ? 16 : 0) + (hasSkin ? 32 : 0) + (hasUV ? 8 : 0)
        guard stride > 0, Int(vbytes) % stride == 0 else { return nil }
        let vertexCount = Int(vbytes) / stride
        guard vertexCount > 0, reader.remaining >= Int(vbytes) else { return nil }

        var vertices = [SceneVertex]()
        vertices.reserveCapacity(vertexCount)
        var minPos = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maxPos = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)

        for _ in 0..<vertexCount {
            var v = SceneVertex(position: SIMD4(0, 0, 0, 1), texcoord: .zero)
            if hasPos, let p = reader.vec3() {
                v.position = SIMD4(p, 1)
                minPos = simd_min(minPos, SIMD2(p.x, p.y))
                maxPos = simd_max(maxPos, SIMD2(p.x, p.y))
            }
            if hasNormal, let n = reader.vec3() { v.normal = SIMD4(n, 0) }
            if hasTangent, let t = reader.vec4() { v.tangent = t }
            if hasSkin {
                guard let idx = reader.uvec4(), let w = reader.vec4() else { return nil }
                v.indices = idx
                v.weights = w
            }
            if hasUV, let uv = reader.vec2() {
                // MDL UVs are normalised to the artwork size; scale by imageExtent for block-padded `.tex`.
                v.texcoord = SIMD4(uv.x * imageExtent.x, uv.y * imageExtent.y, 0, 0)
            }
            vertices.append(v)
        }

        guard let ibytes = reader.u32(), ibytes % 6 == 0, reader.remaining >= Int(ibytes) else { return nil }
        let indexCount = Int(ibytes) / 2
        var indices = [UInt16]()
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            guard let i = reader.u16() else { return nil }
            indices.append(i)
        }

        // Post-index MDLV extras (alternate positions, submesh index ranges, embedded clipping masks).
        var submeshes: [Submesh] = []
        var clippingMasks: [ClippingMask] = []
        let nextSection = Self.findNextSection(in: data, from: reader.offset)
        if reader.offset < nextSection {
            if let hasAlt = reader.u8(), hasAlt != 0, let altCount = reader.u32() {
                for _ in 0..<altCount {
                    guard let bytes = reader.u32(), reader.skip(Int(bytes)) else { break }
                }
            }
            if reader.offset < nextSection, let hasSub = reader.u8(), hasSub != 0, let subBytes = reader.u32() {
                let count = Int(subBytes) / 16
                for _ in 0..<count {
                    guard let id = reader.u32(), reader.u32() != nil,
                          let start = reader.u32(), let len = reader.u32()
                    else { break }
                    submeshes.append(Submesh(id: Int(id), indexStart: Int(start), indexCount: Int(len)))
                }
            }
            if reader.offset < nextSection, let clipCount = reader.u32() {
                for _ in 0..<clipCount {
                    guard reader.skip(8), let maskTex = reader.cString(), reader.u32() != nil,
                          let targetCount = reader.u32()
                    else { break }
                    var targets: [Int] = []
                    for _ in 0..<targetCount { if let idx = reader.u32() { targets.append(Int(idx)) } }
                    guard let maskCount = reader.u32() else { break }
                    var masks: [Int] = []
                    for _ in 0..<maskCount { if let idx = reader.u32() { masks.append(Int(idx)) } }
                    if !maskTex.isEmpty, !targets.isEmpty, !masks.isEmpty {
                        clippingMasks.append(ClippingMask(maskTextureName: maskTex, targetSubmeshes: targets, maskSubmeshes: masks))
                    }
                }
            }
        }
        reader.offset = nextSection

        // Remaining tagged sections: MDLS (skeleton), MDAT (attachments), MDLA (animations), MDLE (extra).
        var rawBones: [(name: String, parent: Int, local: simd_float4x4)] = []
        var attachments: [String: Attachment] = [:]
        var animations: [Int: Animation] = [:]

        while reader.offset + 13 <= data.count {
            guard let tag = reader.cString(), let endOffset = reader.u32() else { break }
            let sectionEnd = min(Int(endOffset), data.count)
            if tag.hasPrefix("MDLS") {
                if let boneCount = reader.u32() {
                    rawBones.reserveCapacity(Int(boneCount))
                    for _ in 0..<boneCount {
                        guard let name = reader.cString(),
                              reader.u32() != nil,
                              let parent = reader.i32(),
                              let matBytes = reader.u32(), matBytes == 64,
                              let local = reader.mat4(),
                              reader.cString() != nil // constraint JSON
                        else { break }
                        rawBones.append((name, Int(parent), local))
                    }
                }
            } else if tag.hasPrefix("MDAT") {
                if let attCount = reader.u16() {
                    for _ in 0..<attCount {
                        guard let boneIndex = reader.u16(),
                              let name = reader.cString(),
                              let matrix = reader.mat4()
                        else { break }
                        attachments[name] = Attachment(name: name, boneIndex: Int(boneIndex), localTransform: matrix)
                    }
                }
            } else if tag.hasPrefix("MDLA"), let animVer = Int(tag.dropFirst(4)) {
                if let animCount = reader.u32() {
                    for _ in 0..<animCount {
                        guard let id = reader.i32(), reader.u32() != nil,
                              let name = reader.cString(), let modeStr = reader.cString(),
                              let fps = reader.f32(), let frameCount = reader.u32(),
                              reader.u32() != nil, let boneCount = reader.u32()
                        else { break }
                        var tracks: [[KeyFrame]] = []
                        tracks.reserveCapacity(Int(boneCount))
                        for _ in 0..<boneCount {
                            guard reader.u32() != nil, let bytes = reader.u32(), bytes % 36 == 0 else { break }
                            let count = Int(bytes) / 36
                            var frames: [KeyFrame] = []
                            frames.reserveCapacity(count)
                            for _ in 0..<count {
                                guard let p = reader.vec3(), let a = reader.vec3(), let s = reader.vec3() else { break }
                                frames.append(KeyFrame(position: p, angles: a, scale: s))
                            }
                            tracks.append(frames)
                        }
                        var alphaTracks: [[Float]]?
                        if animVer == 3 {
                            if let evCount = reader.u32() {
                                for _ in 0..<evCount { _ = reader.f32(); _ = reader.cString() }
                            }
                            _ = reader.skip(5)
                        } else {
                            _ = reader.u32()
                            if let hasAlpha = reader.u8(), hasAlpha != 0 {
                                var alphas: [[Float]] = []
                                alphas.reserveCapacity(Int(boneCount))
                                for _ in 0..<boneCount {
                                    guard reader.u32() != nil, let bytes = reader.u32(), bytes % 4 == 0 else { break }
                                    let count = Int(bytes) / 4
                                    var vals: [Float] = []
                                    vals.reserveCapacity(count)
                                    for _ in 0..<count { if let v = reader.f32() { vals.append(v) } }
                                    alphas.append(vals)
                                }
                                alphaTracks = alphas
                            }
                            _ = reader.skip(animVer == 5 ? 25 : 26)
                            if let evCount = reader.u32() {
                                for _ in 0..<evCount { _ = reader.f32(); _ = reader.cString() }
                            }
                        }
                        let mode: PlayMode = switch modeStr.lowercased() {
                        case "mirror": .mirror
                        case "single": .single
                        default: .loop
                        }
                        animations[Int(id)] = Animation(
                            id: Int(id), name: name, mode: mode, fps: max(fps, 1),
                            frameCount: max(Int(frameCount), 1), tracks: tracks, alphaTracks: alphaTracks
                        )
                    }
                }
            }
            if sectionEnd <= reader.offset { break }
            reader.offset = sectionEnd
        }

        // Precompute bind-pose world matrices, inverse bind matrices, and decomposed rest TRS.
        var bindWorld = [simd_float4x4](repeating: matrix_identity_float4x4, count: rawBones.count)
        var resolved = [Bool](repeating: false, count: rawBones.count)
        func computeBind(_ index: Int) -> simd_float4x4 {
            if resolved[index] { return bindWorld[index] }
            resolved[index] = true
            let parent = rawBones[index].parent
            let world = (parent >= 0 && parent < rawBones.count && parent != index)
                ? computeBind(parent) * rawBones[index].local
                : rawBones[index].local
            bindWorld[index] = world
            return world
        }
        var bones: [Bone] = []
        bones.reserveCapacity(rawBones.count)
        for i in 0..<rawBones.count {
            let world = computeBind(i)
            let trs = Self.decomposeTRS(rawBones[i].local)
            bones.append(Bone(
                name: rawBones[i].name, parent: rawBones[i].parent,
                localRest: rawBones[i].local,
                restPosition: trs.position, restAngles: trs.angles, restScale: trs.scale,
                inverseBind: world.inverse
            ))
        }

        // Clamp blend indices to valid bone range so a corrupted index can never read out of bounds.
        if hasSkin, !bones.isEmpty {
            let maxBone = UInt32(bones.count - 1)
            for i in 0..<vertices.count {
                vertices[i].indices = SIMD4(
                    min(vertices[i].indices.x, maxBone),
                    min(vertices[i].indices.y, maxBone),
                    min(vertices[i].indices.z, maxBone),
                    min(vertices[i].indices.w, maxBone)
                )
                let w = vertices[i].weights
                let sum = w.x + w.y + w.z + w.w
                if sum < 1e-5 { vertices[i].weights = SIMD4(1, 0, 0, 0) }
            }
        }

        guard let vertexBuffer = vertices.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }), let indexBuffer = indices.withUnsafeBytes({
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }) else { return nil }

        return PuppetModel(
            vertexBuffer: vertexBuffer, indexBuffer: indexBuffer, indexCount: indexCount,
            isSkinned: hasSkin, bones: bones, attachments: attachments, animations: animations,
            submeshes: submeshes, clippingMasks: clippingMasks,
            boundsMin: minPos, boundsMax: maxPos
        )
    }

    /// Locates the start of the next `MDLS`/`MDAT`/`MDLA`/`MDLE` tagged section.
    private static func findNextSection(in data: Data, from start: Int) -> Int {
        let count = data.count
        guard start + 9 <= count else { return count }
        return data.withUnsafeBytes { raw -> Int in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = start
            while i + 9 <= count {
                if bytes[i] == 0x4D, bytes[i + 1] == 0x44, // "MD"
                   ((bytes[i + 2] == 0x4C && (bytes[i + 3] == 0x53 || bytes[i + 3] == 0x41 || bytes[i + 3] == 0x45)) ||
                    (bytes[i + 2] == 0x41 && bytes[i + 3] == 0x54)),
                   bytes[i + 4] >= 0x30, bytes[i + 4] <= 0x39,
                   bytes[i + 8] == 0 {
                    return i
                }
                i += 1
            }
            return (count > 0 && bytes[count - 1] == 0) ? count - 1 : count
        }
    }

    /// Decomposes a column-major TRS matrix (`T * Rz * Ry * Rx * S`) into position, Euler angles and scale.
    static func decomposeTRS(_ m: simd_float4x4) -> (position: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) {
        let pos = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let c0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        var sx = simd_length(c0), sy = simd_length(c1), sz = simd_length(c2)
        if simd_dot(simd_cross(c0, c1), c2) < 0 { sx = -sx }
        let r0 = abs(sx) > 1e-6 ? c0 / sx : SIMD3(1, 0, 0)
        let r1 = abs(sy) > 1e-6 ? c1 / sy : SIMD3(0, 1, 0)
        let r2 = abs(sz) > 1e-6 ? c2 / sz : SIMD3(0, 0, 1)
        let ay = asin(min(max(-r0.z, -1), 1))
        let ax: Float, az: Float
        if abs(cos(ay)) > 1e-5 {
            ax = atan2(r1.z, r2.z)
            az = atan2(r0.y, r0.x)
        } else {
            ax = atan2(-r2.y, r1.y)
            az = 0
        }
        return (pos, SIMD3(ax, ay, az), SIMD3(sx, sy, sz))
    }
}

/// Evaluates `animationlayers` on a `PuppetModel` every frame, producing GPU skinning matrices
/// (`g_Bones`), bone alphas (`g_BonesAlpha`), and world bone transforms for child attachments.
final class PuppetAnimator {
    struct Layer {
        let animationID: Int
        let rate: Float
        let blend: Float
        let additive: Bool
        let visible: Bool
    }

    let model: PuppetModel
    let layers: [Layer]
    private(set) var skinMatrices: [simd_float4x4]
    private(set) var boneAlphas: [Float]
    private(set) var worldBones: [simd_float4x4]
    private var localPositions: [SIMD3<Float>]
    private var localAngles: [SIMD3<Float>]
    private var localScales: [SIMD3<Float>]
    private var localMatrices: [simd_float4x4]
    private var hasEvaluated = false

    init(model: PuppetModel, rawLayers: Any?, values: SceneValues) {
        self.model = model
        var parsed: [Layer] = []
        for case let entry as [String: Any] in rawLayers as? [Any] ?? [] {
            let animID = values.int(entry["animation"], default: -1)
            guard animID >= 0, model.animations[animID] != nil else { continue }
            parsed.append(Layer(
                animationID: animID,
                rate: values.float(entry["rate"], default: 1),
                blend: min(max(values.float(entry["blend"], default: 1), 0), 1),
                additive: values.bool(entry["additive"], default: false),
                visible: values.bool(entry["visible"], default: true)
            ))
        }
        self.layers = parsed
        let count = model.bones.count
        skinMatrices = Array(repeating: matrix_identity_float4x4, count: model.boneCountBucket)
        boneAlphas = Array(repeating: 1, count: model.boneCountBucket)
        worldBones = Array(repeating: matrix_identity_float4x4, count: count)
        localPositions = model.bones.map(\.restPosition)
        localAngles = model.bones.map(\.restAngles)
        localScales = model.bones.map(\.restScale)
        localMatrices = model.bones.map(\.localRest)
        evaluate(at: 0)
    }

    func evaluate(at time: Float) {
        let boneCount = model.bones.count
        guard boneCount > 0 else { return }
        let activeLayers = layers.filter { $0.visible && $0.blend > 0.0001 }
        if activeLayers.isEmpty, hasEvaluated { return }
        hasEvaluated = true

        for i in 0..<boneCount {
            let bone = model.bones[i]
            localPositions[i] = bone.restPosition
            localAngles[i] = bone.restAngles
            localScales[i] = bone.restScale
            boneAlphas[i] = 1
        }

        for layer in activeLayers {
            guard let anim = model.animations[layer.animationID] else { continue }
            let rawFrame = max(0, time * layer.rate * anim.fps)
            let maxF = Float(anim.frameCount)
            let frame: Float
            switch anim.mode {
            case .loop:
                frame = rawFrame.truncatingRemainder(dividingBy: maxF)
            case .mirror:
                let cycle = rawFrame.truncatingRemainder(dividingBy: maxF * 2)
                frame = cycle > maxF ? maxF * 2 - cycle : cycle
            case .single:
                frame = min(rawFrame, maxF)
            }
            let f0 = Int(floor(frame))
            let t = frame - Float(f0)
            let w = layer.blend
            let count = min(boneCount, anim.tracks.count)

            for i in 0..<count {
                let track = anim.tracks[i]
                guard !track.isEmpty else { continue }
                let idx0 = min(max(f0, 0), track.count - 1)
                let idx1 = min(idx0 + 1, track.count - 1)
                let k0 = track[idx0], k1 = track[idx1]
                let pos = simd_mix(k0.position, k1.position, SIMD3(repeating: t))
                let ang = k0.angles + Self.shortestAngleDelta(from: k0.angles, to: k1.angles) * t
                let scl = simd_mix(k0.scale, k1.scale, SIMD3(repeating: t))

                if layer.additive {
                    let rest = model.bones[i]
                    localPositions[i] += (pos - rest.restPosition) * w
                    localAngles[i] += Self.shortestAngleDelta(from: rest.restAngles, to: ang) * w
                    let ratio = SIMD3(
                        abs(rest.restScale.x) > 1e-5 ? scl.x / rest.restScale.x : scl.x,
                        abs(rest.restScale.y) > 1e-5 ? scl.y / rest.restScale.y : scl.y,
                        abs(rest.restScale.z) > 1e-5 ? scl.z / rest.restScale.z : scl.z
                    )
                    localScales[i] *= SIMD3(1, 1, 1) + (ratio - SIMD3(1, 1, 1)) * w
                } else {
                    localPositions[i] = simd_mix(localPositions[i], pos, SIMD3(repeating: w))
                    localAngles[i] += Self.shortestAngleDelta(from: localAngles[i], to: ang) * w
                    localScales[i] = simd_mix(localScales[i], scl, SIMD3(repeating: w))
                }

                if let alphaTracks = anim.alphaTracks, i < alphaTracks.count, !alphaTracks[i].isEmpty {
                    let at = alphaTracks[i]
                    let a0 = at[min(idx0, at.count - 1)], a1 = at[min(idx1, at.count - 1)]
                    let a = a0 + (a1 - a0) * t
                    boneAlphas[i] = layer.additive ? boneAlphas[i] * (1 + (a - 1) * w) : (boneAlphas[i] + (a - boneAlphas[i]) * w)
                }
            }
        }

        if activeLayers.isEmpty {
            for i in 0..<boneCount { localMatrices[i] = model.bones[i].localRest }
        } else {
            for i in 0..<boneCount {
                localMatrices[i] = SceneMath.model(origin: localPositions[i], angles: localAngles[i], scale: localScales[i])
            }
        }

        var computed = [Bool](repeating: false, count: boneCount)
        func worldOf(_ index: Int) -> simd_float4x4 {
            if computed[index] { return worldBones[index] }
            computed[index] = true
            let parent = model.bones[index].parent
            let w = (parent >= 0 && parent < boneCount && parent != index)
                ? worldOf(parent) * localMatrices[index]
                : localMatrices[index]
            worldBones[index] = w
            return w
        }
        for i in 0..<boneCount {
            let w = worldOf(i)
            skinMatrices[i] = w * model.bones[i].inverseBind
        }
    }

    func attachmentTransform(named name: String) -> simd_float4x4? {
        guard let att = model.attachments[name], att.boneIndex >= 0, att.boneIndex < worldBones.count else { return nil }
        return worldBones[att.boneIndex] * att.localTransform
    }

    private static func shortestAngleDelta(from a: SIMD3<Float>, to b: SIMD3<Float>) -> SIMD3<Float> {
        func wrap(_ d: Float) -> Float {
            var v = (d + .pi).truncatingRemainder(dividingBy: 2 * .pi)
            if v < 0 { v += 2 * .pi }
            return v - .pi
        }
        return SIMD3(wrap(b.x - a.x), wrap(b.y - a.y), wrap(b.z - a.z))
    }
}

/// Prepared passes for an MDL model that uses embedded clipping masks (`clippingmaskimage4` + `CLIPPINGTARGET`).
struct PuppetClipping {
    struct Entry {
        let maskPass: PreparedPass
        let maskSubmeshes: [Int]
    }

    let clippedBase: PreparedPass
    /// Maps each clipped submesh index to the mask entry index in `entries`.
    let submeshToEntry: [Int: Int]
    let entries: [Entry]
}

// MARK: - Little-endian reader

private struct BinaryReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }
    var remaining: Int { data.count - offset }

    @discardableResult
    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, offset + count <= data.count else { return false }
        offset += count
        return true
    }

    mutating func u8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        let v = data[offset]; offset += 1; return v
    }

    mutating func u16() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: v)
    }

    mutating func u32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: v)
    }

    mutating func i32() -> Int32? {
        u32().map { Int32(bitPattern: $0) }
    }

    mutating func f32() -> Float? {
        u32().map { Float(bitPattern: $0) }
    }

    mutating func vec2() -> SIMD2<Float>? {
        guard let x = f32(), let y = f32() else { return nil }
        return SIMD2(x, y)
    }

    mutating func vec3() -> SIMD3<Float>? {
        guard let x = f32(), let y = f32(), let z = f32() else { return nil }
        return SIMD3(x, y, z)
    }

    mutating func vec4() -> SIMD4<Float>? {
        guard let x = f32(), let y = f32(), let z = f32(), let w = f32() else { return nil }
        return SIMD4(x, y, z, w)
    }

    mutating func uvec4() -> SIMD4<UInt32>? {
        guard let x = u32(), let y = u32(), let z = u32(), let w = u32() else { return nil }
        return SIMD4(x, y, z, w)
    }

    mutating func mat4() -> simd_float4x4? {
        guard let c0 = vec4(), let c1 = vec4(), let c2 = vec4(), let c3 = vec4() else { return nil }
        return simd_float4x4(columns: (c0, c1, c2, c3))
    }

    mutating func cString() -> String? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[end] != 0 { end += 1 }
        guard end < data.count else { return nil }
        let str = String(decoding: data[offset..<end], as: UTF8.self)
        offset = end + 1
        return str
    }
}
