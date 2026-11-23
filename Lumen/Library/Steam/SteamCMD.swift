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

    enum Failure: LocalizedError {
        case installFailed(String)
        case invalidPassword
        case guardCodeRejected
        case rateLimited
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
            case .accessDenied: String(localized: "This Steam account can't download it. Workshop downloads need an account that owns Wallpaper Engine.")
            case .notSignedIn: String(localized: "Sign in to Steam first.")
            case .downloadFailed(let reason): String(localized: "The download failed: \(reason)")
            case .cancelled: String(localized: "Cancelled.")
            }
        }
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

/// One SteamCMD run, reading its output line by line from a pseudo-terminal.
final class SteamCMDSession: @unchecked Sendable {
    enum Event {
        case output(String)
        case needsPassword
        case needsGuardCode(email: Bool)
        case needsMobileConfirmation
        case loggedIn
        case progress(Double)
        case downloaded(id: String, path: String)
        case failed(SteamCMD.Failure)
    }

    private let process = Process()
    private var master: Int32 = -1
    private var buffer = ""
    private let queue = DispatchQueue(label: "app.lumen.steamcmd")
    private var source: DispatchSourceRead?
    var onEvent: (@Sendable (Event) -> Void)?

    init(arguments: [String], script: URL = SteamCMD.script) {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let home = script.deletingLastPathComponent()
        process.currentDirectoryURL = home
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
    }

    /// Starts SteamCMD and returns its exit status when it finishes.
    func run() async -> Int32 {
        var masterFD: Int32 = 0, slaveFD: Int32 = 0
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { return -1 }
        master = masterFD
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave

        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        self.source = source

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] process in
                self?.queue.async {
                    self?.readAvailable()
                    self?.source?.cancel()
                    if let master = self?.master, master >= 0 { close(master) }
                    self?.master = -1
                    continuation.resume(returning: process.terminationStatus)
                }
            }
            do {
                try process.run()
                try? slave.close()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    /// Answers a prompt (password, Steam Guard code).
    func send(_ line: String) {
        queue.async { [weak self] in
            guard let self, self.master >= 0 else { return }
            let data = Array((line + "\n").utf8)
            _ = data.withUnsafeBytes { write(self.master, $0.baseAddress, $0.count) }
        }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }

    private func readAvailable() {
        guard master >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = read(master, &bytes, bytes.count)
        guard count > 0 else { return }
        buffer += String(decoding: bytes[0..<count], as: UTF8.self)
        // Prompts don't end with a newline, so check the unfinished line too.
        var lines = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        let pending = lines.removeLast()
        for line in lines where !line.isEmpty { interpret(line, complete: true) }
        buffer = pending
        if !pending.isEmpty, interpret(pending, complete: false) { buffer = "" }
    }

    /// Returns true when an unfinished line was a prompt that has been handled.
    @discardableResult
    private func interpret(_ raw: String, complete: Bool) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        if complete { onEvent?(.output(line)) }
        if lower.hasSuffix("password:") {
            onEvent?(.needsPassword)
            return true
        }
        if lower.contains("steam guard code") || lower.contains("two-factor code") || lower.contains("two factor code") {
            if lower.hasSuffix(":") || complete {
                onEvent?(.needsGuardCode(email: lower.contains("email")))
                return !complete
            }
        }
        guard complete else { return false }
        if lower.contains("confirm the login in the steam mobile app") { onEvent?(.needsMobileConfirmation) }
        if lower.contains("logged in ok") || lower.contains("waiting for user info...ok") { onEvent?(.loggedIn) }
        if lower.contains("invalid password") { onEvent?(.failed(.invalidPassword)) }
        if lower.contains("invalid login auth code") || lower.contains("two-factor code mismatch") || lower.contains("invalid two-factor") {
            onEvent?(.failed(.guardCodeRejected))
        }
        if lower.contains("rate limit exceeded") { onEvent?(.failed(.rateLimited)) }
        if lower.contains("access denied") || lower.contains("no subscription") { onEvent?(.failed(.accessDenied)) }
        if let match = line.firstMatch(of: /\[\s*(\d+)%\]/), let percent = Double(match.1) { onEvent?(.progress(percent / 100)) }
        if let match = line.firstMatch(of: /Success\. Downloaded item (\d+) to "(.+)"/) {
            onEvent?(.downloaded(id: String(match.1), path: String(match.2)))
        } else if let match = line.firstMatch(of: /ERROR! Download item \d+ failed \((.+)\)/) {
            let reason = String(match.1)
            onEvent?(.failed(reason.lowercased().contains("access denied") ? .accessDenied : .downloadFailed(reason)))
        }
        return false
    }
}
