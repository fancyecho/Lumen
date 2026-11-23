import Foundation
import Metal
import simd

/// A Wallpaper Engine particle system (`particles/*.json`), simulated on the CPU and drawn
/// with Wallpaper Engine's own `genericparticle` shader as camera-facing quads.
final class ParticleSystem {
    struct Emitter {
        enum Shape { case sphere, box }
        var shape: Shape
        var origin: SIMD3<Float>
        var distanceMin: SIMD3<Float>
        var distanceMax: SIMD3<Float>
        var directions: SIMD3<Float>
        var sign: SIMD3<Float>
        var rate: Float
        var instantaneous: Int
        var speed: ClosedRange<Float>
        var duration: Float
    }

    enum Initializer {
        case lifetime(ClosedRange<Float>, Float)
        case size(ClosedRange<Float>, Float)
        case velocity(SIMD3<Float>, SIMD3<Float>)
        case color(SIMD3<Float>, SIMD3<Float>)
        case alpha(ClosedRange<Float>)
        case rotation(SIMD3<Float>, SIMD3<Float>)
        case angularVelocity(SIMD3<Float>, SIMD3<Float>)
        case turbulentVelocity(speed: ClosedRange<Float>, scale: Float, offset: Float)
        case positionOffset(Float)
    }

    enum Operator {
        case movement(gravity: SIMD3<Float>, drag: Float)
        case angularMovement(force: SIMD3<Float>, drag: Float)
        case alphaFade(fadeIn: Float, fadeOut: Float)
        case alphaChange(start: Float, end: Float, from: Float, to: Float)
        case sizeChange(start: Float, end: Float, from: Float, to: Float)
        case colorChange(start: Float, end: Float, from: SIMD3<Float>, to: SIMD3<Float>)
        case oscillateAlpha(frequency: ClosedRange<Float>, scale: ClosedRange<Float>)
        case oscillateSize(frequency: ClosedRange<Float>, scale: ClosedRange<Float>)
        case oscillatePosition(frequency: ClosedRange<Float>, scale: ClosedRange<Float>, mask: SIMD3<Float>)
        case turbulence(speed: ClosedRange<Float>, scale: Float, timescale: Float, mask: SIMD3<Float>)
        case vortex(offset: SIMD3<Float>, axis: SIMD3<Float>, inner: Float, outer: Float, speedInner: Float, speedOuter: Float)
        case attract(controlPoint: Int, origin: SIMD3<Float>, scale: Float, threshold: Float)
    }

    enum Renderer {
        case sprite
        case trail(length: Float, maxLength: Float, minLength: Float)
        case none
    }

    /// How children attach to their parent system.
    enum ChildKind { case independent, follow, death, spawn }

    struct Particle {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var rotation: SIMD3<Float>
        var angularVelocity: SIMD3<Float>
        var color: SIMD3<Float>
        var alpha: Float
        var size: Float
        var age: Float
        var lifetime: Float
        var random: SIMD4<Float>
        var offset = SIMD3<Float>.zero
        var frame: Float = 0
    }

    let pass: PreparedPass
    let maxCount: Int
    let renderer: Renderer
    let childKind: ChildKind
    let localTransform: simd_float4x4
    private(set) var particles: [Particle] = []
    var children: [ParticleSystem] = []

    private let emitters: [Emitter]
    private let initializers: [Initializer]
    private let operators: [Operator]
    private let mouseControlPoints: Set<Int>
    private let controlPointOffsets: [Int: SIMD3<Float>]
    private let sequenceMultiplier: Float
    private let randomFrame: Bool
    private let spriteFrames: Int
    private let overrides: Overrides
    private var accumulators: [Float]
    private var emitted = false
    private var clock: Float = 0
    private var rng: SplitMix

    /// `instanceoverride` multipliers from the scene object.
    struct Overrides {
        var count: Float = 1
        var rate: Float = 1
        var speed: Float = 1
        var size: Float = 1
        var lifetime: Float = 1
        var alpha: Float = 1
        var color = SIMD3<Float>(1, 1, 1)

        init() {}

        init(_ raw: [String: Any]?, values: SceneValues) {
            guard let raw else { return }
            count = values.float(raw["count"], default: 1)
            rate = values.float(raw["rate"], default: 1)
            speed = values.float(raw["speed"], default: 1)
            size = values.float(raw["size"], default: 1)
            lifetime = values.float(raw["lifetime"], default: 1)
            alpha = values.float(raw["alpha"], default: 1)
            if raw["colorn"] != nil {
                color = values.vec3(raw["colorn"], default: SIMD3(1, 1, 1))
            } else if raw["color"] != nil {
                color = values.vec3(raw["color"], default: SIMD3(255, 255, 255)) / 255
            }
            color *= values.float(raw["brightness"], default: 1)
        }
    }

    init(json: [String: Any], pass: PreparedPass, values: SceneValues, overrides: Overrides,
         childKind: ChildKind, localTransform: simd_float4x4, childMaxCount: Int?, seed: UInt64) {
        self.pass = pass
        self.overrides = overrides
        self.childKind = childKind
        self.localTransform = localTransform
        let baseCount = childMaxCount ?? values.int(json["maxcount"], default: 100)
        maxCount = max(1, min(20_000, Int((Float(baseCount) * overrides.count).rounded())))
        sequenceMultiplier = values.float(json["sequencemultiplier"], default: 1)
        randomFrame = (json["animationmode"] as? String) == "randomframe"
        spriteFrames = pass.spriteSheet?.frames.count ?? 0
        rng = SplitMix(seed: seed)

        var emitters: [Emitter] = []
        for case let raw as [String: Any] in json["emitter"] as? [Any] ?? [] {
            let shape: Emitter.Shape = (raw["name"] as? String) == "boxrandom" ? .box : .sphere
            emitters.append(Emitter(
                shape: shape,
                origin: values.vec3(raw["origin"], default: .zero),
                distanceMin: values.vec3(raw["distancemin"], default: .zero),
                distanceMax: values.vec3(raw["distancemax"], default: SIMD3(repeating: 256)),
                directions: values.vec3(raw["directions"], default: SIMD3(1, 1, 0)),
                sign: values.vec3(raw["sign"], default: .zero),
                rate: values.float(raw["rate"], default: 5),
                instantaneous: values.int(raw["instantaneous"], default: 0),
                speed: Self.range(values, raw["speedmin"], raw["speedmax"], 0, 0),
                duration: values.float(raw["duration"], default: 0)
            ))
        }
        self.emitters = emitters
        accumulators = Array(repeating: 0, count: emitters.count)

        var initializers: [Initializer] = []
        for case let raw as [String: Any] in json["initializer"] as? [Any] ?? [] {
            let min = raw["min"], max = raw["max"]
            switch raw["name"] as? String {
            case "lifetimerandom": initializers.append(.lifetime(Self.range(values, min, max, 1, 1), values.float(raw["exponent"], default: 1)))
            case "sizerandom": initializers.append(.size(Self.range(values, min, max, 20, 40), values.float(raw["exponent"], default: 1)))
            case "velocityrandom": initializers.append(.velocity(values.vec3(min, default: SIMD3(-32, -32, 0)), values.vec3(max, default: SIMD3(32, 32, 0))))
            case "colorrandom": initializers.append(.color(values.vec3(min, default: SIMD3(repeating: 255)) / 255, values.vec3(max ?? min, default: SIMD3(repeating: 255)) / 255))
            case "alpharandom": initializers.append(.alpha(Self.range(values, min, max, 0.05, 1)))
            case "rotationrandom": initializers.append(.rotation(values.vec3(min, default: .zero), values.vec3(max, default: SIMD3(0, 0, 2 * .pi))))
            case "angularvelocityrandom": initializers.append(.angularVelocity(values.vec3(min, default: SIMD3(0, 0, -5)), values.vec3(max, default: SIMD3(0, 0, 5))))
            case "turbulentvelocityrandom":
                initializers.append(.turbulentVelocity(
                    speed: Self.range(values, raw["speedmin"], raw["speedmax"], 100, 250),
                    scale: values.float(raw["scale"], default: 1),
                    offset: values.float(raw["offset"], default: 0)
                ))
            case "positionoffsetrandom": initializers.append(.positionOffset(values.float(raw["distance"], default: 0)))
            default: break
            }
        }
        self.initializers = initializers

        var operators: [Operator] = []
        for case let raw as [String: Any] in json["operator"] as? [Any] ?? [] {
            switch raw["name"] as? String {
            case "movement":
                operators.append(.movement(gravity: values.vec3(raw["gravity"], default: .zero), drag: values.float(raw["drag"], default: 0)))
            case "angularmovement":
                operators.append(.angularMovement(force: values.vec3(raw["force"], default: .zero), drag: values.float(raw["drag"], default: 0)))
            case "alphafade":
                operators.append(.alphaFade(fadeIn: values.float(raw["fadeintime"], default: 0.5), fadeOut: values.float(raw["fadeouttime"], default: 0.5)))
            case "alphachange":
                operators.append(.alphaChange(start: values.float(raw["starttime"], default: 0), end: values.float(raw["endtime"], default: 1),
                                              from: values.float(raw["startvalue"], default: 1), to: values.float(raw["endvalue"], default: 0)))
            case "sizechange":
                operators.append(.sizeChange(start: values.float(raw["starttime"], default: 0), end: values.float(raw["endtime"], default: 1),
                                             from: values.float(raw["startvalue"], default: 1), to: values.float(raw["endvalue"], default: 0)))
            case "colorchange":
                operators.append(.colorChange(start: values.float(raw["starttime"], default: 0), end: values.float(raw["endtime"], default: 1),
                                              from: values.vec3(raw["startvalue"], default: SIMD3(1, 1, 1)), to: values.vec3(raw["endvalue"], default: SIMD3(1, 1, 1))))
            case "oscillatealpha":
                operators.append(.oscillateAlpha(frequency: Self.range(values, raw["frequencymin"], raw["frequencymax"], 0, 10),
                                                 scale: Self.range(values, raw["scalemin"], raw["scalemax"], 0, 1)))
            case "oscillatesize":
                operators.append(.oscillateSize(frequency: Self.range(values, raw["frequencymin"], raw["frequencymax"], 0, 10),
                                                scale: Self.range(values, raw["scalemin"], raw["scalemax"], 0.8, 1.2)))
            case "oscillateposition":
                operators.append(.oscillatePosition(frequency: Self.range(values, raw["frequencymin"], raw["frequencymax"], 0, 10),
                                                    scale: Self.range(values, raw["scalemin"], raw["scalemax"], 0, 1),
                                                    mask: values.vec3(raw["mask"], default: SIMD3(1, 1, 0))))
            case "turbulence":
                operators.append(.turbulence(speed: Self.range(values, raw["speedmin"], raw["speedmax"], 500, 1000),
                                             scale: values.float(raw["scale"], default: 0.005),
                                             timescale: values.float(raw["timescale"], default: 1),
                                             mask: values.vec3(raw["mask"], default: SIMD3(1, 1, 0))))
            case "vortex":
                operators.append(.vortex(offset: values.vec3(raw["offset"], default: .zero), axis: values.vec3(raw["axis"], default: SIMD3(0, 0, 1)),
                                         inner: values.float(raw["distanceinner"], default: 500), outer: values.float(raw["distanceouter"], default: 650),
                                         speedInner: values.float(raw["speedinner"], default: 2500), speedOuter: values.float(raw["speedouter"], default: 0)))
            case "controlpointattract":
                operators.append(.attract(controlPoint: values.int(raw["controlpoint"], default: 0), origin: values.vec3(raw["origin"], default: .zero),
                                          scale: values.float(raw["scale"], default: 0), threshold: values.float(raw["threshold"], default: 512)))
            default: break
            }
        }
        self.operators = operators

        var mouse = Set<Int>()
        var offsets: [Int: SIMD3<Float>] = [:]
        for case let point as [String: Any] in json["controlpoint"] as? [Any] ?? [] {
            let id = values.int(point["id"], default: 0)
            if values.int(point["flags"], default: 0) & 1 != 0 { mouse.insert(id) }
            offsets[id] = values.vec3(point["offset"], default: .zero)
        }
        mouseControlPoints = mouse
        controlPointOffsets = offsets

        let rendererJSON = (json["renderer"] as? [Any])?.first as? [String: Any]
        switch rendererJSON?["name"] as? String {
        case "spritetrail":
            renderer = .trail(length: values.float(rendererJSON?["length"], default: 0.05),
                              maxLength: values.float(rendererJSON?["maxlength"], default: 10_000),
                              minLength: values.float(rendererJSON?["minlength"], default: 0))
        case "rope", "ropetrail":
            renderer = .none
        default:
            renderer = .sprite
        }
        particles.reserveCapacity(maxCount)
    }

    private static func range(_ values: SceneValues, _ min: Any?, _ max: Any?, _ defaultMin: Float, _ defaultMax: Float) -> ClosedRange<Float> {
        let low = values.float(min, default: defaultMin)
        let high = values.float(max, default: Swift.max(defaultMax, low))
        return Swift.min(low, high)...Swift.max(low, high)
    }

    // MARK: Simulation

    /// `pointer` is the cursor in this system's local space, if it's over the scene.
    func update(delta: Float, pointer: SIMD3<Float>?) {
        clock += delta
        // Age and remove.
        var index = 0
        while index < particles.count {
            particles[index].age += delta
            if particles[index].age >= particles[index].lifetime {
                let dead = particles[index]
                particles.swapAt(index, particles.count - 1)
                particles.removeLast()
                for child in children where child.childKind == .death { child.burst(at: dead.position + dead.offset) }
                continue
            }
            index += 1
        }
        emit(delta: delta)
        simulate(delta: delta, pointer: pointer)
        for child in children {
            if child.childKind == .follow {
                child.followOrigins = particles.map { $0.position + $0.offset }
            }
            child.update(delta: delta, pointer: pointer)
        }
    }

    /// Positions of the parent's particles that a following child emits from.
    private var followOrigins: [SIMD3<Float>] = []

    private func emit(delta: Float) {
        for (index, emitter) in emitters.enumerated() {
            if !emitted, emitter.instantaneous > 0 {
                for _ in 0..<emitter.instantaneous { spawn(emitter) }
            }
            if emitter.duration > 0, clock > emitter.duration { continue }
            if childKind == .death || childKind == .spawn { continue }
            var rate = emitter.rate * overrides.rate
            if childKind == .follow { rate *= Float(followOrigins.count) }
            accumulators[index] += rate * delta
            while accumulators[index] >= 1 {
                accumulators[index] -= 1
                guard particles.count < maxCount else { accumulators[index] = 0; break }
                spawn(emitter)
            }
        }
        emitted = true
    }

    /// Event children: a burst where a parent particle died or was born.
    func burst(at position: SIMD3<Float>) {
        for emitter in emitters {
            let count = max(1, emitter.instantaneous > 0 ? emitter.instantaneous : Int(emitter.rate.rounded()))
            for _ in 0..<count where particles.count < maxCount { spawn(emitter, at: position) }
        }
    }

    private func spawn(_ emitter: Emitter, at base: SIMD3<Float>? = nil) {
        guard particles.count < maxCount else { return }
        var origin = base ?? emitter.origin
        if base == nil, childKind == .follow, !followOrigins.isEmpty {
            origin = followOrigins[Int(rng.next() * Float(followOrigins.count)) % followOrigins.count]
        }
        var offset: SIMD3<Float>
        switch emitter.shape {
        case .sphere:
            // `directions` stretches the sphere into an ellipsoid (e.g. "1 0.2 0" is a flat band).
            var direction = rng.unitVector()
            for axis in 0..<3 where emitter.sign[axis] != 0 { direction[axis] = abs(direction[axis]) * (emitter.sign[axis] > 0 ? 1 : -1) }
            let distance = emitter.distanceMin.x + (emitter.distanceMax.x - emitter.distanceMin.x) * rng.next()
            offset = direction * distance * emitter.directions
        case .box:
            offset = SIMD3(
                (rng.next() * 2 - 1) * emitter.distanceMax.x,
                (rng.next() * 2 - 1) * emitter.distanceMax.y,
                (rng.next() * 2 - 1) * emitter.distanceMax.z
            )
        }
        var particle = Particle(
            position: origin + offset,
            velocity: .zero,
            rotation: .zero,
            angularVelocity: .zero,
            color: SIMD3(1, 1, 1),
            alpha: 1,
            size: 20,
            age: 0,
            lifetime: 1,
            random: SIMD4(rng.next(), rng.next(), rng.next(), rng.next())
        )
        if emitter.speed.upperBound > 0, simd_length(offset) > 0.0001 {
            particle.velocity += simd_normalize(offset) * rng.value(in: emitter.speed)
        }
        for initializer in initializers {
            switch initializer {
            case .lifetime(let range, let exponent): particle.lifetime = rng.value(in: range, exponent: exponent)
            case .size(let range, let exponent): particle.size = rng.value(in: range, exponent: exponent)
            case .velocity(let low, let high): particle.velocity += rng.vector(low, high)
            case .color(let low, let high): particle.color = rng.vector(low, high)
            case .alpha(let range): particle.alpha = rng.value(in: range)
            case .rotation(let low, let high): particle.rotation = rng.vector(low, high)
            case .angularVelocity(let low, let high): particle.angularVelocity = rng.vector(low, high)
            case .turbulentVelocity(let speed, let scale, let offsetAngle):
                let p = particle.position * scale * 0.01
                let angle = (sin(p.x * 1.7 + p.y * 0.9) + cos(p.y * 1.3 - p.x * 0.7)) * .pi + offsetAngle
                particle.velocity += SIMD3(cos(angle), sin(angle), 0) * rng.value(in: speed)
            case .positionOffset(let distance): particle.position += rng.unitVector() * distance * rng.next()
            }
        }
        particle.lifetime = max(0.01, particle.lifetime * overrides.lifetime)
        particle.size *= overrides.size
        particle.alpha *= overrides.alpha
        particle.color *= overrides.color
        particle.velocity *= overrides.speed
        if randomFrame, spriteFrames > 0 { particle.frame = Float(Int(rng.next() * Float(spriteFrames))) / Float(spriteFrames) + 0.0001 }
        particles.append(particle)
        for child in children where child.childKind == .spawn { child.burst(at: particle.position) }
    }

    private func simulate(delta: Float, pointer: SIMD3<Float>?) {
        guard !particles.isEmpty else { return }
        for index in particles.indices {
            var p = particles[index]
            for op in operators {
                switch op {
                case .movement(let gravity, let drag):
                    p.velocity += gravity * delta
                    if drag > 0 { p.velocity *= max(0, 1 - drag * delta) }
                    p.position += p.velocity * delta
                case .angularMovement(let force, let drag):
                    p.angularVelocity += force * delta
                    if drag > 0 { p.angularVelocity *= max(0, 1 - drag * delta) }
                    p.rotation += p.angularVelocity * delta
                case .turbulence(let speed, let scale, let timescale, let mask):
                    let q = p.position * scale + SIMD3(repeating: clock * timescale)
                    let force = SIMD3(
                        sin(q.y * 1.31 + q.z * 0.7) + sin(q.x * 2.17 - clock * 0.3),
                        sin(q.z * 1.73 + q.x * 0.9) + cos(q.y * 2.41 + clock * 0.2),
                        sin(q.x * 1.11 + q.y * 1.9)
                    ) * 0.5
                    let strength = speed.lowerBound + (speed.upperBound - speed.lowerBound) * p.random.w
                    p.velocity += force * mask * strength * delta
                case .vortex(let offset, let axis, let inner, let outer, let speedInner, let speedOuter):
                    let relative = p.position - offset
                    let distance = simd_length(relative)
                    let t = min(max((distance - inner) / max(outer - inner, 0.001), 0), 1)
                    let speed = speedInner + (speedOuter - speedInner) * t
                    let tangent = simd_cross(simd_normalize(axis), relative)
                    if simd_length(tangent) > 0.0001 { p.velocity += simd_normalize(tangent) * speed * delta }
                case .attract(let point, let origin, let scale, let threshold):
                    let target: SIMD3<Float>
                    if mouseControlPoints.contains(point) {
                        guard let pointer else { continue }
                        target = pointer + origin
                    } else {
                        target = (controlPointOffsets[point] ?? .zero) + origin
                    }
                    let delta3 = target - p.position
                    let distance = simd_length(delta3)
                    if distance < threshold, distance > 0.001 {
                        p.velocity += delta3 / distance * scale * delta
                    }
                default:
                    break
                }
            }
            particles[index] = p
        }
    }

    // MARK: Drawing

    /// Values that only exist at draw time (fades, oscillations), applied to a copy.
    func renderState(of p: Particle) -> (position: SIMD3<Float>, size: Float, color: SIMD3<Float>, alpha: Float) {
        let life = min(max(p.age / p.lifetime, 0), 1)
        var alpha = p.alpha, size = p.size, color = p.color, position = p.position
        for op in operators {
            switch op {
            case .alphaFade(let fadeIn, let fadeOut):
                if fadeIn > 0, life < fadeIn { alpha *= life / fadeIn }
                if life > fadeOut, fadeOut < 1 { alpha *= max(0, 1 - (life - fadeOut) / (1 - fadeOut)) }
            case .alphaChange(let start, let end, let from, let to):
                alpha *= from + (to - from) * Self.ramp(life, start, end)
            case .sizeChange(let start, let end, let from, let to):
                size *= from + (to - from) * Self.ramp(life, start, end)
            case .colorChange(let start, let end, let from, let to):
                color *= from + (to - from) * Self.ramp(life, start, end)
            case .oscillateAlpha(let frequency, let scale):
                let f = frequency.lowerBound + (frequency.upperBound - frequency.lowerBound) * p.random.x
                let wave = 0.5 + 0.5 * sin(p.age * f + p.random.y * 6.283)
                alpha *= scale.lowerBound + (scale.upperBound - scale.lowerBound) * wave
            case .oscillateSize(let frequency, let scale):
                let f = frequency.lowerBound + (frequency.upperBound - frequency.lowerBound) * p.random.y
                let wave = 0.5 + 0.5 * sin(p.age * f + p.random.z * 6.283)
                size *= scale.lowerBound + (scale.upperBound - scale.lowerBound) * wave
            case .oscillatePosition(let frequency, let scale, let mask):
                let f = frequency.lowerBound + (frequency.upperBound - frequency.lowerBound) * p.random.z
                let s = scale.lowerBound + (scale.upperBound - scale.lowerBound) * p.random.x
                let phase = p.random.w * 6.283
                position += SIMD3(sin(p.age * f + phase), cos(p.age * f * 0.9 + phase), sin(p.age * f * 1.1 + phase * 0.5)) * s * mask
            default:
                break
            }
        }
        return (position, max(size, 0), color, min(max(alpha, 0), 1))
    }

    private static func ramp(_ life: Float, _ start: Float, _ end: Float) -> Float {
        guard end > start else { return life >= end ? 1 : 0 }
        return min(max((life - start) / (end - start), 0), 1)
    }

    /// Writes four vertices per live particle; returns how many particles were written.
    func writeVertices(into pointer: UnsafeMutablePointer<SceneVertex>, capacity: Int) -> Int {
        var written = 0
        let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        for particle in particles where written < capacity {
            let state = renderState(of: particle)
            guard state.alpha > 0.001, state.size > 0.01 else { continue }
            let life = particle.age / particle.lifetime
            let frame = randomFrame ? particle.frame : (life * sequenceMultiplier).truncatingRemainder(dividingBy: 1)
            for (index, corner) in corners.enumerated() {
                pointer[written * 4 + index] = SceneVertex(
                    position: SIMD4(state.position, 1),
                    texcoord: SIMD4(corner.x, corner.y, particle.rotation.z, state.size),
                    texcoord1: SIMD4(particle.velocity, frame),
                    texcoord2: SIMD4(particle.rotation.x, particle.rotation.y, 0, 0),
                    color: SIMD4(state.color, state.alpha)
                )
            }
            written += 1
        }
        return written
    }

    /// Advances the simulation as if it had been running for `seconds` (`starttime`).
    func prewarm(_ seconds: Float) {
        guard seconds > 0 else { return }
        let step: Float = 1.0 / 15
        var remaining = min(seconds, 30)
        while remaining > 0 {
            update(delta: min(step, remaining), pointer: nil)
            remaining -= step
        }
    }
}

/// A particle object in the scene: its systems (with children) and their GPU buffers.
final class ParticleLayer {
    let object: SceneDocument.Object
    let root: ParticleSystem
    var parentModel = matrix_identity_float4x4
    var localModel: simd_float4x4
    private var buffers: [ObjectIdentifier: [MTLBuffer]] = [:]
    private var frameIndex = 0
    private static var indexBuffer: MTLBuffer?
    private static let indexLock = NSLock()

    init(object: SceneDocument.Object, root: ParticleSystem) {
        self.object = object
        self.root = root
        localModel = SceneMath.model(origin: object.origin, angles: object.angles, scale: object.scale)
    }

    var model: simd_float4x4 { parentModel * localModel }

    var systems: [ParticleSystem] {
        var result: [ParticleSystem] = []
        func visit(_ system: ParticleSystem) {
            result.append(system)
            system.children.forEach(visit)
        }
        visit(root)
        return result
    }

    func update(delta: Float, pointerCanvas: SIMD2<Float>?) {
        let local = pointerCanvas.map { point -> SIMD3<Float> in
            let p = model.inverse * SIMD4(point.x, point.y, 0, 1)
            return SIMD3(p.x, p.y, p.z)
        }
        root.update(delta: delta, pointer: local)
    }

    static func sharedIndices(device: MTLDevice) -> MTLBuffer? {
        indexLock.lock()
        defer { indexLock.unlock() }
        if let indexBuffer { return indexBuffer }
        let quads = 16_000
        var indices: [UInt32] = []
        indices.reserveCapacity(quads * 6)
        for quad in 0..<quads {
            let base = UInt32(quad * 4)
            indices += [base, base + 1, base + 2, base + 1, base + 3, base + 2]
        }
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 4, options: .storageModeShared)
        return indexBuffer
    }

    /// The vertex buffer for `system` this frame (three in rotation so the GPU never reads
    /// one the CPU is writing).
    func vertexBuffer(for system: ParticleSystem, device: MTLDevice) -> MTLBuffer? {
        let key = ObjectIdentifier(system)
        if buffers[key] == nil {
            let length = max(1, system.maxCount) * 4 * MemoryLayout<SceneVertex>.stride
            buffers[key] = (0..<3).compactMap { _ in device.makeBuffer(length: length, options: .storageModeShared) }
        }
        guard let ring = buffers[key], ring.count == 3 else { return nil }
        return ring[frameIndex % 3]
    }

    func advanceFrame() { frameIndex += 1 }
}

/// Small, fast, deterministic random numbers for particles.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    mutating func next() -> Float { Float(nextUInt() >> 40) / Float(1 << 24) }

    mutating func value(in range: ClosedRange<Float>, exponent: Float = 1) -> Float {
        let t = exponent == 1 ? next() : pow(next(), exponent)
        return range.lowerBound + (range.upperBound - range.lowerBound) * t
    }

    mutating func vector(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(low.x + (high.x - low.x) * next(), low.y + (high.y - low.y) * next(), low.z + (high.z - low.z) * next())
    }

    mutating func unitVector() -> SIMD3<Float> {
        let z = next() * 2 - 1
        let angle = next() * 2 * .pi
        let r = (max(0, 1 - z * z)).squareRoot()
        return SIMD3(r * cos(angle), r * sin(angle), z)
    }
}
