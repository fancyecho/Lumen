import Foundation
import XCTest

final class WallpaperEngineProjectTests: XCTestCase {
    func testLoadsLenientManifestAndNormalisesPropertyDefaults() throws {
        let folder = try makeFixtureDirectory()
        let manifest = #"""
        {
          // Workshop authors sometimes leave comments and trailing commas.
          "title": "<b>Night</b><br>Sky &amp; Stars",
          "type": "WEB",
          "file": "pages/index.html",
          "preview": "poster.png",
          "workshopid": 3456789012,
          "tags": ["Relaxing"],
          "contentrating": "Everyone",
          "general": {
            "supportsaudioprocessing": true,
            "localization": { "en-us": { "mode_title": "<b>Theme</b>", "night_option": "Night" } },
            "properties": {
              "speed": { "type": "slider", "value": "2.5", "order": 1, "min": 0, "max": 5, "step": 0.5 },
              "mode": {
                "type": "combo", "text": "mode_title", "value": 2, "index": 0,
                "options": [{ "label": "night_option", "value": 2 }]
              },
              "enabled": { "type": "bool", "value": 1, "order": 1, "condition": "mode.value == 2" },
              "invalid": false,
            },
          },
        }
        """#
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(contentsOf: manifest.utf8)
        try bytes.write(to: folder.appending(path: "project.json"))

        let project = try WEProject.load(folder: folder)

        XCTAssertEqual(project.kind, .web)
        XCTAssertEqual(project.title, "Night Sky & Stars")
        XCTAssertEqual(project.entryURL, folder.appending(path: "pages/index.html"))
        XCTAssertEqual(project.previewURL, folder.appending(path: "poster.png"))
        XCTAssertEqual(project.workshopID, "3456789012")
        XCTAssertEqual(project.tags, ["Relaxing"])
        XCTAssertEqual(project.contentRating, "Everyone")
        XCTAssertTrue(project.supportsAudio)
        XCTAssertEqual(project.properties.map(\.id), ["mode", "enabled", "speed"])

        let mode = try XCTUnwrap(project.properties.first { $0.id == "mode" })
        XCTAssertEqual(mode.kind, .combo)
        XCTAssertEqual(mode.label, "Theme")
        XCTAssertEqual(mode.defaultValue, .string("2"))
        XCTAssertEqual(mode.options, [.init(label: "Night", value: "2")])

        let enabled = try XCTUnwrap(project.properties.first { $0.id == "enabled" })
        XCTAssertEqual(enabled.defaultValue, .bool(true))
        XCTAssertTrue(WEProperty.conditionHolds(enabled.condition, values: ["mode": mode.defaultValue]))
        XCTAssertFalse(WEProperty.conditionHolds(enabled.condition, values: ["mode": .string("1")]))

        let speed = try XCTUnwrap(project.properties.first { $0.id == "speed" })
        XCTAssertEqual(speed.defaultValue, .number(2.5))
        XCTAssertEqual(speed.min, 0)
        XCTAssertEqual(speed.max, 5)
        XCTAssertEqual(speed.step, 0.5)
    }

    func testUsesWorkshopFolderNameWhenOptionalMetadataIsMissing() throws {
        let folder = try makeFixtureDirectory(name: "3456789012")
        try #"{"type":"scene","file":"scene.pkg","preview":""}"#
            .write(to: folder.appending(path: "project.json"), atomically: true, encoding: .utf8)

        let project = try WEProject.load(folder: folder)

        XCTAssertEqual(project.kind, .scene)
        XCTAssertEqual(project.title, "3456789012")
        XCTAssertEqual(project.workshopID, "3456789012")
        XCTAssertNil(project.previewURL)
        XCTAssertTrue(project.properties.isEmpty)
        XCTAssertFalse(project.supportsAudio)
    }

    func testRejectsAValidJSONValueWithTheWrongRootType() throws {
        let folder = try makeFixtureDirectory()
        try "[]".write(to: folder.appending(path: "project.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try WEProject.load(folder: folder)) { error in
            guard case .unreadable? = error as? WEProject.ProjectError else {
                return XCTFail("Expected unreadable, got \(error)")
            }
        }
    }
}
