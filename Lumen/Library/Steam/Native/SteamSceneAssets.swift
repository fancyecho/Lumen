import Foundation

/// Downloads Wallpaper Engine's shared `assets` folder (shaders, materials, effects) from the
/// app's own depot, so scenes work without borrowing another app's copy. Needs a signed-in
/// account that owns Wallpaper Engine; only files under `assets/` are fetched.
struct SteamSceneAssetsDownload {
    static let appID: UInt64 = 431960
    /// Wallpaper Engine's main Windows content depot, which carries `assets/`. SteamCMD needs the
    /// ID up front; the native client finds the depot from product info instead.
    static let contentDepot: UInt64 = 431961
    /// A file every real assets folder has; it identifies the depot that carries them.
    private static let marker = ["assets", "shaders", "genericimage2.frag"]

    func download(credential: SteamNativeCredential, to destination: URL,
                  progress: @escaping (Double) async -> Void) async throws {
        let cm = try await SteamCM.connect(credential)
        do {
            try await download(through: cm, to: destination, progress: progress)
        } catch {
            await cm.close()
            throw error
        }
        await cm.close()
    }

    private func download(through cm: SteamCM, to destination: URL,
                          progress: @escaping (Double) async -> Void) async throws {
        let appID = Self.appID
        let depots = try SteamAppDepot.parse(try await cm.appInfo(appID: appID))
        guard !depots.isEmpty else { throw SteamNativeError.unsupportedContent }
        var lastError: Error = SteamNativeError.unsupportedContent
        for depot in depots {
            try Task.checkCancellation()
            do {
                let key = try await cm.depotKey(depotID: depot.id, appID: appID)
                var requestCode = SteamProto.Writer()
                requestCode.uint(1, appID)
                requestCode.uint(2, depot.id)
                requestCode.uint(3, depot.manifestID)
                requestCode.string(4, "public")
                let codeResponse = try await cm.service("ContentServerDirectory.GetManifestRequestCode", requestCode)
                guard let code = codeResponse.number(1), code != 0 else { throw SteamNativeError.accessDenied }
                let cdn = try await SteamContentServers(cm: cm, appID: appID, depotID: depot.id)
                let data = try await cdn.fetch("manifest/\(depot.manifestID)/5/\(code)", maxBytes: 64 * 1024 * 1024)
                let manifest = try SteamDepotManifest(data, depotID: depot.id, manifestID: depot.manifestID, key: key)
                guard manifest.files.contains(where: { $0.components.map { $0.lowercased() } == Self.marker }) else { continue }
                try await SteamNativeDownload.materialize(
                    manifest.files, key: key, in: destination,
                    path: Self.assetsPath, progress: progress
                ) { chunk in
                    try await cdn.fetch("chunk/\(chunk.identifier)", maxBytes: chunk.size + 1_048_576)
                }
                guard SceneAssetsLocator.isAssetsFolder(destination) else { throw SteamNativeError.invalidContent }
                return
            } catch let error as SteamNativeError where error == .accessDenied {
                // Depots the account can't read (optional or regional content) aren't the one we need.
                lastError = error
            }
        }
        throw lastError
    }

    /// `assets/shaders/x.frag` → `shaders/x.frag`; everything outside `assets/` is skipped.
    static func assetsPath(_ components: [String]) -> [String]? {
        guard components.count > 1, components[0].lowercased() == "assets" else { return nil }
        return Array(components.dropFirst())
    }
}

/// A depot of a Steam app with a public manifest, from PICS product info.
struct SteamAppDepot: Equatable {
    let id: UInt64
    let manifestID: UInt64
    let size: UInt64

    /// Depots that may carry Windows content, largest first (the main content depot is the big one).
    static func parse(_ buffer: Data) throws -> [SteamAppDepot] {
        var data = buffer
        while data.last == 0 { data.removeLast() }
        let text = String(decoding: data, as: UTF8.self)
        guard let root = SteamKeyValues.parse(text) else { throw SteamNativeError.protocolError }
        let appinfo = root["appinfo"] ?? root
        guard let depots = appinfo["depots"]?.children else { return [] }
        var result: [SteamAppDepot] = []
        for (name, node) in depots {
            guard let id = UInt64(name), node.children != nil else { continue }
            if let oslist = node["config"]?["oslist"]?.value, !oslist.isEmpty,
               !oslist.lowercased().split(separator: ",").contains("windows") { continue }
            // Steam China's separate realm has its own depots that global accounts can't read.
            if let realm = node["config"]?["realm"]?.value, !realm.isEmpty, realm.lowercased() != "steamglobal" { continue }
            // Newer product info nests the manifest under `gid`; older info stores it directly.
            let manifest = node["manifests"]?["public"]
            guard let gid = (manifest?["gid"]?.value ?? manifest?.value).flatMap(UInt64.init), gid != 0 else { continue }
            let size = (manifest?["size"]?.value).flatMap(UInt64.init) ?? 0
            result.append(SteamAppDepot(id: id, manifestID: gid, size: size))
        }
        return result.sorted { ($0.size, $1.id) > ($1.size, $0.id) }
    }
}

/// Valve's text KeyValues ("VDF"): quoted keys mapping to strings or nested `{ }` blocks.
/// Keys are matched case-insensitively, as Steam does.
indirect enum SteamKeyValues {
    case value(String)
    case block([(String, SteamKeyValues)])

    var value: String? {
        if case .value(let text) = self { return text }
        return nil
    }

    var children: [(String, SteamKeyValues)]? {
        if case .block(let entries) = self { return entries }
        return nil
    }

    subscript(key: String) -> SteamKeyValues? {
        children?.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    static func parse(_ text: String) -> SteamKeyValues? {
        var tokens = Tokens(text)
        guard let entries = block(&tokens, nested: false) else { return nil }
        return .block(entries)
    }

    private static func block(_ tokens: inout Tokens, nested: Bool) -> [(String, SteamKeyValues)]? {
        var entries: [(String, SteamKeyValues)] = []
        while let token = tokens.next() {
            switch token {
            case .close:
                return nested ? entries : nil
            case .open:
                return nil
            case .text(let key):
                switch tokens.next() {
                case .text(let value):
                    entries.append((key, .value(value)))
                case .open:
                    guard let inner = block(&tokens, nested: true) else { return nil }
                    entries.append((key, .block(inner)))
                default:
                    return nil
                }
            }
        }
        return nested ? nil : entries
    }

    private enum Token { case text(String), open, close }

    private struct Tokens {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        mutating func next() -> Token? {
            while index < scalars.count {
                let scalar = scalars[index]
                if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    index += 1
                } else if scalar == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else if scalar == "[" {
                    // Platform conditionals such as [$WIN32] don't matter for depot discovery.
                    while index < scalars.count, scalars[index] != "]" { index += 1 }
                    index += 1
                } else {
                    break
                }
            }
            guard index < scalars.count else { return nil }
            let scalar = scalars[index]
            if scalar == "{" { index += 1; return .open }
            if scalar == "}" { index += 1; return .close }
            var text = String.UnicodeScalarView()
            if scalar == "\"" {
                index += 1
                while index < scalars.count, scalars[index] != "\"" {
                    if scalars[index] == "\\", index + 1 < scalars.count {
                        index += 1
                        switch scalars[index] {
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        default: text.append(scalars[index])
                        }
                    } else {
                        text.append(scalars[index])
                    }
                    index += 1
                }
                index += 1
            } else {
                while index < scalars.count, !CharacterSet.whitespacesAndNewlines.contains(scalars[index]),
                      scalars[index] != "{", scalars[index] != "}", scalars[index] != "\"" {
                    text.append(scalars[index])
                    index += 1
                }
            }
            return .text(String(text))
        }
    }
}
