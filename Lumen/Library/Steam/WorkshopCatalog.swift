import AppKit
import Foundation
import ImageIO
import Observation

/// One Wallpaper Engine item as listed on the Steam Workshop.
struct WorkshopListing: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let previewURL: URL?
    let fileSize: Int64
    let tags: [String]
    let subscriptions: Int
    let favorites: Int
    let updated: Date?
    let summary: String
    /// Steam's 0–5 star bucket; nil when the source didn't say.
    var stars: Int?
    var votes: Int?

    var kind: String? { tags.first(where: WorkshopCatalog.kindTags.contains) }
    var ageRating: String? { tags.first(where: WorkshopCatalog.ratingTags.contains) }
    var resolution: String? { tags.first(where: WorkshopCatalog.resolutionTags.contains) }
    var genres: [String] { tags.filter(WorkshopCatalog.genreTags.contains) }
    var features: [String] { tags.filter(WorkshopCatalog.featureTags.contains) }
}

/// Browses the Steam Workshop for Wallpaper Engine without an account or API key.
///
/// Steam's public browse page answers a sort/search/tag query and embeds the page of results —
/// titles, previews, sizes, tags, counts, star ratings and the page count — as JSON for its own
/// renderer, so one request yields a whole page. If that ever changes, the item links on the page
/// plus the keyless `ISteamRemoteStorage/GetPublishedFileDetails` call still work. Only downloading
/// needs the person's own sign-in (handled by `SteamWorkshop`). No cookies are kept and nothing about
/// the person is sent.
enum WorkshopCatalog {
    enum Sort: String, CaseIterable, Identifiable, Sendable {
        case trending, topRated, mostSubscribed, newest, updated
        var id: String { rawValue }

        fileprivate var browseValue: String {
            switch self {
            case .trending: "trend"
            case .topRated: "toprated"
            case .mostSubscribed: "totaluniquesubscribers"
            case .newest: "mostrecent"
            case .updated: "lastupdated"
            }
        }
    }

    enum Period: Int, CaseIterable, Identifiable, Sendable {
        case day = 1, week = 7, month = 30, quarter = 90, halfYear = 180, year = 365, allTime = -1
        var id: Int { rawValue }
    }

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case scene = "Scene", video = "Video", web = "Web"
        var id: String { rawValue }
    }

    enum Rating: String, CaseIterable, Identifiable, Sendable {
        /// Only items their authors rated for everyone.
        case everyone
        /// Also items rated "Questionable". Mature items are never listed.
        case questionable
        var id: String { rawValue }
    }

    struct Query: Hashable, Sendable {
        var text = ""
        var sort: Sort = .trending
        var period: Period = .week
        var kind: Kind?
        var genre: String?
        var resolution: String?
        var features: Set<String> = []
        var rating: Rating = .everyone

        /// Filters beyond type and genre, for the Filters menu's badge.
        var extraFilterCount: Int {
            (resolution == nil ? 0 : 1) + features.count + (rating == .everyone ? 0 : 1)
        }
    }

    struct Page: Sendable {
        let items: [WorkshopListing]
        /// Steam caps browsing at 1000 pages; nil when the page didn't say.
        let pageCount: Int?
        /// Only meaningful for text searches; Steam reports the whole Workshop for plain browsing.
        let resultCount: Int?
        let hasNext: Bool
    }

    // MARK: Wallpaper Engine's tags

    static let kindTags: Set<String> = ["Scene", "Video", "Web", "Application", "Preset"]
    static let ratingTags: Set<String> = ["Everyone", "Questionable", "Mature"]

    /// All of Wallpaper Engine's genre tags, most-used first.
    static let genres = [
        "Anime", "Landscape", "Nature", "Game", "Girls", "Fantasy", "Sci-Fi", "Abstract", "Relaxing", "Pixel art",
        "Cyberpunk", "Music", "Vehicle", "Animal", "Technology", "Cartoon", "Retro", "MMD", "CGI", "Guys",
        "Medieval", "Memes", "Sports", "Television", "Unspecified",
    ]
    static let genreTags = Set(genres)

    /// Resolution tags, grouped as Wallpaper Engine groups them.
    static let resolutionGroups: [(group: String, tags: [String])] = [
        ("Standard", ["1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160"]),
        ("Ultrawide", ["Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440"]),
        ("Dual", ["Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160"]),
        ("Triple", ["Triple 5760 x 1080", "Triple 7680 x 1440", "Triple 11520 x 2160"]),
        ("Portrait", ["Portrait 1080 x 1920", "Portrait 1440 x 2560", "Portrait 2160 x 3840"]),
        ("Other", ["Dynamic resolution", "Other resolution"]),
    ]
    static let resolutionTags: Set<String> = Set(resolutionGroups.flatMap(\.tags)).union([
        "Standard Definition", "Ultrawide Standard Definition", "Dual Standard Definition",
        "Triple Standard Definition", "Portrait Standard Definition", "Portrait 720 x 1280",
    ])

    /// Feature ("Misc") tags people can filter by.
    static let features = [
        "Approved", "Audio responsive", "Customizable", "Media Integration", "Video Texture",
        "Puppet Warp", "3D", "HDR", "User Shortcut",
    ]
    static let featureTags = Set(features)

    // MARK: Fetching

    private static let pageSize = 30
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    static func page(_ query: Query, number: Int) async throws -> Page {
        let html = try await browsePage(query, page: number)
        if let embedded = embeddedResults(in: html) {
            let items = embedded.results.compactMap(listing).filter { allowed($0, rating: query.rating) }
            let searching = !query.text.trimmingCharacters(in: .whitespaces).isEmpty
            return Page(
                items: items,
                pageCount: embedded.pageCount,
                resultCount: searching ? embedded.resultCount : nil,
                hasNext: embedded.pageCount.map { number < $0 } ?? (embedded.results.count >= pageSize)
            )
        }
        // Fallback: item links in the page, then one batched details call.
        var seen = Set<String>()
        let ids = html.matches(of: #/filedetails/\?id=(\d+)/#).compactMap { match -> String? in
            let id = String(match.output.1)
            return seen.insert(id).inserted ? id : nil
        }
        guard !ids.isEmpty else { return Page(items: [], pageCount: nil, resultCount: nil, hasNext: false) }
        let details = try await details(for: ids)
        let items = ids.compactMap { details[$0] }.filter { allowed($0, rating: query.rating) }
        return Page(items: items, pageCount: nil, resultCount: nil, hasNext: ids.count >= pageSize)
    }

    private static func browsePage(_ query: Query, page: Int) async throws -> String {
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sort = text.isEmpty ? query.sort.browseValue : "textsearch"
        var fields: [(String, String)] = [
            ("appid", SteamWorkshop.appID),
            ("section", "readytouseitems"),
            ("browsesort", sort),
            ("actualsort", sort),
            ("numperpage", String(pageSize)),
            ("p", String(max(page, 1))),
        ]
        if !text.isEmpty { fields.append(("searchtext", text)) }
        if sort == "trend" { fields.append(("days", String(query.period.rawValue))) }
        var required: [String] = []
        if let kind = query.kind { required.append(kind.rawValue) }
        if let genre = query.genre { required.append(genre) }
        if let resolution = query.resolution { required.append(resolution) }
        required += query.features.sorted()
        if query.rating == .everyone { required.append("Everyone") }
        fields += required.map { ("requiredtags[]", $0) }
        // Windows-only programs can't run here, and mature items are never shown.
        fields += ["Application", "Mature"].map { ("excludedtags[]", $0) }

        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        components.percentEncodedQuery = fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        guard let url = components.url else { throw WorkshopCatalogError.badResponse }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw WorkshopCatalogError.badResponse }
        return String(decoding: data, as: UTF8.self)
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// The page's query result, which Steam embeds as an escaped JSON string:
    /// `{"eresult":1,"current_page":…,"total_pages":…,"total_count":…,"results":[…]},"dataUpdateCount"…`.
    private static func embeddedResults(in html: String) -> (results: [[String: Any]], pageCount: Int?, resultCount: Int?)? {
        guard let key = html.range(of: #"\"current_page\""#),
              let start = html[..<key.lowerBound].lastIndex(of: "{"),
              let end = html.range(of: #"},\"dataUpdateCount\""#, range: key.upperBound..<html.endIndex)
        else { return nil }
        let escaped = html[start...end.lowerBound]
        guard let text = try? JSONSerialization.jsonObject(with: Data("\"\(escaped)\"".utf8), options: .fragmentsAllowed) as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let results = object["results"] as? [[String: Any]]
        else { return nil }
        return (results, int(object["total_pages"]), int(object["total_count"]))
    }

    // MARK: Details (fallback)

    static func details(for ids: [String]) async throws -> [String: WorkshopListing] {
        guard let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/") else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = ["itemcount=\(ids.count)"]
        for (index, id) in ids.enumerated() { form.append("publishedfileids%5B\(index)%5D=\(id)") }
        request.httpBody = Data(form.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (json["response"] as? [String: Any])?["publishedfiledetails"] as? [[String: Any]]
        else { throw WorkshopCatalogError.badResponse }
        var result: [String: WorkshopListing] = [:]
        for item in list {
            guard int(item["result"]) == 1, int(item["visibility"]) ?? 0 == 0, let listing = listing(item) else { continue }
            result[listing.id] = listing
        }
        return result
    }

    /// Builds a listing from either source; both use Steam's PublishedFileDetails field names.
    private static func listing(_ item: [String: Any]) -> WorkshopListing? {
        guard let id = item["publishedfileid"] as? String, int(item["banned"]) ?? 0 == 0 else { return nil }
        let tags = (item["tags"] as? [[String: Any]])?.compactMap { $0["tag"] as? String } ?? []
        let text = (item["short_description"] as? String) ?? (item["description"] as? String) ?? ""
        return WorkshopListing(
            id: id,
            title: WEProject.plainText(item["title"] as? String ?? id),
            previewURL: (item["preview_url"] as? String).flatMap(URL.init(string:)),
            fileSize: Int64(int(item["file_size"]) ?? 0),
            tags: tags,
            subscriptions: int(item["subscriptions"]) ?? 0,
            favorites: int(item["favorited"]) ?? 0,
            updated: int(item["time_updated"]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            summary: plainDescription(text),
            stars: int(item["star_rating"]),
            votes: int(item["total_votes"])
        )
    }

    /// Steam sends numbers as JSON numbers or as strings depending on the field.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// Descriptions are BBCode; keep readable text only, capped so panels stay tidy.
    private static func plainDescription(_ raw: String) -> String {
        let stripped = raw
            .replacing(#/\[url=[^\]]*\]/#, with: "")
            .replacing(#/\[/?[a-zA-Z0-9*]+(=[^\]]*)?\]/#, with: "")
            .replacing(#/\n{3,}/#, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(900))
    }

    /// A safety net in case the browse page ignores a tag filter.
    private static func allowed(_ item: WorkshopListing, rating: Rating) -> Bool {
        if item.tags.contains("Mature") || item.tags.contains("Application") { return false }
        if rating == .everyone, item.tags.contains("Questionable") { return false }
        return true
    }
}

enum WorkshopCatalogError: LocalizedError {
    case badResponse

    var errorDescription: String? {
        String(localized: "The Steam Workshop didn't answer. Check your connection and try again.")
    }
}

/// Browsing state for the Workshop page, kept on `AppModel` so it survives switching tabs.
/// Results come a page at a time (30 items) so memory stays flat and any page is one jump away.
@MainActor
@Observable
final class WorkshopBrowser {
    var query = WorkshopCatalog.Query() {
        didSet { if query != oldValue { load(page: 1) } }
    }
    /// The item shown in the preview sidebar.
    var selection: WorkshopListing?
    private(set) var items: [WorkshopListing] = []
    private(set) var page = 1
    private(set) var pageCount: Int?
    private(set) var resultCount: Int?
    private(set) var hasNext = false
    private(set) var isLoading = false
    private(set) var error: String?

    private struct Key: Hashable {
        let query: WorkshopCatalog.Query
        let page: Int
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Recently viewed pages, so going back (a page, a filter, a cleared search) is instant.
    @ObservationIgnored private var cache: [Key: WorkshopCatalog.Page] = [:]
    @ObservationIgnored private var cacheOrder: [Key] = []

    var canGoBack: Bool { page > 1 }
    var canGoForward: Bool { pageCount.map { page < $0 } ?? hasNext }

    /// Loads the current page unless it's already showing.
    func start() {
        if items.isEmpty && !isLoading && error == nil { load(page: page) }
    }

    func load(page requested: Int) {
        task?.cancel()
        generation += 1
        let target = max(1, pageCount.map { min(requested, $0) } ?? requested)
        page = target
        error = nil
        if let cached = cache[Key(query: query, page: target)] {
            apply(cached)
            isLoading = false
            return
        }
        items = []
        isLoading = true
        let query = query, generation = generation
        task = Task { [weak self] in
            // A short pause lets fast typing settle before asking Steam.
            if target == 1, !query.text.isEmpty { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            do {
                let result = try await WorkshopCatalog.page(query, number: target)
                guard let self, generation == self.generation else { return }
                apply(result)
                isLoading = false
                remember(result, for: Key(query: query, page: target))
            } catch {
                guard let self, generation == self.generation, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }

    func next() { if canGoForward { load(page: page + 1) } }
    func previous() { if canGoBack { load(page: page - 1) } }

    /// Forgets the cached copy of this page and asks Steam again.
    func refresh() {
        cache[Key(query: query, page: page)] = nil
        load(page: page)
    }

    private func apply(_ result: WorkshopCatalog.Page) {
        items = result.items
        pageCount = result.pageCount
        resultCount = result.resultCount
        hasNext = result.hasNext
    }

    private func remember(_ result: WorkshopCatalog.Page, for key: Key) {
        cache[key] = result
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > 24 { cache[cacheOrder.removeFirst()] = nil }
    }
}

/// Workshop preview images: disk-cached downloads, first frames decoded off the main thread at grid size.
enum WorkshopPreviews {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.lumen.Lumen/WorkshopPreviews", directoryHint: .isDirectory)
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 300 << 20, directory: folder)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
    @MainActor private static let stills = NSCache<NSURL, NSImage>()

    static func data(for url: URL) async -> Data? {
        try? await session.data(from: url).0
    }

    /// The first frame, at most `maxPixel` on its long side.
    @MainActor
    static func still(for url: URL, maxPixel: Int = 640) async -> NSImage? {
        if let cached = stills.object(forKey: url as NSURL) { return cached }
        guard let data = await data(for: url) else { return nil }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        if let image { stills.setObject(image, forKey: url as NSURL) }
        return image
    }
}
