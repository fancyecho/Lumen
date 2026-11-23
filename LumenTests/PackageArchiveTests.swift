import Foundation
import XCTest

final class PackageArchiveTests: XCTestCase {
    func testEntryOffsetsAreRelativeToTheEndOfTheEntireTable() throws {
        var package = packageHeader(entryCount: 3)
        package.appendSizedString("./folder\\背景.txt")
        package.appendLE(5, 6)
        package.appendSizedString("scene.json")
        package.appendLE(0, 5)
        package.appendSizedString("out-of-bounds.txt")
        package.appendLE(10, 8)
        package.append(contentsOf: "scenepixels".utf8)

        let url = try makeFixtureDirectory().appending(path: "scene.pkg")
        try package.write(to: url)
        let archive = try PackageArchive(url: url)

        XCTAssertEqual(archive.version, "PKGV0002")
        XCTAssertEqual(Set(archive.fileNames), ["folder/背景.txt", "scene.json"])
        XCTAssertTrue(archive.contains("folder/背景.txt"))
        XCTAssertEqual(archive.data("folder/背景.txt"), Data("pixels".utf8))
        XCTAssertEqual(archive.data("scene.json"), Data("scene".utf8))
        XCTAssertNil(archive.data("out-of-bounds.txt"))
    }

    func testInvalidMagicAndTruncatedTableReportCorruptPackage() throws {
        var invalidMagic = Data()
        invalidMagic.appendSizedString("NOTAPKG")
        invalidMagic.appendLE(0)

        var truncated = packageHeader(entryCount: 1)
        truncated.appendSizedString("scene.json")
        truncated.appendLE(0) // Offset only; the entry size is missing.

        let url = try makeFixtureDirectory().appending(path: "scene.pkg")
        for bytes in [invalidMagic, truncated] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try PackageArchive(url: url)) { error in
                guard case .corruptPackage? = error as? SceneLoadError else {
                    return XCTFail("Expected corruptPackage, got \(error)")
                }
            }
        }
    }

    func testSceneFilesPreferPackageThenLooseFilesThenSharedAssets() throws {
        let project = try makeFixtureDirectory(name: "project")
        let assets = try makeFixtureDirectory(name: "assets")
        var package = packageHeader(entryCount: 1)
        package.appendSizedString("scene.json")
        package.appendLE(0, 8)
        package.append(contentsOf: "archived".utf8)
        try package.write(to: project.appending(path: "scene.pkg"))
        try "loose scene".write(to: project.appending(path: "scene.json"), atomically: true, encoding: .utf8)
        try "loose".write(to: project.appending(path: "material.json"), atomically: true, encoding: .utf8)
        try "shared material".write(to: assets.appending(path: "material.json"), atomically: true, encoding: .utf8)
        try "shared".write(to: assets.appending(path: "shader.frag"), atomically: true, encoding: .utf8)

        let files = try SceneFileSystem(projectFolder: project, assets: assets)

        XCTAssertEqual(files.text("./scene.json"), "archived")
        XCTAssertEqual(files.text("material.json"), "loose")
        XCTAssertEqual(files.text("shader.frag"), "shared")
        XCTAssertNil(files.text("missing.frag"))
    }

    private func packageHeader(entryCount: UInt32) -> Data {
        var package = Data()
        package.appendSizedString("PKGV0002")
        package.appendLE(entryCount)
        return package
    }
}
