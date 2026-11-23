import XCTest

final class SceneResolutionPolicyTests: XCTestCase {
    func testOnlySustainedSlowFramesTriggerReduction() {
        var policy = SceneResolutionPolicy(ceiling: 6_000_000)
        for duration in [0.028, 0.017, 0.025, 0.014, 0.026, 0.015, 0.025, 0.014] {
            XCTAssertFalse(policy.isSustainedLoad(gpuTime: duration, frameRate: 30))
        }
        for duration in [0.025, 0.014, 0.023, 0.023, 0.016, 0.024, 0.026] {
            XCTAssertFalse(policy.isSustainedLoad(gpuTime: duration, frameRate: 30))
        }
        XCTAssertTrue(policy.isSustainedLoad(gpuTime: 0.025, frameRate: 30))
        XCTAssertTrue(policy.reduce())
        XCTAssertEqual(policy.budget, 4_320_000)
        XCTAssertFalse(policy.isSustainedLoad(gpuTime: 0.025, frameRate: 30))
    }

    func testBudgetUsesActualPixelsBelowTheSelectedQualityCeiling() {
        for ceiling: Double in [1_600_000, 6_000_000, 16_600_000] {
            var policy = SceneResolutionPolicy(ceiling: ceiling)
            let first = min(ceiling, 4_000_000) * 0.72
            XCTAssertTrue(policy.reduce(renderedPixels: 4_000_000))
            XCTAssertEqual(policy.budget, first)
            XCTAssertTrue(policy.reduce())
            XCTAssertTrue(policy.reduce())
            XCTAssertEqual(policy.budget, first * 0.72 * 0.72)
            XCTAssertFalse(policy.reduce())
        }
    }
}
