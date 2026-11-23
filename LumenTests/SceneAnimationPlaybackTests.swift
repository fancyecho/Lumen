import XCTest

final class SceneAnimationPlaybackTests: XCTestCase {
    func testStartPausedPlayPauseResumeAndStopUseTheSceneClock() throws {
        var player = SceneAnimationPlayback(try XCTUnwrap(SceneAnimation(track(mode: "loop", paused: true))))
        XCTAssertFalse(player.isPlaying(at: 8))
        XCTAssertEqual(player.frame(at: 8), 0)

        player.play(at: 8)
        player.play(at: 8.5)
        XCTAssertEqual(player.frame(at: 9), 10)
        player.pause(at: 9)
        XCTAssertFalse(player.isPlaying(at: 15))
        XCTAssertEqual(player.frame(at: 15), 10)
        player.play(at: 15)
        XCTAssertEqual(player.frame(at: 15.5), 15)

        player.stop(at: 15.5)
        XCTAssertFalse(player.isPlaying(at: 16))
        XCTAssertEqual(player.frame(at: 16), 0)
    }

    func testSingleHoldsLastFrameAndCanBeReplayed() throws {
        var player = SceneAnimationPlayback(try XCTUnwrap(SceneAnimation(track(mode: "single"))))
        XCTAssertFalse(player.isPlaying(at: 3))
        XCTAssertEqual(player.frame(at: 3), 20)
        player.play(at: 3)
        XCTAssertTrue(player.isPlaying(at: 3))
        XCTAssertEqual(player.frame(at: 3), 0)
        XCTAssertEqual(player.frame(at: 3.5), 5)
    }

    func testMirrorResumesInTheDirectionItWasMoving() throws {
        var player = SceneAnimationPlayback(try XCTUnwrap(SceneAnimation(track(mode: "mirror"))))
        player.pause(at: 3)
        XCTAssertEqual(player.frame(at: 10), 10)
        player.play(at: 10)
        XCTAssertEqual(player.frame(at: 10.5), 5)
        XCTAssertEqual(player.frame(at: 11.5), 5)
    }

    func testSeekingAndChangingRateDoNotMoveThePreviousPlayhead() throws {
        var player = SceneAnimationPlayback(try XCTUnwrap(SceneAnimation(track(mode: "loop", paused: true))))
        player.seek(to: 20, at: 0)
        XCTAssertEqual(player.frame(at: 5), 20)
        player.seek(to: 5, at: 5)
        player.setRate(2, at: 5)
        player.play(at: 5)
        XCTAssertEqual(player.frame(at: 5.5), 15)
        player.setRate(0.5, at: 5.5)
        XCTAssertEqual(player.frame(at: 5.5), 15)
        XCTAssertEqual(player.frame(at: 6), 17.5)
    }

    func testCombinedLayerPropertiesSampleTheSamePlayhead() throws {
        var alpha = track(mode: "single", parent: "origin")
        var alphaAnimation = try XCTUnwrap(alpha["animation"] as? [String: Any])
        alphaAnimation["c0"] = [["frame": 0, "value": 0], ["frame": 20, "value": 1]]
        alpha["animation"] = alphaAnimation
        let document = SceneDocument(json: [
            "objects": [[
                "id": 1, "image": "models/solid.json",
                "origin": track(mode: "single", paused: true), "alpha": alpha,
            ]],
        ], values: SceneValues(properties: [:]))
        let object = try XCTUnwrap(document.objects.first)
        XCTAssertEqual(object.state(at: 1).origin.x, 0)
        XCTAssertEqual(object.state(at: 1).alpha, 0)
        let state = object.state(at: 1, animationFrames: ["origin": 10])
        XCTAssertEqual(state.origin.x, 10)
        XCTAssertEqual(state.alpha, 0.5)
    }

    private func track(mode: String, paused: Bool = false, parent: String? = nil) -> [String: Any] {
        var options: [String: Any] = ["mode": mode, "fps": 10, "length": 20, "startpaused": paused]
        if let parent { options["parent"] = ["key": parent] }
        return [
            "value": 0,
            "animation": [
                "options": options,
                "c0": [["frame": 0, "value": 0], ["frame": 20, "value": 20]],
            ],
        ]
    }
}
