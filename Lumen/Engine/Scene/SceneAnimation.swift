import Foundation

/// A keyframed value from a scene: `{"animation": {"c0": [keys…], "options": {…}}, "value": …}`.
/// Each component (`c0`, `c1`, `c2`…) is a curve of keys with Bézier handles.
struct SceneAnimation {
    struct Key {
        var frame: Float
        var value: Float
        /// Handle offsets in (frames, value) relative to the key.
        var back: SIMD2<Float>?
        var front: SIMD2<Float>?
    }

    enum Mode { case loop, mirror, single }

    let curves: [[Key]]
    let fps: Float
    let length: Float
    let mode: Mode
    let startPaused: Bool
    let name: String
    let parentProperty: String?

    init?(_ raw: Any?) {
        guard let object = raw as? [String: Any], let animation = object["animation"] as? [String: Any] else { return nil }
        var curves: [[Key]] = []
        for index in 0..<16 {
            guard let keys = animation["c\(index)"] as? [Any] else { break }
            let parsed = keys.compactMap { raw -> Key? in
                guard let key = raw as? [String: Any], let frame = (key["frame"] as? NSNumber)?.floatValue else { return nil }
                let value = (key["value"] as? NSNumber)?.floatValue ?? 0
                func handle(_ name: String) -> SIMD2<Float>? {
                    guard let handle = key[name] as? [String: Any], handle["enabled"] as? Bool ?? true else { return nil }
                    return SIMD2((handle["x"] as? NSNumber)?.floatValue ?? 0, (handle["y"] as? NSNumber)?.floatValue ?? 0)
                }
                return Key(frame: frame, value: value, back: handle("back"), front: handle("front"))
            }.sorted { $0.frame < $1.frame }
            curves.append(parsed)
        }
        guard curves.contains(where: { !$0.isEmpty }) else { return nil }
        self.curves = curves
        let options = animation["options"] as? [String: Any] ?? [:]
        fps = max((options["fps"] as? NSNumber)?.floatValue ?? 30, 1)
        let lastFrame = curves.compactMap { $0.last?.frame }.max() ?? 0
        length = max((options["length"] as? NSNumber)?.floatValue ?? lastFrame, 1)
        startPaused = (options["startpaused"] as? Bool) ?? false
        name = options["name"] as? String ?? ""
        parentProperty = (options["parent"] as? [String: Any])?["key"] as? String
        switch options["mode"] as? String {
        case "single": mode = .single
        case "mirror": mode = .mirror
        default: mode = .loop
        }
    }

    /// A combined timeline uses the parent's playhead for its linked properties on this layer.
    static func timelineProperty(for property: String, in animations: [String: SceneAnimation]) -> String {
        guard let parent = animations[property]?.parentProperty,
              parent != property, let root = animations[parent], root.parentProperty == nil
        else { return property }
        return parent
    }

    func frame(at time: Float) -> Float {
        startPaused ? 0 : frame(forProgress: time * fps)
    }

    func frame(forProgress progress: Float) -> Float {
        switch mode {
        case .loop:
            return progress.truncatingRemainder(dividingBy: length)
        case .mirror:
            let cycle = progress.truncatingRemainder(dividingBy: length * 2)
            return cycle > length ? length * 2 - cycle : cycle
        case .single:
            return min(progress, length)
        }
    }

    /// Component values sampled at the scene time.
    func values(at time: Float) -> [Float] {
        values(atFrame: frame(at: time))
    }

    func values(atFrame frame: Float) -> [Float] {
        curves.map { Self.evaluate($0, frame: frame) }
    }

    func value(at time: Float) -> Float { values(at: time).first ?? 0 }

    private static func evaluate(_ keys: [Key], frame: Float) -> Float {
        guard let first = keys.first else { return 0 }
        if frame <= first.frame || keys.count == 1 { return first.value }
        guard let last = keys.last, frame < last.frame else { return keys.last?.value ?? 0 }
        var index = 0
        while index + 1 < keys.count, keys[index + 1].frame <= frame { index += 1 }
        let a = keys[index], b = keys[index + 1]
        let span = max(b.frame - a.frame, 0.0001)
        guard let front = a.front, let back = b.back else {
            return a.value + (b.value - a.value) * (frame - a.frame) / span
        }
        // Cubic Bézier through (frame, value) points; find t for this frame by bisection.
        let p0 = SIMD2(a.frame, a.value), p3 = SIMD2(b.frame, b.value)
        let p1 = SIMD2(min(max(a.frame + front.x, a.frame), b.frame), a.value + front.y)
        let p2 = SIMD2(max(min(b.frame + back.x, b.frame), a.frame), b.value + back.y)
        var low: Float = 0, high: Float = 1, t: Float = 0.5
        for _ in 0..<24 {
            t = (low + high) / 2
            let x = bezier(p0.x, p1.x, p2.x, p3.x, t)
            if x < frame { low = t } else { high = t }
        }
        return bezier(p0.y, p1.y, p2.y, p3.y, t)
    }

    private static func bezier(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let u = 1 - t
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    }
}

/// Scene time freezes during engine pauses. Keep an unwrapped progress so a paused mirror
/// animation can continue in the same direction when it resumes.
struct SceneAnimationPlayback {
    private let animation: SceneAnimation
    private var baseProgress: Float = 0
    private var anchorTime: Float = 0
    private var heldFrame: Float?
    private var playing: Bool
    private(set) var rate: Float = 1

    init(_ animation: SceneAnimation) {
        self.animation = animation
        playing = !animation.startPaused
    }

    private func progress(at time: Float) -> Float {
        baseProgress + (playing ? max(0, time - anchorTime) * animation.fps * rate : 0)
    }

    func frame(at time: Float) -> Float {
        let position = progress(at: time)
        if position == baseProgress, let heldFrame { return heldFrame }
        return position.isFinite ? animation.frame(forProgress: position) : 0
    }

    func isPlaying(at time: Float) -> Bool {
        playing && (animation.mode != .single || progress(at: time) < animation.length)
    }

    mutating func play(at time: Float) {
        guard !isPlaying(at: time) else { return }
        if animation.mode == .single && progress(at: time) >= animation.length {
            baseProgress = 0
            heldFrame = nil
        }
        anchorTime = time
        playing = true
    }

    mutating func pause(at time: Float) {
        heldFrame = frame(at: time)
        baseProgress = progress(at: time)
        anchorTime = time
        playing = false
    }

    mutating func stop(at time: Float) {
        baseProgress = 0
        heldFrame = nil
        anchorTime = time
        playing = false
    }

    mutating func seek(to frame: Float, at time: Float) {
        guard frame.isFinite else { return }
        baseProgress = min(max(0, frame), animation.length)
        heldFrame = baseProgress
        anchorTime = time
    }

    mutating func setRate(_ newRate: Float, at time: Float) {
        guard newRate.isFinite, newRate >= 0 else { return }
        heldFrame = frame(at: time)
        baseProgress = progress(at: time)
        anchorTime = time
        rate = newRate
    }
}
