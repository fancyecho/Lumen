import CryptoKit
import Foundation

struct SteamNativeDownload {
    let appID: UInt64

    func download(itemID: UInt64, credential: SteamNativeCredential, to folder: URL,
                  progress: @Sendable (Double) async -> Void) async throws {
        let cm = try await SteamCM.connect(credential)
        do {
            try await download(itemID: itemID, through: cm, to: folder, progress: progress)
        } catch {
            await cm.close()
            throw error
        }
        await cm.close()
    }

    private func download(itemID: UInt64, through cm: SteamCM, to folder: URL,
                          progress: @Sendable (Double) async -> Void) async throws {
        var detailsRequest = SteamProto.Writer()
        detailsRequest.fixed64(1, itemID)
        detailsRequest.uint(14, appID)
        let details = try await cm.service("PublishedFile.GetDetails", detailsRequest)
        guard let item = try details.messages(1).first(where: { $0.number(2) == itemID }) else {
            throw SteamNativeError.protocolError
        }
        if let result = item.number(1), result != 1 { throw SteamNativeError.result(result) }
        guard item.number(5) == appID, let manifestID = item.number(14), manifestID != 0 else {
            throw SteamNativeError.unsupportedContent
        }

        var requestCode = SteamProto.Writer()
        requestCode.uint(1, appID)
        requestCode.uint(2, appID)
        requestCode.uint(3, manifestID)
        let codeResponse = try await cm.service("ContentServerDirectory.GetManifestRequestCode", requestCode)
        guard let code = codeResponse.number(1), code != 0 else { throw SteamNativeError.accessDenied }

        let key = try await cm.depotKey(appID: appID)
        var cdn = try await SteamContentServers(cm: cm, appID: appID)
        let data = try await cdn.fetch("manifest/\(manifestID)/5/\(code)", maxBytes: 64 * 1024 * 1024)
        let manifest = try SteamDepotManifest(data, depotID: appID, manifestID: manifestID, key: key)
        try await Self.materialize(manifest, key: key, in: folder, progress: progress) { chunk in
            try await cdn.fetch("chunk/\(chunk.identifier)", maxBytes: chunk.size + 1_048_576)
        }
    }

    static func materialize(_ manifest: SteamDepotManifest, key: Data, in folder: URL,
                            progress: (Double) async -> Void,
                            fetch: (SteamDepotManifest.Chunk) async throws -> Data) async throws {
        // The caller gives each download a fresh directory; no preexisting links or files are reused.
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw SteamNativeError.invalidContent }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var delivered: UInt64 = 0
        for item in manifest.files {
            try Task.checkCancellation()
            let target = item.components.reduce(folder) { $0.appending(path: $1) }
            if item.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: target.path),
                  FileManager.default.createFile(atPath: target.path, contents: nil) else {
                throw SteamNativeError.invalidContent
            }
            let file = try FileHandle(forWritingTo: target)
            defer { try? file.close() }
            var hash = Insecure.SHA1()
            for chunk in item.chunks {
                try Task.checkCancellation()
                let sealed = try await fetch(chunk)
                let compressed = try SteamDepotCipher.decrypt(sealed, key: key)
                let content = try SteamCompression.chunk(compressed, size: chunk.size)
                try chunk.verify(content)
                try file.write(contentsOf: content)
                hash.update(data: content)
                delivered += UInt64(content.count)
                await progress(Double(delivered) / Double(max(manifest.size, 1)))
            }
            if let expected = item.hash, Data(hash.finalize()) != expected {
                throw SteamNativeError.invalidContent
            }
        }
        guard WEProject.isProjectFolder(folder) else { throw SteamNativeError.invalidContent }
    }
}

private struct SteamContentServers {
    private let cm: SteamCM
    private let appID: UInt64
    private var hosts: [String]
    private var authorisations: [String: String] = [:]

    init(cm: SteamCM, appID: UInt64) async throws {
        self.cm = cm
        self.appID = appID
        var request = SteamProto.Writer()
        request.uint(1, await cm.cellID())
        request.uint(2, 20)
        let response = try await cm.service("ContentServerDirectory.GetServersForSteamPipe", request)
        var unique = Set<String>()
        hosts = try response.messages(1).compactMap { item in
            guard item.number(7) != 1, item.number(10) != 1, item.string(12)?.lowercased() != "none",
                  let host = item.string(9) ?? item.string(8), Self.isSteamHost(host),
                  unique.insert(host).inserted else { return nil }
            return host
        }
        guard !hosts.isEmpty else { throw SteamNativeError.connection }
    }

    mutating func fetch(_ path: String, maxBytes: Int) async throws -> Data {
        var error: Error = SteamNativeError.connection
        for host in Array(hosts.prefix(5)) {
            try Task.checkCancellation()
            do {
                let data = try await fetch(path, host: host, maxBytes: maxBytes)
                // Keep the reachable server first; an unreachable server shouldn't delay each chunk.
                hosts.removeAll { $0 == host }
                hosts.insert(host, at: 0)
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch SteamNativeError.rateLimited {
                throw SteamNativeError.rateLimited
            } catch let failure {
                error = failure
            }
        }
        throw error
    }

    private mutating func fetch(_ path: String, host: String, maxBytes: Int) async throws -> Data {
        do {
            return try await fetch(path, host: host, token: authorisations[host], maxBytes: maxBytes)
        } catch SteamNativeError.accessDenied {
            var request = SteamProto.Writer()
            request.uint(1, appID)
            request.string(2, host)
            request.uint(3, appID)
            let reply = try await cm.service("ContentServerDirectory.GetCDNAuthToken", request)
            guard let token = reply.string(1), !token.isEmpty else { throw SteamNativeError.accessDenied }
            authorisations[host] = token
            return try await fetch(path, host: host, token: token, maxBytes: maxBytes)
        }
    }

    private func fetch(_ path: String, host: String, token: String?, maxBytes: Int) async throws -> Data {
        var endpoint = URLComponents()
        endpoint.scheme = "https"
        endpoint.host = host
        endpoint.path = "/depot/\(appID)/\(path)"
        if let token {
            let query = token.hasPrefix("?") ? String(token.dropFirst()) : token
            guard let parameters = URLComponents(string: "?\(query)"), parameters.fragment == nil,
                  let items = parameters.queryItems, !items.isEmpty else { throw SteamNativeError.protocolError }
            endpoint.queryItems = items
        }
        guard let url = endpoint.url else { throw SteamNativeError.protocolError }
        return try await SteamNativeHTTP.shared.data(URLRequest(url: url), maxBytes: maxBytes)
    }

    private static func isSteamHost(_ value: String) -> Bool {
        let host = value.lowercased()
        return host.hasSuffix(".steamcontent.com")
            && host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }
}
