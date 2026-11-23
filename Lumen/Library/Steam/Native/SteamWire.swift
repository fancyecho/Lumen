import Foundation

enum SteamNativeError: LocalizedError, Equatable {
    case connection
    case signInRequired
    case expired
    case rateLimited
    case accessDenied
    case protocolError
    case invalidContent
    case unsupportedContent
    case keychain
    case service(UInt64)

    var errorDescription: String? {
        switch self {
        case .connection: String(localized: "Steam couldn't connect. Check your network and system proxy.")
        case .signInRequired: String(localized: "Steam sign-in has expired. Sign in again.")
        case .expired: String(localized: "This Steam QR code expired. Create a new code to try again.")
        case .rateLimited: String(localized: "Steam is limiting requests. Wait a while and try again.")
        case .accessDenied: String(localized: "Steam denied access. Check that this account owns Wallpaper Engine and can access the item.")
        case .protocolError: String(localized: "Steam returned an unexpected response.")
        case .invalidContent: String(localized: "The Workshop download did not pass verification.")
        case .unsupportedContent: String(localized: "This Workshop item uses an unsupported download format.")
        case .keychain: String(localized: "Lumen couldn't access its Steam sign-in in Keychain.")
        case .service(let code): String(localized: "Steam returned error \(code).")
        }
    }

    static func result(_ code: UInt64) -> Self {
        switch code {
        case 3, 10, 16, 20, 35, 38: .connection
        case 5, 21, 65, 89: .signInRequired
        case 15, 24, 50: .accessDenied
        case 27: .expired
        case 25, 84: .rateLimited
        default: .service(code)
        }
    }
}

/// Steam's messages use protobuf varints and little-endian fixed-width fields.
struct SteamBytes {
    let data: Data
    private(set) var position = 0

    init(_ data: Data) { self.data = Data(data) }

    var remaining: Int { data.count - position }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw SteamNativeError.protocolError }
        defer { position += count }
        return data.subdata(in: position..<(position + count))
    }

    mutating func littleEndian<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        guard remaining >= MemoryLayout<T>.size else { throw SteamNativeError.protocolError }
        defer { position += MemoryLayout<T>.size }
        return data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: position, as: T.self)) }
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            let byte: UInt8 = try littleEndian()
            guard shift < 63 || byte <= 1 else { throw SteamNativeError.protocolError }
            value |= UInt64(byte & 0x7f) << shift
            if (byte & 0x80) == 0 { return value }
        }
        throw SteamNativeError.protocolError
    }
}

struct SteamProto {
    private enum Value {
        case number(UInt64)
        case bytes(Data)
    }
    private var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        var reader = SteamBytes(data)
        while reader.remaining > 0 {
            let key = try reader.varint()
            let field = key >> 3
            guard field > 0, field <= 0x1fff_ffff else { throw SteamNativeError.protocolError }
            let value: Value
            switch key & 7 {
            case 0: value = .number(try reader.varint())
            case 1: value = .number(try reader.littleEndian(UInt64.self))
            case 2:
                let count = try reader.varint()
                guard count <= UInt64(reader.remaining) else { throw SteamNativeError.protocolError }
                value = .bytes(try reader.take(Int(count)))
            case 5: value = .number(UInt64(try reader.littleEndian(UInt32.self)))
            default: throw SteamNativeError.protocolError
            }
            fields[Int(field), default: []].append(value)
        }
    }

    func number(_ field: Int) -> UInt64? {
        if case .number(let value)? = fields[field]?.last { return value }
        return nil
    }

    func bytes(_ field: Int) -> Data? {
        if case .bytes(let value)? = fields[field]?.last { return value }
        return nil
    }

    func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    func messages(_ field: Int) throws -> [SteamProto] {
        try (fields[field] ?? []).map { value in
            guard case .bytes(let data) = value else { throw SteamNativeError.protocolError }
            return try SteamProto(data)
        }
    }

    struct Writer {
        private(set) var data = Data()

        mutating func uint(_ field: Int, _ value: UInt64) {
            putVarint(UInt64(field) << 3)
            putVarint(value)
        }

        mutating func fixed64(_ field: Int, _ value: UInt64) {
            putVarint((UInt64(field) << 3) | 1)
            data.appendSteamInteger(value)
        }

        mutating func bytes(_ field: Int, _ value: Data) {
            putVarint((UInt64(field) << 3) | 2)
            putVarint(UInt64(value.count))
            data.append(value)
        }

        mutating func string(_ field: Int, _ value: String) {
            bytes(field, Data(value.utf8))
        }

        private mutating func putVarint(_ value: UInt64) {
            var rest = value
            while rest >= 0x80 {
                data.append(UInt8(truncatingIfNeeded: rest) | 0x80)
                rest >>= 7
            }
            data.append(UInt8(rest))
        }
    }
}

extension Data {
    fileprivate mutating func appendSteamInteger<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

struct SteamCMFrame {
    private static let protobufMask: UInt32 = 0x8000_0000
    let message: UInt32
    let header: SteamProto
    let body: Data

    init(_ wire: Data) throws {
        var reader = SteamBytes(wire)
        let kind: UInt32 = try reader.littleEndian()
        guard (kind & Self.protobufMask) != 0 else { throw SteamNativeError.protocolError }
        message = kind & ~Self.protobufMask
        let length: UInt32 = try reader.littleEndian()
        header = try SteamProto(reader.take(Int(length)))
        body = try reader.take(reader.remaining)
    }

    static func make(_ message: UInt32, header: SteamProto.Writer, body: Data) -> Data {
        var wire = Data()
        wire.appendSteamInteger(message | protobufMask)
        wire.appendSteamInteger(UInt32(header.data.count))
        wire.append(header.data)
        wire.append(body)
        return wire
    }
}
