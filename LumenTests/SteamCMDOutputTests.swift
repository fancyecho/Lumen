import Foundation
import os
import XCTest

final class SteamCMDOutputTests: XCTestCase {
    func testParsesPromptsWithoutNewlinesAndReportsDownload() async throws {
        let result = try await runTranscript(#"""
        printf 'Password: '
        IFS= read -r -s -t 5 password || exit 10
        [ "$password" = "fixture-password" ] || exit 11
        printf '\nSteam Guard code from your email:'
        IFS= read -r -t 5 code || exit 12
        [ "$code" = "fixture-code" ] || exit 13
        printf 'Confirm the login in the Steam mobile app.\n'
        printf 'Waiting for user info...OK\n'
        printf '[ 45%%] Downloading...\r'
        printf 'Success. Downloaded item 123456 to "/fixture/Workshop Content/123456" (100 bytes)\n'
        """#)

        XCTAssertEqual(result.status, 0)
        let events = result.events
        guard events.count == 6 else { return XCTFail("Expected six SteamCMD events, got \(events)") }
        guard case .needsPassword = events[0],
              case .needsGuardCode(email: true) = events[1],
              case .needsMobileConfirmation = events[2],
              case .loggedIn = events[3],
              case .progress(let fraction) = events[4],
              case .downloaded(let id, let path) = events[5] else {
            return XCTFail("Unexpected SteamCMD events: \(events)")
        }

        XCTAssertEqual(fraction, 0.45, accuracy: 0.0001)
        XCTAssertEqual(id, "123456")
        XCTAssertEqual(path, "/fixture/Workshop Content/123456")
    }

    func testDistinguishesSignInAndWorkshopFailures() async throws {
        let result = try await runTranscript(#"""
        printf 'FAILED (Invalid Password)\n'
        printf 'FAILED (Invalid Two-Factor)\n'
        printf 'FAILED (Rate Limit Exceeded)\n'
        printf 'ERROR! Download item 123456 failed (Timeout)\n'
        exit 5
        """#)

        XCTAssertEqual(result.status, 5)
        let events = result.events
        guard events.count == 4 else { return XCTFail("Expected four SteamCMD failures, got \(events)") }
        guard case .failed(.invalidPassword) = events[0],
              case .failed(.guardCodeRejected) = events[1],
              case .failed(.rateLimited) = events[2],
              case .failed(.downloadFailed(let reason)) = events[3] else {
            return XCTFail("Unexpected SteamCMD failures: \(events)")
        }

        XCTAssertEqual(reason, "Timeout")
    }

    private func runTranscript(_ transcript: String) async throws -> (status: Int32, events: [SteamCMDSession.Event]) {
        let script = try makeFixtureDirectory().appending(path: "fake-steamcmd.sh")
        try transcript.write(to: script, atomically: true, encoding: .utf8)
        let session = SteamCMDSession(arguments: [], script: script)
        let events = OSAllocatedUnfairLock(initialState: [SteamCMDSession.Event]())
        session.onEvent = { [weak session] event in
            if case .output = event { return }
            events.withLock { $0.append(event) }
            switch event {
            case .needsPassword: session?.send("fixture-password")
            case .needsGuardCode: session?.send("fixture-code")
            default: break
            }
        }

        let status = await session.run()
        return (status, events.withLock { $0 })
    }
}
