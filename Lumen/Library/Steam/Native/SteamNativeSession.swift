import Foundation
import Security

struct SteamNativeCredential: Codable, Sendable {
    let account: String
    let steamID: UInt64
    let refreshToken: String

    init(account: String, refreshToken: String) throws {
        let segments = refreshToken.split(separator: ".", omittingEmptySubsequences: false)
        guard !account.isEmpty, segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else {
            throw SteamNativeError.protocolError
        }
        let claim = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - claim.count % 4) % 4
        guard let data = Data(base64Encoded: claim + String(repeating: "=", count: padding)),
              let subject = try JSONDecoder().decode(Claims.self, from: data).subject,
              let steamID = UInt64(subject), steamID > 0 else { throw SteamNativeError.protocolError }
        // Steam verifies the token at CM logon. The subject is only used to route that packet.
        self.account = account
        self.steamID = steamID
        self.refreshToken = refreshToken
    }

    private struct Claims: Decodable {
        let subject: String?
        enum CodingKeys: String, CodingKey { case subject = "sub" }
    }
}

enum SteamNativeKeychain {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.lumen.steam-client",
            kSecAttrAccount as String: "refresh-token",
        ]
    }

    static func load() throws -> SteamNativeCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        switch SecItemCopyMatching(request as CFDictionary, &value) {
        case errSecItemNotFound: return nil
        case errSecSuccess:
            guard let data = value as? Data else { throw SteamNativeError.keychain }
            return try JSONDecoder().decode(SteamNativeCredential.self, from: data)
        default: throw SteamNativeError.keychain
        }
    }

    static func store(_ credential: SteamNativeCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw SteamNativeError.keychain }
        var item = query
        item.merge(attributes) { _, value in value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SteamNativeError.keychain }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SteamNativeError.keychain }
    }
}

final class SteamNativeHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SteamNativeHTTP()
    static let api = URL(string: "https://api.steampowered.com")!

    // The default proxy selection is retained. No cookies, URL cache or credentials survive a run.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func webSocket(_ url: URL) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        return task
    }

    func data(_ request: URLRequest, maxBytes: Int) async throws -> Data {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            try Task.checkCancellation()
            throw SteamNativeError.connection
        }
        guard let http = response as? HTTPURLResponse else { throw SteamNativeError.protocolError }
        if http.statusCode == 429 { throw SteamNativeError.rateLimited }
        if http.statusCode == 401 || http.statusCode == 403 { throw SteamNativeError.accessDenied }
        if http.statusCode >= 500 { throw SteamNativeError.connection }
        guard http.statusCode == 200, http.expectedContentLength <= Int64(maxBytes) else { throw SteamNativeError.protocolError }
        if let header = http.value(forHTTPHeaderField: "x-eresult"),
           let code = UInt64(header), code != 1 {
            throw SteamNativeError.result(code)
        }
        // Keep upper bounds even when HTTP uses transfer encoding instead of a content length.
        var data = Data()
        if http.expectedContentLength > 0 { data.reserveCapacity(Int(http.expectedContentLength)) }
        do {
            for try await byte in bytes {
                guard data.count < maxBytes else { throw SteamNativeError.protocolError }
                data.append(byte)
            }
        } catch let error as SteamNativeError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw SteamNativeError.connection
        }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        completionHandler(request.url?.scheme == "https" && request.url?.host() == original?.host()
                          && request.url?.port == original?.port ? request : nil)
    }
}

struct SteamQRSignIn {
    struct Challenge {
        var clientID: UInt64
        let requestID: Data
        var url: URL
        let interval: Double
    }

    enum Poll {
        case waiting(Challenge)
        case authorised(SteamNativeCredential)
    }

    private struct Envelope: Decodable {
        let response: Reply
    }

    private struct Reply: Decodable {
        var clientID: String?
        var requestID: Data?
        var challengeURL: String?
        var interval: Double?
        var newClientID: String?
        var newChallengeURL: String?
        var account: String?
        var refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id", requestID = "request_id", challengeURL = "challenge_url", interval
            case newClientID = "new_client_id", newChallengeURL = "new_challenge_url"
            case account = "account_name", refreshToken = "refresh_token"
        }
    }

    private let request: @Sendable (URLRequest, Int) async throws -> Data

    init(request: @escaping @Sendable (URLRequest, Int) async throws -> Data = { request, limit in
        try await SteamNativeHTTP.shared.data(request, maxBytes: limit)
    }) {
        self.request = request
    }

    func begin() async throws -> Challenge {
        var device = SteamProto.Writer()
        device.string(1, "Lumen")
        device.uint(2, 1) // Steam Client token audience
        var input = SteamProto.Writer()
        input.string(1, "Lumen")
        input.uint(2, 1)
        input.bytes(3, device.data)
        input.string(4, "Client")
        let reply = try await call("BeginAuthSessionViaQR", input.data)
        guard let id = reply.clientID.flatMap(UInt64.init), id > 0,
              let requestID = reply.requestID, !requestID.isEmpty,
              let url = Self.challengeURL(reply.challengeURL) else { throw SteamNativeError.protocolError }
        let interval = reply.interval ?? 5
        guard interval.isFinite else { throw SteamNativeError.protocolError }
        return Challenge(clientID: id, requestID: requestID, url: url, interval: min(max(interval, 1), 20))
    }

    func poll(_ challenge: Challenge) async throws -> Poll {
        var input = SteamProto.Writer()
        input.uint(1, challenge.clientID)
        input.bytes(2, challenge.requestID)
        let reply: Reply
        do {
            reply = try await call("PollAuthSessionStatus", input.data)
        } catch SteamNativeError.service(22) {
            return .waiting(challenge)
        }
        if let token = reply.refreshToken, let account = reply.account {
            return .authorised(try SteamNativeCredential(account: account, refreshToken: token))
        }
        var waiting = challenge
        if let newID = reply.newClientID, let id = UInt64(newID), id > 0 { waiting.clientID = id }
        if let newURL = reply.newChallengeURL {
            guard let url = Self.challengeURL(newURL) else { throw SteamNativeError.protocolError }
            waiting.url = url
        }
        return .waiting(waiting)
    }

    private func call(_ method: String, _ data: Data) async throws -> Reply {
        let url = SteamNativeHTTP.api.appending(path: "IAuthenticationService/\(method)/v1/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let value = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        request.httpBody = Data("input_protobuf_encoded=\(value)".utf8)
        let data = try await self.request(request, 65_536)
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).response
        } catch {
            throw SteamNativeError.protocolError
        }
    }

    private static func challengeURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https", url.host() == "s.team",
              url.path.hasPrefix("/q/"), url.user() == nil, url.password() == nil, url.port == nil else { return nil }
        return url
    }
}
