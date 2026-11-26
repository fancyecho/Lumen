import Foundation
import XCTest

final class SteamSceneAssetsTests: XCTestCase {
    private let appInfo = """
    "appinfo"
    {
        "appid"     "431960"
        // Comments, conditionals and escapes appear in real product info.
        "common" { "name" "Wallpaper \\"Engine\\"" }
        "depots"
        {
            "431961"
            {
                "config" { "oslist" "windows" }
                "manifests" { "public" { "gid" "7000000000000000001" "size" "900000000" "download" "400000000" } }
            }
            "431962"
            {
                "manifests" { "public" "7000000000000000002" }
            }
            "431963"
            {
                "config" { "oslist" "macos" }
                "manifests" { "public" { "gid" "7000000000000000003" "size" "5" } }
            }
            "431964" { "depotfromapp" "228980" }
            "branches" { "public" { "buildid" "1" } }
            "workshopdepot" "431960" [$WIN32]
        }
    }
    """

    func testKeyValuesReadNestedBlocksCaseInsensitively() throws {
        let root = try XCTUnwrap(SteamKeyValues.parse(appInfo))
        XCTAssertEqual(root["APPINFO"]?["common"]?["name"]?.value, "Wallpaper \"Engine\"")
        XCTAssertEqual(root["appinfo"]?["depots"]?["workshopdepot"]?.value, "431960")
        XCTAssertNil(SteamKeyValues.parse("\"a\" { \"b\" \"c\""))
        XCTAssertNil(SteamKeyValues.parse("}"))
    }

    func testDepotsKeepWindowsAndUnlabelledPublicManifestsLargestFirst() throws {
        let depots = try SteamAppDepot.parse(Data(appInfo.utf8) + Data([0]))
        XCTAssertEqual(depots, [
            SteamAppDepot(id: 431961, manifestID: 7_000_000_000_000_000_001, size: 900_000_000),
            SteamAppDepot(id: 431962, manifestID: 7_000_000_000_000_000_002, size: 0),
        ])
    }

    func testOnlyFilesInsideAssetsAreKept() {
        XCTAssertEqual(SteamSceneAssetsDownload.assetsPath(["Assets", "shaders", "common.h"]), ["shaders", "common.h"])
        XCTAssertNil(SteamSceneAssetsDownload.assetsPath(["assets"]))
        XCTAssertNil(SteamSceneAssetsDownload.assetsPath(["bin", "wallpaper64.exe"]))
        XCTAssertNil(SteamSceneAssetsDownload.assetsPath(["projects", "assets", "x"]))
    }
}
