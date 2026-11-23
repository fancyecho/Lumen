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

    func testTwoOptionOnOffComboMapsOffOptionToFalseForDirectBooleanBinding() {
        let projectJSON: [String: Any] = [
            "general": [
                "properties": [
                    "parallax": [
                        "type": "combo",
                        "value": "1",
                        "options": [
                            ["label": "开", "value": "1"],
                            ["label": "关", "value": "2"],
                        ],
                    ],
                    "theme": [
                        "type": "combo",
                        "value": "1",
                        "options": [
                            ["label": "Day", "value": "1"],
                            ["label": "Night", "value": "2"],
                        ],
                    ],
                ],
            ],
        ]
        let comboOff = SceneValues.comboOffValues(from: projectJSON)
        XCTAssertEqual(comboOff["parallax"], ["2"])
        XCTAssertNil(comboOff["theme"])

        let onValues = SceneValues(properties: ["parallax": .string("1"), "theme": .string("2")], comboOffValues: comboOff)
        let offValues = SceneValues(properties: ["parallax": .string("2"), "theme": .string("2")], comboOffValues: comboOff)
        let parallaxBinding: [String: Any] = ["user": "parallax", "value": true]
        let themeBinding: [String: Any] = ["user": "theme", "value": true]

        XCTAssertTrue(onValues.bool(parallaxBinding, default: false))
        XCTAssertFalse(offValues.bool(parallaxBinding, default: true))
        XCTAssertTrue(offValues.bool(themeBinding, default: false))
    }

    func testUnwrapsNestedUserPropertyFallbacks() {
        let nested: [String: Any] = [
            "user": "missingOuter",
            "value": ["user": "innerProp", "value": -4] as [String: Any],
        ]
        let withInner = SceneValues(properties: ["innerProp": .number(42)])
        let withoutAny = SceneValues(properties: [:])

        XCTAssertEqual(withInner.float(nested, default: 0), 42)
        XCTAssertEqual(withoutAny.float(nested, default: 0), -4)
    }
}
