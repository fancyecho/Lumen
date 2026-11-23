import XCTest

final class SceneValuesTests: XCTestCase {
    func testConvertsDirectBindingsToBoolean() {
        let cases: [(PropertyValue, Bool)] = [
            (.bool(false), false), (.bool(true), true),
            (.number(0), false), (.number(0.25), true), (.number(-2), true),
            (.string("  \n"), false), (.string(" 0.0 "), false),
            (.string("-2"), true), (.string("2"), true), (.string("local"), true),
            (.string("0 0 0"), true), (.string("0.9 0.9 0.9"), true),
        ]
        for (property, expected) in cases {
            let values = SceneValues(properties: ["property": property])
            let shorthand: [String: Any] = ["user": "property", "value": false]
            let descriptor = ["user": ["name": "property"]]
            XCTAssertEqual(values.resolve(shorthand) as? Bool, expected, "\(property)")
            XCTAssertEqual(values.bool(descriptor, default: !expected), expected, "\(property)")
        }
    }

    func testConditionMatchesTheOptionIDBeforeCoercion() {
        let binding: [String: Any] = ["user": ["name": "style", "condition": "2"], "value": false]
        let matching = SceneValues(properties: ["style": .string("2")])
        let nonmatching = SceneValues(properties: ["style": .string("1")])

        XCTAssertTrue(matching.bool(binding, default: false))
        XCTAssertFalse(nonmatching.bool(binding, default: true))
    }

    func testMissingBindingUsesTheAuthoredValueOrCallerFallback() {
        let values = SceneValues(properties: [:])
        let binding: [String: Any] = ["user": ["name": "missing", "condition": "2"], "value": true]

        XCTAssertTrue(values.bool(binding, default: false))
        XCTAssertFalse(values.bool(["user": "missing", "value": false], default: true))
        XCTAssertTrue(values.bool(["user": "missing"], default: true))
        XCTAssertFalse(values.bool(["value": "2"], default: true))
    }

    func testAppliesOneColorToLayerVisibilityAndTint() throws {
        let values = SceneValues(properties: ["background": .string("0.91 0.91 0.91"), "enabled": .bool(true)])
        let scene = SceneDocument(json: [
            "objects": [[
                "id": 269,
                "image": "models/solid.json",
                "visible": ["user": "background", "value": true] as [String: Any],
                "color": ["user": "background", "value": "0.5 0.5 0.5"],
                "alpha": ["user": "enabled", "value": 0.2] as [String: Any],
            ]],
        ], values: values)
        let layer = try XCTUnwrap(scene.objects.first)

        XCTAssertTrue(layer.visible)
        XCTAssertEqual(layer.color, SIMD3(repeating: 0.91))
        XCTAssertEqual(layer.alpha, 1)
        let disabled = SceneValues(properties: ["enabled": .bool(false)])
        XCTAssertEqual(disabled.float(["user": "enabled", "value": 0.2], default: 1), 0)
    }
}
