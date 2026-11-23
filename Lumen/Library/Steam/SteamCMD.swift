import Darwin
import Foundation

/// Valve's SteamCMD, installed into Lumen's support folder and driven through a
/// pseudo-terminal so its password and Steam Guard prompts can be answered from Lumen's UI.
/// Passwords are written straight to SteamCMD and never stored; SteamCMD keeps its own
/// login token so later downloads don't ask again.
enum SteamCMD {
    static let folder = AppPaths.root.appending(path: "SteamCMD", directoryHint: .isDirectory)
    static let contentFolder = folder.appending(path: "content", directoryHint: .isDirectory)
    static var script: URL { folder.appending(path: "steamcmd.sh") }
    static let downloadURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: script.path) }

    enum Failure: LocalizedError, Equatable {
        case installFailed(String)
        case invalidPassword
        case guardCodeRejected
        case rateLimited
        case connectionFailed
        case guardRequired
        case accessDenied
        case notSignedIn
        case downloadFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .installFailed(let reason): String(localized: "SteamCMD couldn't be installed: \(reason)")
            case .invalidPassword: String(localized: "Steam didn't accept the password.")
            case .guardCodeRejected: String(localized: "Steam didn't accept the Steam Guard code.")
            case .rateLimited: String(localized: "Steam is limiting sign-in attempts. Wait a while and try again.")
            case .connectionFailed: String(localized: "Steam couldn't connect. Check your network and system HTTP/HTTPS proxy, then try again.")
            case .guardRequired: String(localized: "Steam requires Steam Guard verification. Finish the approval or enter a current code and try again.")
            case .accessDenied: String(localized: "This Steam account can't download it. Workshop downloads need an account that owns Wallpaper Engine.")
            case .notSignedIn: String(localized: "Sign in to Steam first.")
            case .downloadFailed(let reason): String(localized: "The download failed: \(reason)")
            case .cancelled: String(localized: "Cancelled.")
            }
        }

        /// SteamCMD uses the same result names in its terminal and console log.
        static func fromOutput(_ line: String) -> Self? {
            let text = line.lowercased()
            if text.contains("invalid password") || text.contains("invalidpassword") { return .invalidPassword }
            if text.contains("invalid login auth code") || text.contains("two-factor code mismatch")
                || text.contains("invalid two-factor") || text.contains("twofactormismatch") { return .guardCodeRejected }
            if text.contains("rate limit") || text.contains("ratelimit") || text.contains("too many login failures") { return .rateLimited }
            if text.contains("account logon denied") || text.contains("accountlogondenied")
                || text.contains("accountlogonneedtwofactor") || text.contains("steam guard required") { return .guardRequired }
            if text.contains("access denied") || text.contains("no subscription") { return .accessDenied }
            if text.contains("no connection") || text.contains("noconnection") || text.contains("connection failure")
                || text.contains("connection reset") || text.contains("connection timed out") || text.contains("(timeout)")
                || text.hasSuffix(": timeout") || text.hasSuffix(" timeout") || text == "timeout" {
                return .connectionFailed
            }
            return nil
        }

        fileprivate var diagnosticPriority: Int {
            switch self {
            case .downloadFailed: 0
            case .connectionFailed: 1
            default: 2
            }
        }
    }

    /// Pauses before up to three retries, only once the download run has authenticated.
    static func retryDelay(attempt: Int, authenticated: Bool, failure: Failure, cancelled: Bool) -> Duration? {
        let seconds = [2, 8, 30]
        guard !cancelled, authenticated, failure == .connectionFailed, seconds.indices.contains(attempt) else { return nil }
        return .seconds(seconds[attempt])
    }

    /// Downloads and unpacks SteamCMD (about 3 MB; it updates itself on first run).
    static func install() async throws {
        if isInstalled { return }
        let (archive, response) = try await URLSession.shared.download(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.installFailed("HTTP error") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", folder.path]
        try tar.run()
        tar.waitUntilExit()
        try? FileManager.default.removeItem(at: archive)
        guard tar.terminationStatus == 0, isInstalled else { throw Failure.installFailed("unpacking failed") }
    }

    /// Forgets the signed-in account (SteamCMD's cached login).
    static func signOut() {
        for name in ["config/config.vdf", "config/loginusers.vdf", "ssfn"] {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
        if let files = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for file in files where file.hasPrefix("ssfn") {
                try? FileManager.default.removeItem(at: folder.appending(path: file))
            }
        }
    }
}

/// One SteamCMD run. The result includes diagnostics collected before the caller resumes.
final class SteamCMDSession: @unchecked Sendable {
    enum Event {
        case needsPassword
        case needsGuardCode(email: Bool)
        case needsMobileConfirmation
        case loggedIn
        case progress(Double)
        case downloaded(id: String, path: String)
        case failed(SteamCMD.Failure)
    }

    struct Result {
        var status: Int32 = -1
        var loggedIn = false
        var downloads: [String: String] = [:]
        var failure: SteamCMD.Failure?
    }

    private let process = Process()
    private let logURL: URL
    private var master: Int32 = -1
    private var buffer = ""
    private var result = Result()
    private var stopReason: SteamCMD.Failure?
    private let queue = DispatchQueue(label: "app.lumen.steamcmd")
    private var source: DispatchSourceRead?
    var onEvent: (@Sendable (Event) -> Void)?

    init(arguments: [String], script: URL = SteamCMD.script) {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let home = script.deletingLastPathComponent()
        logURL = home.appending(path: "logs/console_log.txt")
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
    }

    func run() async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { self.launch(continuation) }
            }
        } onCancel: {
            cancel()
        }
    }

    private func launch(_ continuation: CheckedContinuation<Result, Never>) {
        if let stopReason {
            continuation.resume(returning: Result(failure: stopReason))
            return
        }
        var masterFD: Int32 = 0, slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else {
            continuation.resume(returning: Result())
            return
        }
        master = masterFD
        _ = fcntl(masterFD, F_SETFL, O_NONBLOCK)
        var tty = termios()
        if tcgetattr(slaveFD, &tty) == 0 {
            tty.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(slaveFD, TCSANOW, &tty)
        }
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave

        let logBefore = ConsoleLogPosition(url: logURL)
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(masterFD) }
        source.resume()
        self.source = source

        process.terminationHandler = { [self] process in
            queue.async {
                self.readAvailable()
                if !self.buffer.isEmpty { _ = self.interpret(self.buffer, complete: true) }
                self.result.status = process.terminationStatus
                if let stopReason = self.stopReason {
                    self.result.failure = stopReason
                } else if process.terminationStatus != 0 || self.result.failure != nil || !self.result.loggedIn {
                    self.readNewDiagnostics(after: logBefore)
                }
                self.closePTY()
                self.process.terminationHandler = nil
                continuation.resume(returning: self.result)
            }
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            closePTY()
            continuation.resume(returning: result)
        }
        try? slave.close()
    }

    func send(_ line: String) {
        queue.async { [weak self] in
            guard let self, self.stopReason == nil, self.master >= 0 else { return }
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBytes { write(self.master, $0.baseAddress, $0.count) }
        }
    }

    func cancel() {
        stop(.cancelled)
    }

    func stop(_ reason: SteamCMD.Failure) {
        queue.async {
            self.stopReason = reason
            if self.process.isRunning { self.process.terminate() }
        }
    }

    private func closePTY() {
        master = -1
        source?.cancel()
        source = nil
    }

    private func readAvailable() {
        guard master >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(master, &bytes, bytes.count)
            guard count > 0 else { break }
            buffer += String(decoding: bytes[0..<count], as: UTF8.self)
            let lines = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            buffer = String((lines.last ?? "").suffix(8192))
            for line in lines.dropLast() where !line.isEmpty { _ = interpret(line, complete: true) }
            if !buffer.isEmpty, interpret(buffer, complete: false) { buffer = "" }
        }
    }

    private func interpret(_ raw: String, complete: Bool) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        if lower.hasSuffix("password:") {
            if result.failure != .invalidPassword { onEvent?(.needsPassword) }
            return true
        }
        if lower.hasSuffix(":"), lower.contains("steam guard code") || lower.contains("two-factor code") || lower.contains("two factor code") {
            onEvent?(.needsGuardCode(email: lower.contains("email")))
            return true
        }
        guard complete else { return false }

        if lower.contains("confirm the login in the steam mobile app") { onEvent?(.needsMobileConfirmation) }
        if !result.loggedIn, lower.contains("logged in ok") || lower.contains("waiting for user info...ok") {
            result.loggedIn = true
            onEvent?(.loggedIn)
        }
        if let failure = SteamCMD.Failure.fromOutput(line) {
            record(failure)
            // Some SteamCMD releases leave the login prompt open after a rejected password.
            if failure == .invalidPassword, process.isRunning { process.terminate() }
            return false
        }
        if let match = line.firstMatch(of: /\[\s*(\d+)%\]/), let percent = Double(match.1) { onEvent?(.progress(percent / 100)) }
        if let match = line.firstMatch(of: /Success\. Downloaded item (\d+) to "(.+)"/) {
            let id = String(match.1), path = String(match.2)
            result.downloads[id] = path
            onEvent?(.downloaded(id: id, path: path))
        } else if line.firstMatch(of: /ERROR! Download item \d+ failed \((.+)\)/) != nil {
            record(.downloadFailed(String(localized: "SteamCMD reported a Workshop download error.")))
        }
        return false
    }

    private func record(_ failure: SteamCMD.Failure) {
        guard result.failure != failure else { return }
        if (result.failure?.diagnosticPriority ?? -1) <= failure.diagnosticPriority { result.failure = failure }
        onEvent?(.failed(failure))
    }

    private struct ConsoleLogPosition {
        let inode: UInt64?
        let size: UInt64

        init(url: URL) {
            let values = try? FileManager.default.attributesOfItem(atPath: url.path)
            inode = (values?[.systemFileNumber] as? NSNumber)?.uint64Value
            size = (values?[.size] as? NSNumber)?.uint64Value ?? 0
        }
    }

    private func readNewDiagnostics(after before: ConsoleLogPosition) {
        let now = ConsoleLogPosition(url: logURL)
        guard now.inode != nil, let file = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? file.close() }
        let since = now.inode == before.inode && now.size >= before.size ? before.size : 0
        let start = max(since, now.size > 65_536 ? now.size - 65_536 : 0)
        guard now.size > start else { return }
        do {
            try file.seek(toOffset: start)
            let data = try file.read(upToCount: Int(now.size - start)) ?? Data()
            for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                if let failure = SteamCMD.Failure.fromOutput(String(line)) { record(failure) }
            }
        } catch {
            // Terminal diagnostics remain authoritative when SteamCMD can't write its log.
        }
    }
}
