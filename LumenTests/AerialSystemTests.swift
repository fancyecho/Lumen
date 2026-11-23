import Foundation
import XCTest

final class AerialSystemTests: XCTestCase {
    private let assetA = AerialSystem.assetSlots[0]
    private let assetB = AerialSystem.assetSlots[1]

    private func makeImageContent(url: String) throws -> [String: Any] {
        let config = try PropertyListSerialization.data(
            fromPropertyList: ["type": "imageFile", "url": ["relative": url]],
            format: .binary,
            options: 0
        )
        return [
            "Choices": [[
                "Configuration": config,
                "Files": [Any](),
                "Provider": "com.apple.wallpaper.choice.image",
            ]],
            "EncodedOptionValues": Data([1, 2, 3]),
            "Shuffle": "$null",
        ]
    }

    private func makeAerialContent(assetID: String) throws -> [String: Any] {
        let config = try PropertyListSerialization.data(
            fromPropertyList: ["assetID": assetID],
            format: .binary,
            options: 0
        )
        return [
            "Choices": [[
                "Configuration": config,
                "Files": [Any](),
                "Provider": "com.apple.wallpaper.choice.aerials",
            ]],
            "EncodedOptionValues": "$null",
            "Shuffle": "$null",
        ]
    }

    private func makeSlot(_ content: [String: Any]) -> [String: Any] {
        ["Content": content, "LastSet": Date(timeIntervalSince1970: 100), "LastUse": Date(timeIntervalSince1970: 100)]
    }

    private func makeSampleStore() throws -> [String: Any] {
        let img1 = try makeImageContent(url: "file:///orig-desktop-1.jpg")
        let img2 = try makeImageContent(url: "file:///orig-desktop-2.jpg")
        let origIdle = try makeAerialContent(assetID: "APPLE-ORIGINAL-AERIAL-0001")
        let container1: [String: Any] = [
            "Type": "individual",
            "Desktop": makeSlot(img1),
            "Idle": makeSlot(origIdle),
        ]
        let container2: [String: Any] = [
            "Type": "individual",
            "Desktop": makeSlot(img2),
            "Idle": makeSlot(origIdle),
        ]
        return [
            "AllSpacesAndDisplays": [
                "Type": "idle",
                "Idle": makeSlot(origIdle),
            ],
            "SystemDefault": container1,
            "Displays": [
                "DISP-PRIMARY": container1,
                "DISP-SECONDARY": container2,
            ],
            "Spaces": [
                "SPACE-1": [
                    "Default": container1,
                    "Displays": [
                        "DISP-PRIMARY": container1,
                        "DISP-SECONDARY": container2,
                    ],
                ],
                "SPACE-2": [
                    "Default": container1,
                    "Displays": [
                        "DISP-PRIMARY": container1,
                    ],
                ],
            ],
        ]
    }

    private func choiceProviderAndURLOrAsset(in slot: Any?) -> (provider: String?, value: String?) {
        guard let slotDict = slot as? [String: Any],
              let content = slotDict["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let first = choices.first
        else { return (nil, nil) }
        let provider = first["Provider"] as? String
        guard let data = first["Configuration"] as? Data,
              let cfg = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (provider, nil) }
        if let id = cfg["assetID"] as? String { return (provider, id) }
        if let url = (cfg["url"] as? [String: Any])?["relative"] as? String { return (provider, url) }
        return (provider, nil)
    }

    func testSelectUpdatesDesktopAndIdleAcrossAllContainersAndRestoresLosslessly() throws {
        let original = try makeSampleStore()
        var backup: [String: Data] = [:]

        let selected = try AerialSystem.applySelection(
            to: original,
            assetID: assetA,
            includeIdle: true,
            backup: &backup
        )

        XCTAssertTrue(AerialSystem.isSelectionActive(in: selected, assetID: assetA, includeIdle: true))

        // AllSpacesAndDisplays should gain Desktop and upgrade Type from "idle" to "individual".
        let allSD = try XCTUnwrap(selected["AllSpacesAndDisplays"] as? [String: Any])
        XCTAssertEqual(allSD["Type"] as? String, "individual")
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: allSD["Desktop"]).value, assetA)
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: allSD["Idle"]).value, assetA)

        // Switching to the alternating slot must preserve original non-Lumen backups.
        let rotated = try AerialSystem.applySelection(
            to: selected,
            assetID: assetB,
            includeIdle: true,
            backup: &backup
        )
        XCTAssertTrue(AerialSystem.isSelectionActive(in: rotated, assetID: assetB, includeIdle: true))

        // Restore must put back every original Desktop image, Idle aerial, and AllSpacesAndDisplays absence.
        let restored = AerialSystem.applyRestore(to: rotated, from: backup)
        let restoredAll = try XCTUnwrap(restored["AllSpacesAndDisplays"] as? [String: Any])
        XCTAssertNil(restoredAll["Desktop"])
        XCTAssertEqual(restoredAll["Type"] as? String, "idle")
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: restoredAll["Idle"]).value, "APPLE-ORIGINAL-AERIAL-0001")

        let restoredSys = try XCTUnwrap(restored["SystemDefault"] as? [String: Any])
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: restoredSys["Desktop"]).value, "file:///orig-desktop-1.jpg")
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: restoredSys["Idle"]).value, "APPLE-ORIGINAL-AERIAL-0001")

        let restoredSpaces = try XCTUnwrap(restored["Spaces"] as? [String: Any])
        let space1 = try XCTUnwrap(restoredSpaces["SPACE-1"] as? [String: Any])
        let space1Disp = try XCTUnwrap(space1["Displays"] as? [String: Any])
        let sec = try XCTUnwrap(space1Disp["DISP-SECONDARY"] as? [String: Any])
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: sec["Desktop"]).value, "file:///orig-desktop-2.jpg")
    }

    func testExcludedSecondaryDisplayKeepsStillFrameWhilePrimaryGetsAerial() throws {
        let original = try makeSampleStore()
        var backup: [String: Data] = [:]
        let excluded: Set<String> = ["DISP-SECONDARY"]

        let selected = try AerialSystem.applySelection(
            to: original,
            assetID: assetA,
            includeIdle: true,
            excludedDesktopDisplayIDs: excluded,
            backup: &backup
        )

        XCTAssertTrue(AerialSystem.isSelectionActive(
            in: selected,
            assetID: assetA,
            includeIdle: true,
            excludedDesktopDisplayIDs: excluded
        ))

        let displays = try XCTUnwrap(selected["Displays"] as? [String: Any])
        let primary = try XCTUnwrap(displays["DISP-PRIMARY"] as? [String: Any])
        let secondary = try XCTUnwrap(displays["DISP-SECONDARY"] as? [String: Any])
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: primary["Desktop"]).value, assetA)
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: secondary["Desktop"]).value, "file:///orig-desktop-2.jpg")
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: secondary["Idle"]).value, assetA)
    }

    func testIncludeIdleFalseRestoresScreenSaverWhileKeepingDesktopAndIdlePresent() throws {
        let original = try makeSampleStore()
        var backup: [String: Data] = [:]

        let both = try AerialSystem.applySelection(to: original, assetID: assetA, includeIdle: true, backup: &backup)
        XCTAssertFalse(AerialSystem.isSelectionActive(in: both, assetID: assetA, includeIdle: false))

        let desktopOnly = try AerialSystem.applySelection(to: both, assetID: assetA, includeIdle: false, backup: &backup)
        XCTAssertTrue(AerialSystem.isSelectionActive(in: desktopOnly, assetID: assetA, includeIdle: false))

        let sys = try XCTUnwrap(desktopOnly["SystemDefault"] as? [String: Any])
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: sys["Desktop"]).value, assetA)
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: sys["Idle"]).value, "APPLE-ORIGINAL-AERIAL-0001")
    }

    func testIsSelectionActiveDetectsSingleSpaceImageOverwrite() throws {
        let original = try makeSampleStore()
        var backup: [String: Data] = [:]
        var selected = try AerialSystem.applySelection(to: original, assetID: assetA, includeIdle: true, backup: &backup)

        // Overwrite one Space's Desktop with a static image (as StillFrameSync previously did).
        var spaces = try XCTUnwrap(selected["Spaces"] as? [String: Any])
        var space2 = try XCTUnwrap(spaces["SPACE-2"] as? [String: Any])
        var def = try XCTUnwrap(space2["Default"] as? [String: Any])
        def["Desktop"] = makeSlot(try makeImageContent(url: "file:///stale-still.jpg"))
        space2["Default"] = def
        spaces["SPACE-2"] = space2
        selected["Spaces"] = spaces

        XCTAssertFalse(AerialSystem.isSelectionActive(in: selected, assetID: assetA, includeIdle: true))
    }

    func testNewSpaceCreatedAfterEnableBorrowsDesktopBackupOnRestore() throws {
        let original = try makeSampleStore()
        var backup: [String: Data] = [:]
        var selected = try AerialSystem.applySelection(to: original, assetID: assetA, includeIdle: true, backup: &backup)

        // Simulate macOS cloning Lumen's Aerial into a brand new Space created after Lock Screen was enabled.
        var spaces = try XCTUnwrap(selected["Spaces"] as? [String: Any])
        spaces["SPACE-NEW"] = [
            "Default": [
                "Type": "individual",
                "Desktop": makeSlot(try makeAerialContent(assetID: assetA)),
                "Idle": makeSlot(try makeAerialContent(assetID: assetA)),
            ],
        ]
        selected["Spaces"] = spaces

        let restored = AerialSystem.applyRestore(to: selected, from: backup)
        let restoredSpaces = try XCTUnwrap(restored["Spaces"] as? [String: Any])
        let newSpace = try XCTUnwrap(restoredSpaces["SPACE-NEW"] as? [String: Any])
        let newDefault = try XCTUnwrap(newSpace["Default"] as? [String: Any])
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: newDefault["Desktop"]).value, "file:///orig-desktop-1.jpg")
        XCTAssertEqual(choiceProviderAndURLOrAsset(in: newDefault["Idle"]).value, "APPLE-ORIGINAL-AERIAL-0001")
    }
}
