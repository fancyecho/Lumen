import XCTest

final class AppUpdaterTests: XCTestCase {
    func testParsesTheZipAndChecksumOfTheLatestRelease() throws {
        let release = try XCTUnwrap(LumenRelease.parse(payload(tag: "v0.2.0", assets: [
            "Lumen-0.2.0.dmg", "Lumen-0.2.0.dmg.sha256", "Lumen-0.2.0.zip", "Lumen-0.2.0.zip.sha256",
        ])))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.archiveURL.lastPathComponent, "Lumen-0.2.0.zip")
        XCTAssertEqual(release.checksumURL.lastPathComponent, "Lumen-0.2.0.zip.sha256")
        XCTAssertEqual(release.notes, "Notes")
    }

    func testIgnoresReleasesTheUpdaterCannotInstall() throws {
        // 0.1.0 shipped only a DMG.
        XCTAssertNil(try LumenRelease.parse(payload(tag: "v0.1.0", assets: ["Lumen-0.1.0.dmg", "Lumen-0.1.0.dmg.sha256"])))
        XCTAssertNil(try LumenRelease.parse(payload(tag: "v0.3.0", assets: ["Lumen-0.3.0.zip"])))
        XCTAssertNil(try LumenRelease.parse(payload(tag: "v0.3.0", prerelease: true,
                                                    assets: ["Lumen-0.3.0.zip", "Lumen-0.3.0.zip.sha256"])))
        XCTAssertNil(try LumenRelease.parse(payload(tag: "nightly", assets: ["Lumen-nightly.zip", "Lumen-nightly.zip.sha256"])))
    }

    func testComparesVersionsNumerically() {
        XCTAssertTrue(AppUpdater.isNewer("0.10.0", than: "0.9.9"))
        XCTAssertTrue(AppUpdater.isNewer("1.0.0", than: "0.2.0"))
        XCTAssertFalse(AppUpdater.isNewer("0.2.0", than: "0.2.0"))
        XCTAssertFalse(AppUpdater.isNewer("0.1.9", than: "0.2.0"))
        XCTAssertFalse(AppUpdater.isNewer("0.2", than: "0.1.0"))
    }

    private func payload(tag: String, prerelease: Bool = false, assets: [String]) -> Data {
        let list = assets.map { ["name": $0, "browser_download_url": "https://github.com/fancyecho/Lumen/releases/download/\(tag)/\($0)"] }
        let object: [String: Any] = [
            "tag_name": tag, "body": "Notes", "html_url": "https://github.com/fancyecho/Lumen/releases/tag/\(tag)",
            "draft": false, "prerelease": prerelease, "assets": list,
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }
}
