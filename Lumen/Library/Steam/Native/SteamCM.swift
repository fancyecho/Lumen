import Foundation

/// One short-lived Steam Connection Manager session per Workshop transfer.
actor SteamCM {
    private enum Message: UInt32 {
        case multi = 1
        case serviceResponse = 147
        case serviceCall = 151
        case heartbeat = 703
        case logonResponse = 751
        case loggedOff = 757
        case depotKey = 5438
        case depotKeyResponse = 5439
        case logon = 5514
        case hello = 9805
    }

    private struct Directory: Decodable {
        struct Response: Decodable {
            struct Server: Decodable { let endpoint: String }
            let serverlist: [Server]
        }
        let response: Response
    }

    private static let protocolVersion: UInt64 = 65_580
    private let socket: URLSessionWebSocketTask
    private var sessionID: UInt64 = 0
    private var steamID: UInt64 = 0
    private var serverCellID: UInt64 = 0
    private var nextJob: UInt64 = 1
    private var inbox: ArraySlice<SteamCMFrame> = []
    private var heartbeats: Task<Void, Never>?

    private init(url: URL) {
        socket = SteamNativeHTTP.shared.webSocket(url)
    }

    static func connect(_ credential: SteamNativeCredential) async throws -> SteamCM {
        var url = URLComponents(url: SteamNativeHTTP.api.appending(path: "ISteamDirectory/GetCMListForConnect/v1/"),
                                resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "cellid", value: "0"), URLQueryItem(name: "cmtype", value: "websockets")]
        let body = try await SteamNativeHTTP.shared.data(URLRequest(url: url.url!), maxBytes: 512 * 1024)
        let directory = try JSONDecoder().decode(Directory.self, from: body)
        let candidates = directory.response.serverlist.compactMap { server -> URL? in
            guard let endpoint = URL(string: "wss://\(server.endpoint)/cmsocket/"),
                  let host = endpoint.host(), host.hasSuffix(".steamserver.net"),
                  endpoint.path == "/cmsocket/", endpoint.user() == nil, endpoint.query == nil,
                  endpoint.fragment == nil, endpoint.port == nil || endpoint.port == 443 else { return nil }
            return endpoint
        }
        for candidate in candidates.prefix(3) {
            try Task.checkCancellation()
            let cm = SteamCM(url: candidate)
            do {
                try await cm.logon(credential)
                return cm
            } catch SteamNativeError.connection {
                await cm.close()
            } catch {
                await cm.close()
                throw error
            }
        }
        throw SteamNativeError.connection
    }

    private func logon(_ credential: SteamNativeCredential) async throws {
        socket.resume()
        var hello = SteamProto.Writer()
        hello.uint(1, Self.protocolVersion)
        try await send(.hello, body: hello.data)
        steamID = credential.steamID
        var body = SteamProto.Writer()
        body.uint(1, Self.protocolVersion)
        body.string(6, "english")
        body.uint(8, 1)
        body.string(50, credential.account)
        body.string(96, "Lumen")
        body.uint(102, 1)
        body.string(108, credential.refreshToken)
        try await send(.logon, body: body.data)
        let response = try await reply(.logonResponse)
        let fields = try SteamProto(response.body)
        let status = fields.number(1) ?? 2
        guard status == 1 else { throw SteamNativeError.result(status) }
        guard let id = response.header.number(2), id != 0 else { throw SteamNativeError.protocolError }
        sessionID = id
        steamID = response.header.number(1) ?? steamID
        serverCellID = fields.number(7) ?? 0
        let interval = min(max(fields.number(3) ?? 30, 5), 120)
        heartbeats = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Int(interval)))
                    guard let self else { return }
                    try await self.send(.heartbeat, body: Data())
                } catch {
                    return
                }
            }
        }
    }

    func cellID() -> UInt64 { serverCellID }

    func close() {
        heartbeats?.cancel()
        heartbeats = nil
        socket.cancel(with: .normalClosure, reason: nil)
    }

    func service(_ method: String, _ body: SteamProto.Writer) async throws -> SteamProto {
        let job = reserveJob()
        try await send(.serviceCall, body: body.data, job: job, service: method + "#1")
        let response = try await reply(.serviceResponse, job: job)
        if let code = response.header.number(13), code != 1 { throw SteamNativeError.result(code) }
        return try SteamProto(response.body)
    }

    func depotKey(appID: UInt64) async throws -> Data {
        var body = SteamProto.Writer()
        // SteamPipe Workshop depots use the consumer app ID as their depot ID.
        body.uint(1, appID)
        body.uint(2, appID)
        let job = reserveJob()
        try await send(.depotKey, body: body.data, job: job)
        let response = try await reply(.depotKeyResponse, job: job)
        let fields = try SteamProto(response.body)
        let code = fields.number(1) ?? 2
        guard code == 1 else { throw SteamNativeError.result(code) }
        guard fields.number(2) == appID, let key = fields.bytes(3), key.count == 32 else {
            throw SteamNativeError.protocolError
        }
        return key
    }

    private func reserveJob() -> UInt64 {
        defer { nextJob &+= 1 }
        return nextJob
    }

    private func send(_ message: Message, body: Data, job: UInt64? = nil, service: String? = nil) async throws {
        var header = SteamProto.Writer()
        if steamID != 0 { header.fixed64(1, steamID) }
        header.uint(2, sessionID)
        if let job { header.fixed64(10, job) }
        if let service { header.string(12, service) }
        do {
            try await socket.send(.data(SteamCMFrame.make(message.rawValue, header: header, body: body)))
        } catch {
            try Task.checkCancellation()
            throw SteamNativeError.connection
        }
    }

    private func reply(_ message: Message, job: UInt64? = nil) async throws -> SteamCMFrame {
        let duration = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < duration {
            if inbox.isEmpty {
                let raw = try await receive(until: duration)
                inbox = try Self.decode(raw)[...]
                continue
            }
            let frame = inbox.removeFirst()
            if frame.message == Message.loggedOff.rawValue {
                let status = try SteamProto(frame.body).number(1) ?? 21
                throw SteamNativeError.result(status)
            }
            if let job, frame.header.number(11) != job { continue }
            if frame.message == message.rawValue { return frame }
        }
        throw SteamNativeError.connection
    }

    private func receive(until deadline: ContinuousClock.Instant) async throws -> Data {
        let socket = self.socket
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    do {
                        guard case .data(let bytes) = try await socket.receive() else { throw SteamNativeError.protocolError }
                        return bytes
                    } catch let error as SteamNativeError {
                        throw error
                    } catch {
                        try Task.checkCancellation()
                        throw SteamNativeError.connection
                    }
                }
                group.addTask {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    socket.cancel(with: .goingAway, reason: nil)
                    throw SteamNativeError.connection
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw SteamNativeError.connection }
                return result
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    static func decode(_ raw: Data, depth: Int = 0) throws -> [SteamCMFrame] {
        guard depth < 4, raw.count >= 4 else { throw SteamNativeError.protocolError }
        var initial = SteamBytes(raw)
        let flags: UInt32 = try initial.littleEndian()
        // Other client notification types use legacy headers and are irrelevant here.
        guard (flags & 0x8000_0000) != 0 else { return [] }
        let frame = try SteamCMFrame(raw)
        guard frame.message == Message.multi.rawValue else { return [frame] }
        let multi = try SteamProto(frame.body)
        guard let payload = multi.bytes(2) else { throw SteamNativeError.protocolError }
        let size = multi.number(1) ?? 0
        guard size <= 32 * 1024 * 1024 else { throw SteamNativeError.protocolError }
        var parts = SteamBytes(size == 0 ? payload : try SteamCompression.inflate(payload, size: Int(size), gzip: true))
        var result: [SteamCMFrame] = []
        while parts.remaining > 0 {
            let length: UInt32 = try parts.littleEndian()
            result.append(contentsOf: try decode(parts.take(Int(length)), depth: depth + 1))
            guard result.count <= 4096 else { throw SteamNativeError.protocolError }
        }
        return result
    }
}
