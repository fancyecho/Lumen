import Foundation
import XCTest

final class SteamNativeProtocolTests: XCTestCase {
    private let message = Data(String(repeating: "Lumen Workshop test fixture\n", count: 9).utf8)
    private let key = Data(0..<32)
    private let zip = Data(base64Encoded: "UEsDBBQAAAAIAAAAIQDs61/TIQAAAPwAAAAHAAAAZml4dHVyZfMpzU3NUwjPL8ouzsgvUChJLS5RSMusKCktSuXyGeZyAFBLAQIUAxQAAAAIAAAAIQDs61/TIQAAAPwAAAAHAAAAAAAAAAAAAACAAQAAAABmaXh0dXJlUEsFBgAAAAABAAEANQAAAEYAAAAAAA==")!
    private let encrypted = Data(base64Encoded: "3J8B/Xa4fA0PS+iFCwvs4CsJKzpwFkAVUTnCIng2vy1Ypj7ht3rDb5FxGhsYeeSWWZjesx0RHP02xkZt+KuRkU2OEUhhkHcMWrjg3lZbl0fXXb8oriOYjGCMbu9kWP0jH/+lPMle4GarqVzG3ya2O3Z6MeKxrY9aqTzYaA5ILMO+7gZPrW23KXvpr+GtfyWOg9/c7x2OY2geQgrdmtalR5JA6+WRDyd1Q92j6I46SOU=")!
    private let fixtureHash = Data(base64Encoded: "yhixMKCLQk5RSxjAvyNjpTqP+Fc=")!

    func testProtobufGoldenBytesAndMalformedLengths() throws {
        var fields = SteamProto.Writer()
        fields.uint(1, 300)
        fields.fixed64(2, 0x123456789abcdef0)
        fields.bytes(3, Data([0x61, 0x62]))
        let expected = Data([0x08, 0xac, 0x02, 0x11, 0xf0, 0xde, 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12, 0x1a, 2, 0x61, 0x62])
        XCTAssertEqual(fields.data, expected)
        let parsed = try SteamProto(expected)
        XCTAssertEqual(parsed.number(1), 300)
        XCTAssertEqual(parsed.number(2), 0x123456789abcdef0)
        XCTAssertEqual(parsed.string(3), "ab")
        XCTAssertThrowsError(try SteamProto(Data([0x12, 0x07, 0x61])))
        XCTAssertThrowsError(try SteamProto(Data([8] + Array(repeating: 0xff, count: 10))))
        XCTAssertThrowsError(try SteamProto(Data([0, 1])))
    }

    func testCMCompressedMessagesKeepJobCorrelation() throws {
        let compressed = Data(base64Encoded: "H4sIAAAAAAAC/xNmYGCYzMDQwAmkI7UYIICDEQB7zu/hFwAAAA==")!
        var body = SteamProto.Writer()
        body.uint(1, 23)
        body.bytes(2, compressed)
        let packet = SteamCMFrame.make(1, header: .init(), body: body.data)
        let reply = try XCTUnwrap(SteamCM.decode(packet).first)
        XCTAssertEqual(reply.message, 147)
        XCTAssertEqual(reply.header.number(11), 42)
        XCTAssertEqual(try SteamProto(reply.body).number(1), 1)
        XCTAssertThrowsError(try SteamCMFrame(Data([1, 0, 0, 0x80, 0xff, 0xff, 0xff, 0xff])))
    }

    func testDecryptsAndExpandsWorkshopChunks() throws {
        let vz = Data(base64Encoded: "VlphAAAAAF0AAIAAACYdSaZqM8UWEJGhTxdvlZ2X7Ht4EpT2X+g5/7JlVg99fV0z//7RKADs61/T/AAAAHp2")!
        let zstd = Data(base64Encoded: "VlNaYezrX9MotS/9BFgdAQDgTHVtZW4gV29ya3Nob3AgdGVzdCBmaXh0dXJlCgEAdJ+aTrYnrQ7s61/T/AAAAAAAAAB6c3Y=")!
        let decrypted = try SteamDepotCipher.decrypt(encrypted, key: key)
        XCTAssertEqual(decrypted, zip)
        for encoded in [decrypted, vz, zstd] {
            let plain = try SteamCompression.chunk(encoded, size: message.count)
            XCTAssertEqual(plain, message)
            XCTAssertNoThrow(try SteamDepotManifest.Chunk(sha: fixtureHash, offset: 0, size: message.count).verify(plain))
        }
        XCTAssertThrowsError(try SteamDepotCipher.decrypt(encrypted.dropLast(), key: key))
        XCTAssertThrowsError(try SteamCompression.chunk(zip, size: message.count - 1))
        XCTAssertThrowsError(try SteamDepotManifest.Chunk(sha: fixtureHash, offset: 0, size: message.count)
            .verify(Data(repeating: 0, count: message.count)))
    }

    func testManifestDecodesEncryptedPathsAndRejectsUnsafeMappings() throws {
        let filename = "3J8B/Xa4fA0PS+iFCwvs4Pab4M6tUMF+/BAbZMNmQjk="
        let manifest = try SteamDepotManifest(container(filename, encrypted: true), depotID: 431960, manifestID: 51, key: key)
        XCTAssertEqual(manifest.files.first?.components, ["art", "scene.txt"])
        XCTAssertEqual(manifest.files.first?.chunks.first?.identifier, "ca18b130a08b424e514b18c0bf2363a53a8ff857")
        XCTAssertEqual(manifest.size, UInt64(message.count))
        for unsafe in ["../scene.json", "/tmp/scene.json", "C:\\wallpaper\\scene.json", "foo\\..\\scene.json"] {
            XCTAssertThrowsError(try SteamDepotManifest(container(unsafe), depotID: 431960, manifestID: 51, key: key))
        }
        XCTAssertThrowsError(try SteamDepotManifest(container("scene.json", offset: 4), depotID: 431960, manifestID: 51, key: key))
        XCTAssertThrowsError(try SteamDepotManifest(container("scene.json"), depotID: 431960, manifestID: 52, key: key))
    }

    func testReassemblesAWorkshopFolderFromVerifiedChunks() async throws {
        let parent = try makeFixtureDirectory()
        let folder = parent.appending(path: "123456")
        let manifest = try SteamDepotManifest(container("project.json"), depotID: 431960, manifestID: 51, key: key)
        var reported: [Double] = []
        try await SteamNativeDownload.materialize(manifest, key: key, in: folder) { progress in
            reported.append(progress)
        } fetch: { chunk in
            XCTAssertEqual(chunk.sha, self.fixtureHash)
            return self.encrypted
        }
        XCTAssertEqual(reported, [1])
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "project.json")), message)
    }

    func testWritesOnlyMappedDepotFilesUnderTheirNewPath() async throws {
        let parent = try makeFixtureDirectory()
        let assets = try SteamDepotManifest(container("assets\\shaders\\common.h"), depotID: 431960, manifestID: 51, key: key)
        let kept = parent.appending(path: "kept")
        try await SteamNativeDownload.materialize(assets.files, key: key, in: kept, path: SteamSceneAssetsDownload.assetsPath) { _ in
        } fetch: { _ in self.encrypted }
        XCTAssertEqual(try Data(contentsOf: kept.appending(path: "shaders/common.h")), message)

        let program = try SteamDepotManifest(container("bin\\wallpaper64.exe"), depotID: 431960, manifestID: 51, key: key)
        let skipped = parent.appending(path: "skipped")
        try await SteamNativeDownload.materialize(program.files, key: key, in: skipped, path: SteamSceneAssetsDownload.assetsPath) { _ in
        } fetch: { _ in
            XCTFail("Files outside assets must not be fetched")
            return Data()
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: skipped.path), [])
    }

    func testQRRotatesChallengeAndAcceptsOnlyCredentialFromConfirmation() async throws {
        let credentials = "fixture.eyJzdWIiOiI3NjU2MTE5Nzk2MDI2NTcyOSJ9.signature"
        let fixture = QRResponses([
            #"{"response":{"client_id":"42","challenge_url":"https://s.team/q/1/42","request_id":"AQI=","interval":4}}"#,
            #"{"response":{"new_client_id":"43","new_challenge_url":"https://s.team/q/1/43"}}"#,
            #"{"response":{"account_name":"fixture-account","refresh_token":"\#(credentials)"}}"#,
        ])
        let auth = SteamQRSignIn { request, _ in try await fixture.next(request) }
        let initial = try await auth.begin()
        XCTAssertEqual(initial.clientID, 42)
        XCTAssertEqual(initial.interval, 4)
        guard case .waiting(let updated) = try await auth.poll(initial) else { return XCTFail("Expected renewed challenge") }
        XCTAssertEqual(updated.url.absoluteString, "https://s.team/q/1/43")
        XCTAssertEqual(updated.clientID, 43)
        guard case .authorised(let account) = try await auth.poll(updated) else { return XCTFail("Expected an approved test account") }
        XCTAssertEqual(account.steamID, 76561197960265729)
        XCTAssertEqual(account.account, "fixture-account")
        let posted = await fixture.requests
        XCTAssertEqual(posted.map(\.path), [
            "/IAuthenticationService/BeginAuthSessionViaQR/v1",
            "/IAuthenticationService/PollAuthSessionStatus/v1",
            "/IAuthenticationService/PollAuthSessionStatus/v1",
        ])
        XCTAssertEqual(try SteamProto(posted[0].body).number(2), 1)
        XCTAssertEqual(try SteamProto(posted[1].body).bytes(2), Data([1, 2]))
        XCTAssertEqual(try SteamProto(posted[2].body).number(1), 43)
    }

    func testQRRejectsOffSiteChallenge() async {
        let fixture = QRResponses([#"{"response":{"client_id":"42","challenge_url":"https://example.test/q/1/42","request_id":"AQI="}}"#])
        do {
            _ = try await SteamQRSignIn { request, _ in try await fixture.next(request) }.begin()
            XCTFail("Expected an invalid challenge error")
        } catch let error as SteamNativeError {
            XCTAssertEqual(error, .protocolError)
        } catch {
            XCTFail("Unexpected error")
        }
    }

    private func container(_ name: String, encrypted: Bool = false, offset: UInt64 = 0) -> Data {
        var chunk = SteamProto.Writer()
        chunk.bytes(1, fixtureHash)
        chunk.uint(3, offset)
        chunk.uint(4, UInt64(message.count))
        var file = SteamProto.Writer()
        file.string(1, name)
        file.uint(2, UInt64(message.count))
        file.bytes(5, fixtureHash)
        file.bytes(6, chunk.data)
        var payload = SteamProto.Writer()
        payload.bytes(1, file.data)
        var details = SteamProto.Writer()
        details.uint(1, 431960)
        details.uint(2, 51)
        if encrypted { details.uint(4, 1) }
        var manifest = Data()
        func append(_ value: UInt32) {
            var word = value.littleEndian
            Swift.withUnsafeBytes(of: &word) { manifest.append(contentsOf: $0) }
        }
        for (magic, data) in [(UInt32(0x71f617d0), payload.data), (0x1f4812be, details.data), (0x1b81b817, Data())] {
            append(magic)
            append(UInt32(data.count))
            manifest.append(data)
        }
        append(0x32c415ab)
        return manifest
    }

    private actor QRResponses {
        struct Request { let path: String; let body: Data }
        var requests: [Request] = []
        var responses: [String]

        init(_ responses: [String]) { self.responses = responses }

        func next(_ request: URLRequest) throws -> Data {
            guard request.httpMethod == "POST", request.url?.host() == "api.steampowered.com",
                  let url = request.url, let form = request.httpBody.flatMap({ String(data: $0, encoding: .utf8) }),
                  let token = form.split(separator: "=", maxSplits: 1).last?.removingPercentEncoding,
                  let data = Data(base64Encoded: token), !responses.isEmpty else { throw SteamNativeError.protocolError }
            requests.append(Request(path: url.path, body: data))
            return Data(responses.removeFirst().utf8)
        }
    }
}
