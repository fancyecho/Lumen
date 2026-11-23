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
              case .failed(.connectionFailed) = events[3] else {
            return XCTFail("Unexpected SteamCMD failures: \(events)")
        }

    }

    func testReadsOnlyNewConsoleDiagnosticsWhenTheTerminalIsGeneric() async throws {
        let output = try await runTranscript(#"""
        printf '[fixture] Steam login failed: No Connection\n' >> logs/console_log.txt
        printf 'SteamCMD could not complete the request.\n'
        exit 5
        """#, previousLog: "FAILED (Invalid Password)\n")
        XCTAssertEqual(output.result.failure, .connectionFailed)
        XCTAssertFalse(output.result.loggedIn)

        let silent = try await runTranscript("exit 5", previousLog: "FAILED (Rate Limit Exceeded)\n")
        XCTAssertNil(silent.result.failure)
    }

    func testSignalsGuardAndRetriesOnlyNetworkFailuresAfterLogin() {
        XCTAssertEqual(SteamCMD.Failure.fromOutput("FAILED (AccountLogonDenied)"), .guardRequired)
        XCTAssertEqual(SteamCMD.Failure.fromOutput("FAILED (RateLimitExceeded)"), .rateLimited)
        for (attempt, seconds) in [2, 8, 30].enumerated() {
            XCTAssertEqual(SteamCMD.retryDelay(attempt: attempt, authenticated: true, failure: .connectionFailed,
                                               cancelled: false), .seconds(seconds))
        }
        XCTAssertNil(SteamCMD.retryDelay(attempt: 3, authenticated: true, failure: .connectionFailed, cancelled: false))
        XCTAssertNil(SteamCMD.retryDelay(attempt: 0, authenticated: false, failure: .connectionFailed, cancelled: false))
        XCTAssertNil(SteamCMD.retryDelay(attempt: 0, authenticated: true, failure: .invalidPassword, cancelled: false))
        XCTAssertNil(SteamCMD.retryDelay(attempt: 0, authenticated: true, failure: .connectionFailed, cancelled: true))
    }

    func testStopsAfterRejectedPassword() async throws {
        let output = try await runTranscript(#"""
        printf 'Password: '
        IFS= read -r -t 5 password || exit 10
        printf '\nFAILED (Invalid Password)\nPassword: '
        IFS= read -r -t 5 second || exit 5
        exit 20
        """#)
        XCTAssertEqual(output.result.failure, .invalidPassword)
        let requests = output.events.filter { if case .needsPassword = $0 { true } else { false } }
        XCTAssertEqual(requests.count, 1)
    }

    private func runTranscript(_ transcript: String, previousLog: String? = nil) async throws
        -> (status: Int32, result: SteamCMDSession.Result, events: [SteamCMDSession.Event]) {
        let folder = try makeFixtureDirectory()
        let script = folder.appending(path: "fake-steamcmd.sh")
        if let previousLog {
            let logs = folder.appending(path: "logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try previousLog.write(to: logs.appending(path: "console_log.txt"), atomically: true, encoding: .utf8)
        }
        try transcript.write(to: script, atomically: true, encoding: .utf8)
        let session = SteamCMDSession(arguments: [], script: script)
        let events = OSAllocatedUnfairLock(initialState: [SteamCMDSession.Event]())
        session.onEvent = { [weak session] event in
            events.withLock { $0.append(event) }
            switch event {
            case .needsPassword: session?.send("fixture-password")
            case .needsGuardCode: session?.send("fixture-code")
            default: break
            }
        }

        let result = await session.run()
        return (result.status, result, events.withLock { $0 })
    }
}
