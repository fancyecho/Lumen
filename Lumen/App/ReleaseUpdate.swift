import Foundation

/// The feed is optional and is only fetched in response to the Check for Updates button.
struct ReleaseUpdate: Decodable {
    let version: String
    let downloadURL: URL
    let notes: String

    private enum FeedError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            String(localized: "Lumen could not read the update information.")
        }
    }

    static var feedURL: URL? {
        let value = Bundle.main.object(forInfoDictionaryKey: "LumenUpdateFeedURL") as? String ?? ""
        return URL(string: value).flatMap(secureURL)
    }

    static func check(_ feed: URL) async throws -> ReleaseUpdate? {
        guard secureURL(feed) != nil,
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        else { throw FeedError.invalidResponse }

        let request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url.flatMap(secureURL) != nil else { throw FeedError.invalidResponse }
        return try availableUpdate(in: data, currentVersion: current)
    }

    static func availableUpdate(in data: Data, currentVersion: String) throws -> ReleaseUpdate? {
        guard let update = try? JSONDecoder().decode(Self.self, from: data),
              let remote = versionParts(update.version),
              let local = versionParts(currentVersion),
              secureURL(update.downloadURL) != nil else { throw FeedError.invalidResponse }
        return local.lexicographicallyPrecedes(remote) ? update : nil
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count ? numbers : nil
    }

    private static func secureURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
