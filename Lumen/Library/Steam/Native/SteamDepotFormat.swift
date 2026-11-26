import CommonCrypto
import CryptoKit
import Foundation
import zlib
#if canImport(LumenArchive)
import LumenArchive
#endif
#if canImport(libzstd)
import libzstd
#endif

enum SteamCompression {
    static func inflate(_ data: Data, size: Int, gzip: Bool) throws -> Data {
        guard size > 0, let inputSize = uInt(exactly: data.count), let outputSize = uInt(exactly: size) else {
            throw SteamNativeError.invalidContent
        }
        var output = Data(count: size)
        var stream = z_stream()
        let windowBits: Int32 = gzip ? 31 : -15
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw SteamNativeError.invalidContent
        }
        defer { inflateEnd(&stream) }
        let status = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = inputSize
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = outputSize
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, stream.total_out == size, stream.avail_in == 0 else {
            throw SteamNativeError.invalidContent
        }
        return output
    }

    /// A whole gzip file; its trailer records the uncompressed size (mod 2³², ample here).
    static func gunzip(_ data: Data, maxBytes: Int) throws -> Data {
        guard data.count >= 18 else { throw SteamNativeError.invalidContent }
        var trailer = SteamBytes(data.suffix(4))
        let size = Int(try trailer.littleEndian(UInt32.self))
        guard size > 0, size <= maxBytes else { throw SteamNativeError.invalidContent }
        return try inflate(data, size: size, gzip: true)
    }

    /// SteamPipe uses single-entry ZIP archives for manifests and some older chunks.
    static func zipEntry(_ data: Data, maxSize: Int) throws -> Data {
        let bytes = Data(data)
        guard bytes.count >= 22 else { throw SteamNativeError.invalidContent }
        let tail = bytes.suffix(min(bytes.count, 65_557))
        guard let marker = tail.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards) else {
            throw SteamNativeError.invalidContent
        }
        var end = SteamBytes(Data(bytes[marker.lowerBound...]))
        _ = try end.take(4)
        let disk: UInt16 = try end.littleEndian()
        let directoryDisk: UInt16 = try end.littleEndian()
        let diskEntries: UInt16 = try end.littleEndian()
        let allEntries: UInt16 = try end.littleEndian()
        let directorySize: UInt32 = try end.littleEndian()
        let directoryOffset: UInt32 = try end.littleEndian()
        let commentSize: UInt16 = try end.littleEndian()
        guard disk == 0, directoryDisk == 0, diskEntries == 1, allEntries == 1, end.remaining == Int(commentSize),
              Int(directoryOffset) + Int(directorySize) <= marker.lowerBound else { throw SteamNativeError.invalidContent }

        var directory = SteamBytes(bytes.subdata(in: Int(directoryOffset)..<Int(directoryOffset + directorySize)))
        let signature: UInt32 = try directory.littleEndian()
        guard signature == 0x02014b50 else { throw SteamNativeError.invalidContent }
        _ = try directory.take(4)
        let flags: UInt16 = try directory.littleEndian()
        let method: UInt16 = try directory.littleEndian()
        _ = try directory.take(4)
        let checksum: UInt32 = try directory.littleEndian()
        let compressedSize: UInt32 = try directory.littleEndian()
        let size: UInt32 = try directory.littleEndian()
        _ = try directory.take(14)
        let entryOffset: UInt32 = try directory.littleEndian()
        guard (flags & 1) == 0, size > 0, size <= maxSize, entryOffset < directoryOffset else {
            throw SteamNativeError.invalidContent
        }
        var entry = SteamBytes(bytes.subdata(in: Int(entryOffset)..<Int(directoryOffset)))
        let entrySignature: UInt32 = try entry.littleEndian()
        guard entrySignature == 0x04034b50 else { throw SteamNativeError.invalidContent }
        _ = try entry.take(22)
        let nameLength: UInt16 = try entry.littleEndian()
        let extraLength: UInt16 = try entry.littleEndian()
        _ = try entry.take(Int(nameLength) + Int(extraLength))
        let compressed = try entry.take(Int(compressedSize))
        let plain: Data
        switch method {
        case 0: plain = compressed
        case 8: plain = try inflate(compressed, size: Int(size), gzip: false)
        default: throw SteamNativeError.unsupportedContent
        }
        guard plain.count == size, crc(plain) == checksum else { throw SteamNativeError.invalidContent }
        return plain
    }

    static func chunk(_ data: Data, size: Int) throws -> Data {
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
            return try zipEntry(data, maxSize: size)
        }
        if data.starts(with: "VZa".utf8) {
            guard data.count >= 22, data.suffix(2) == Data("zv".utf8) else {
                throw SteamNativeError.invalidContent
            }
            var trailer = SteamBytes(Data(data.suffix(10)))
            let checksum: UInt32 = try trailer.littleEndian()
            let declaredSize: UInt32 = try trailer.littleEndian()
            guard size == declaredSize else { throw SteamNativeError.invalidContent }
            // Convert the wrapper's LZMA properties and raw body into a LZMA-Alone stream.
            var stream = Data(data[7..<12])
            var count = UInt64(size).littleEndian
            Swift.withUnsafeBytes(of: &count) { stream.append(contentsOf: $0) }
            stream.append(Data(data[12..<(data.count - 10)]))
            let plain = try lzma(stream, size: size)
            guard crc(plain) == checksum else { throw SteamNativeError.invalidContent }
            return plain
        }
        if data.starts(with: "VSZa".utf8), data.count > 8 {
            return try zstandard(Data(data.dropFirst(8)), size: size)
        }
        if data.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) {
            return try zstandard(data, size: size)
        }
        if data.first == 0x5d {
            return try lzma(data, size: size)
        }
        throw SteamNativeError.unsupportedContent
    }

    private static func lzma(_ data: Data, size: Int) throws -> Data {
        #if canImport(LumenArchive)
        let lzmaFilter: Int32 = 5
        guard let reader = archive_read_new() else { throw SteamNativeError.invalidContent }
        defer { archive_read_free(reader) }
        guard archive_read_support_filter_lzma(reader) == 0,
              archive_read_support_format_raw(reader) == 0 else { throw SteamNativeError.invalidContent }
        var output = Data(count: size)
        let decoded = data.withUnsafeBytes { input in
            var entry: OpaquePointer?
            guard archive_read_open_memory(reader, input.baseAddress, data.count) == 0,
                  archive_read_next_header(reader, &entry) == 0,
                  archive_filter_code(reader, 0) == lzmaFilter else { return false }
            let count = output.withUnsafeMutableBytes { destination in
                archive_read_data(reader, destination.baseAddress, size)
            }
            var trailing: UInt8 = 0
            return count == size && archive_read_data(reader, &trailing, 1) == 0
        }
        guard decoded else { throw SteamNativeError.invalidContent }
        return output
        #else
        throw SteamNativeError.unsupportedContent
        #endif
    }

    private static func zstandard(_ data: Data, size: Int) throws -> Data {
        #if canImport(libzstd)
        var output = Data(count: size)
        let decoded = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                let frameSize = ZSTD_findFrameCompressedSize(source.baseAddress, data.count)
                guard ZSTD_isError(frameSize) == 0 else { return -1 }
                return ZSTD_decompress(destination.baseAddress, size, source.baseAddress, frameSize)
            }
        }
        guard decoded == size else { throw SteamNativeError.invalidContent }
        return output
        #else
        throw SteamNativeError.unsupportedContent
        #endif
    }

    private static func crc(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { UInt32(truncatingIfNeeded: crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))) }
    }
}

enum SteamDepotCipher {
    static func decrypt(_ data: Data, key: Data) throws -> Data {
        guard data.count >= 32, data.count % 16 == 0, key.count == 32 else { throw SteamNativeError.invalidContent }
        // Steam encrypts the per-block IV with AES-ECB, followed by AES-CBC ciphertext and padding.
        let iv = try aes(Data(data.prefix(16)), key: key, iv: nil)
        return try aes(Data(data.dropFirst(16)), key: key, iv: iv)
    }

    private static func aes(_ input: Data, key: Data, iv: Data?) throws -> Data {
        let capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    (iv ?? Data()).withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(iv == nil ? kCCOptionECBMode : kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, input.count,
                                destination.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SteamNativeError.invalidContent }
        output.count = written
        return output
    }
}

struct SteamDepotManifest {
    struct Chunk {
        let sha: Data
        let offset: UInt64
        let size: Int

        var identifier: String { sha.map { String(format: "%02x", $0) }.joined() }

        func verify(_ data: Data) throws {
            guard data.count == size, Data(Insecure.SHA1.hash(data: data)) == sha else { throw SteamNativeError.invalidContent }
        }
    }

    struct File {
        let components: [String]
        let size: UInt64
        let isDirectory: Bool
        let hash: Data?
        let chunks: [Chunk]
    }

    let files: [File]
    let size: UInt64

    init(_ container: Data, depotID: UInt64, manifestID: UInt64, key: Data) throws {
        let raw = container.starts(with: [0x50, 0x4b, 0x03, 0x04])
            ? try SteamCompression.zipEntry(container, maxSize: 64 * 1024 * 1024) : container
        var reader = SteamBytes(raw)
        func section(_ magic: UInt32, from reader: inout SteamBytes) throws -> Data {
            let header: UInt32 = try reader.littleEndian()
            guard header == magic else { throw SteamNativeError.invalidContent }
            let count: UInt32 = try reader.littleEndian()
            return try reader.take(Int(count))
        }
        let payload = try SteamProto(section(0x71f617d0, from: &reader))
        let metadata = try SteamProto(section(0x1f4812be, from: &reader))
        _ = try section(0x1b81b817, from: &reader)
        let end: UInt32 = try reader.littleEndian()
        guard end == 0x32c415ab, reader.remaining == 0, metadata.number(1) == depotID,
              metadata.number(2) == manifestID else { throw SteamNativeError.invalidContent }
        let encrypted = metadata.number(4) == 1
        var entries: [File] = []
        var paths: Set<String> = []
        var total: UInt64 = 0
        for mapping in try payload.messages(1) {
            guard let filename = mapping.string(1), (mapping.string(7) ?? "").isEmpty else {
                throw SteamNativeError.unsupportedContent
            }
            let directory = ((mapping.number(3) ?? 0) & 64) != 0
            let components = try Self.components(filename, encrypted: encrypted, key: key)
            let name = components.joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(name).inserted else { throw SteamNativeError.invalidContent }
            let length = mapping.number(2) ?? 0
            guard !directory || length == 0 else { throw SteamNativeError.invalidContent }
            let hash = mapping.bytes(5)
            if let hash, hash.count != 20 { throw SteamNativeError.invalidContent }
            let chunks = try mapping.messages(6).map { item -> Chunk in
                guard let digest = item.bytes(1), digest.count == 20,
                      let count = item.number(4), count > 0, count <= 8 * 1024 * 1024 else {
                    throw SteamNativeError.invalidContent
                }
                return Chunk(sha: digest, offset: item.number(3) ?? 0, size: Int(count))
            }.sorted { $0.offset < $1.offset }
            var written: UInt64 = 0
            for chunk in chunks {
                guard chunk.offset == written, UInt64(chunk.size) <= length - written else {
                    throw SteamNativeError.invalidContent
                }
                written += UInt64(chunk.size)
            }
            guard written == length else { throw SteamNativeError.invalidContent }
            guard length <= UInt64.max - total else { throw SteamNativeError.invalidContent }
            total += length
            entries.append(File(components: components, size: length, isDirectory: directory, hash: hash, chunks: chunks))
        }
        guard !entries.isEmpty else { throw SteamNativeError.invalidContent }
        files = entries
        size = total
    }

    private static func components(_ filename: String, encrypted: Bool, key: Data) throws -> [String] {
        var text = filename
        if encrypted {
            guard let data = Data(base64Encoded: filename) else { throw SteamNativeError.invalidContent }
            let clear = try SteamDepotCipher.decrypt(data, key: key)
            guard let decrypted = String(data: clear, encoding: .utf8) else { throw SteamNativeError.invalidContent }
            text = decrypted
        }
        while text.last == "\0" { text.removeLast() }
        let normalized = text.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.components(separatedBy: "/")
        guard parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && !part.contains(":") && !part.contains("\0")
        }) else { throw SteamNativeError.invalidContent }
        return parts
    }
}
