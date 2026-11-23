import simd

struct SceneCursorInput {
    struct Sample {
        enum Phase { case move, down, up, leave }

        let phase: Phase
        let world: SIMD2<Float>?
        let screen: SIMD2<Float>?
        let isDown: Bool
    }

    var screen: SIMD2<Float>?
    var isDown = false
    var reset = false
    var samples: [Sample] = []
}

struct SceneCursorEvent {
    enum Kind: String {
        case cursorEnter, cursorLeave, cursorMove, cursorDown, cursorUp, cursorClick
    }

    let kind: Kind
    let layerID: Int
    let world: SIMD2<Float>
    let local: SIMD2<Float>
    let screen: SIMD2<Float>
    let isDown: Bool
}

struct SceneCursorTarget {
    let layerID: Int
    let size: SIMD2<Float>
    let model: simd_float4x4
    let cameraOffset: SIMD2<Float>

    func localPosition(at world: SIMD2<Float>) -> SIMD2<Float>? {
        // Invert the XY projection of the rendered quad. Z scale can be zero on a valid 2D layer.
        let (x, y, _, origin) = model.columns
        let determinant = x.x * y.y - x.y * y.x
        guard determinant.isFinite, determinant != 0 else { return nil }
        let delta = world + cameraOffset - SIMD2(origin.x, origin.y)
        let local = SIMD2(delta.x * y.y - delta.y * y.x, x.x * delta.y - x.y * delta.x) / determinant + size / 2
        return local.x.isFinite && local.y.isFinite ? local : nil
    }

    func contains(_ local: SIMD2<Float>) -> Bool {
        size.x > 0 && size.y > 0 && local.x >= 0 && local.y >= 0 && local.x <= size.x && local.y <= size.y
    }
}

struct SceneCursorTracker {
    private struct Hit {
        let layerID: Int
        let world: SIMD2<Float>
        let local: SIMD2<Float>
        let screen: SIMD2<Float>
    }

    private var hovered: [Hit] = []
    private var pressed: Set<Int> = []

    mutating func events(for input: SceneCursorInput, targets: [SceneCursorTarget]) -> [SceneCursorEvent] {
        if input.reset {
            hovered.removeAll()
            pressed.removeAll()
        }

        var events: [SceneCursorEvent] = []
        for sample in input.samples {
            var hits: [Hit] = []
            if let world = sample.world, let screen = sample.screen {
                for target in targets {
                    guard let local = target.localPosition(at: world), target.contains(local) else { continue }
                    hits.append(Hit(layerID: target.layerID, world: world, local: local, screen: screen))
                }
            }

            func emit(_ kind: SceneCursorEvent.Kind, hits: [Hit]) {
                for hit in hits {
                    events.append(SceneCursorEvent(kind: kind, layerID: hit.layerID, world: hit.world,
                                                   local: hit.local, screen: hit.screen, isDown: sample.isDown))
                }
            }

            let previous = Set(hovered.map(\.layerID))
            let current = Set(hits.map(\.layerID))
            let leaving = hovered.filter { !current.contains($0.layerID) }.map { hit in
                // Desktop exit has no new coordinates. For a move within the scene, use its
                // actual position even though it is now outside this layer's bounds.
                guard let world = sample.world, let screen = sample.screen else { return hit }
                let local = targets.first { $0.layerID == hit.layerID }?.localPosition(at: world) ?? hit.local
                return Hit(layerID: hit.layerID, world: world, local: local, screen: screen)
            }
            emit(.cursorLeave, hits: leaving)
            emit(.cursorEnter, hits: hits.filter { !previous.contains($0.layerID) })
            hovered = hits

            switch sample.phase {
            case .move:
                emit(.cursorMove, hits: hits)
            case .down:
                pressed = current
                emit(.cursorDown, hits: hits)
            case .up:
                emit(.cursorUp, hits: hits)
                emit(.cursorClick, hits: hits.filter { pressed.contains($0.layerID) })
                pressed.removeAll()
            case .leave:
                pressed.removeAll()
            }
        }
        return events
    }
}
