import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// A published Lumen release, read from the GitHub Releases API.
struct LumenRelease: Equatable {
    let version: String
    let notes: String
    let pageURL: URL
    /// `Lumen-<version>.zip`, the archive the updater installs.
    let archiveURL: URL
    /// `Lumen-<version>.zip.sha256`, as written by `Tools/release.sh`.
    let checksumURL: URL

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Parses `releases/latest`. Returns nil for drafts, pre-releases and releases without the
    /// zip and its checksum (older releases shipped only a DMG).
    static func parse(_ data: Data) throws -> LumenRelease? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true else { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard AppUpdater.versionParts(version) != nil else { return nil }
        let archiveName = "Lumen-\(version).zip"
        guard let archive = payload.assets.first(where: { $0.name == archiveName }),
              let checksum = payload.assets.first(where: { $0.name == archiveName + ".sha256" }),
              AppUpdater.isSecure(archive.browser_download_url), AppUpdater.isSecure(checksum.browser_download_url)
        else { return nil }
        return LumenRelease(version: version, notes: payload.body ?? "", pageURL: payload.html_url,
                            archiveURL: archive.browser_download_url, checksumURL: checksum.browser_download_url)
    }
}

/// Checks GitHub Releases for a newer Lumen and installs it in place.
///
/// Releases are ad-hoc signed (no Developer ID), so an update is trusted by where it comes from
/// and what it is: it's downloaded over HTTPS from the project's GitHub releases, must match the
/// SHA-256 published with it, must carry a valid code signature and Lumen's bundle identifier and
/// the advertised version, and, when the running copy is signed with a certificate, must satisfy
/// the running copy's designated requirement. The swap happens after Lumen quits, from a short
/// shell script that puts the old copy back if the move fails.
@MainActor
@Observable
final class AppUpdater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(LumenRelease)
        case installing(LumenRelease)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Called when an automatic check finds a release, for a toast.
    @ObservationIgnored var onAutomaticFind: ((LumenRelease) -> Void)?

    static let automaticKey = "updates.checkAutomatically"
    private static let lastCheckKey = "updates.lastCheck"

    private var repository: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "LumenUpdateRepository") as? String ?? ""
        return value.isEmpty ? "fancyecho/Lumen" : value
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var available: LumenRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// At most one request a day, and only when the user hasn't turned automatic checks off.
    func checkAutomaticallyIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.automaticKey) as? Bool ?? true else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        Task {
            await check()
            if let release = available { onAutomaticFind?(release) }
        }
    }

    func check() async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        do {
            guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { throw UpdateError.unreadable }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Lumen-Updater", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError.unreadable }
            if http.statusCode == 404 { state = .upToDate; return }
            guard http.statusCode == 200 else { throw UpdateError.unreadable }
            if let release = try LumenRelease.parse(data), Self.isNewer(release.version, than: currentVersion) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Downloads, verifies and stages the release, then quits; the new copy opens by itself.
    func install(_ release: LumenRelease) async {
        state = .installing(release)
        do {
            let target = Bundle.main.bundleURL
            let parent = target.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable }
            let staged = try await Self.download(release)
            try Self.verify(staged, version: release.version)
            try Self.relaunch(replacing: target, with: staged)
            NSApp.terminate(nil)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Steps

    private static func download(_ release: LumenRelease) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LumenUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: release.checksumURL)
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = String(data: checksumData, encoding: .utf8)?.split(separator: " ").first.map(String.init)?.lowercased(),
              expected.count == 64 else { throw UpdateError.unreadable }
        let (downloaded, response) = try await URLSession.shared.download(from: release.archiveURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unreadable }
        let archive = folder.appending(path: "Lumen.zip")
        try FileManager.default.moveItem(at: downloaded, to: archive)
        let digest = try SHA256.hash(data: Data(contentsOf: archive, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw UpdateError.checksumMismatch }
        let expanded = folder.appending(path: "expanded", directoryHint: .isDirectory)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path])
        let app = expanded.appending(path: "Lumen.app", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError.invalidApp }
        return app
    }

    private static func verify(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
        else { throw UpdateError.invalidApp }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), nil) == errSecSuccess
        else { throw UpdateError.invalidSignature }
        // An ad-hoc requirement names this exact build, so only a certificate-signed copy can
        // require the same signer of its successor.
        var running: SecCode?
        var runningStatic: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
              SecCodeCopySigningInformation(runningStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32,
              flags & SecCodeSignatureFlags.adhoc.rawValue == 0
        else { return }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(runningStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
        else { throw UpdateError.invalidSignature }
    }

    private static func relaunch(replacing target: URL, with staged: URL) throws {
        let backup = target.deletingLastPathComponent().appending(path: ".Lumen-previous-\(UUID().uuidString).app")
        let script = staged.deletingLastPathComponent().deletingLastPathComponent().appending(path: "install.sh")
        try """
        #!/bin/sh
        # Wait for Lumen to quit, swap in the new copy (restoring the old one on failure), reopen.
        pid="$1"; new="$2"; target="$3"; backup="$4"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        if mv "$target" "$backup"; then
          if mv "$new" "$target"; then
            rm -rf "$backup"
          else
            mv "$backup" "$target"
          fi
        fi
        open "$target"
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, target.path, backup.path]
        try process.run()
    }

    // MARK: Helpers

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidApp }
        return process.terminationStatus
    }

    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let remote = versionParts(remote), let local = versionParts(local) else { return false }
        return local.lexicographicallyPrecedes(remote)
    }

    nonisolated static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count ? numbers : nil
    }

    nonisolated static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }

    private enum UpdateError: LocalizedError {
        case unreadable, checksumMismatch, invalidApp, invalidSignature, notWritable

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "Lumen could not read the update information.")
            case .checksumMismatch: String(localized: "The downloaded update didn't match its checksum, so Lumen didn't install it.")
            case .invalidApp: String(localized: "The downloaded update isn't a valid copy of Lumen.")
            case .invalidSignature: String(localized: "The downloaded update's code signature couldn't be verified.")
            case .notWritable: String(localized: "Lumen can't replace itself in this folder. Download the update from the release page instead.")
            }
        }
    }
}
