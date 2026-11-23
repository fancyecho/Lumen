/// A scene may step down from its selected quality ceiling until the renderer is recreated
/// or the user explicitly selects a different quality.
struct SceneResolutionPolicy {
    private static let samplesPerWindow = 8
    private var sampleCount = 0
    private var slowSamples = 0
    private var remainingReductions = 3
    private(set) var budget: Double

    init(ceiling: Double) {
        budget = ceiling
    }

    var canReduce: Bool { remainingReductions > 0 }

    mutating func resetSamples() {
        sampleCount = 0
        slowSamples = 0
    }

    mutating func isSustainedLoad(gpuTime: Double, frameRate: Int) -> Bool {
        guard gpuTime.isFinite, gpuTime > 0 else { return false }
        // A 30 fps desktop probe dropped presents at 22–27 ms; 15 ms maintained its cadence.
        let limit = 0.65 / Double(max(frameRate, 1))
        sampleCount += 1
        if gpuTime > limit { slowSamples += 1 }
        guard sampleCount == Self.samplesPerWindow else { return false }
        let overloaded = slowSamples >= 6
        resetSamples()
        return overloaded
    }

    @discardableResult
    mutating func reduce(renderedPixels: Double? = nil) -> Bool {
        guard canReduce else { return false }
        // A small canvas can start far below the selected ceiling, even at Native quality.
        budget = min(budget, renderedPixels ?? budget) * 0.72
        remainingReductions -= 1
        resetSamples()
        return true
    }
}
