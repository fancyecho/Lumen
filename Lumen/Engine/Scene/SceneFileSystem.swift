import Foundation

/// Reads Wallpaper Engine's `scene.pkg` archives (`PKGV00xx`): a table of file names, offsets
/// and sizes, followed by the files' bytes. The archive is memory-mapped, so nothing is copied
/// until a file is asked for.
struct PackageArchive {
    let version: String
    private let data: Data
    private let entries: [String: Range<Int>]

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        var reader = ByteReader(data: data)
        let magicLength = Int(try reader.uint32())
        guard magicLength > 0, magicLength < 64 else { throw SceneLoadError.corruptPackage }
        version = try reader.string(length: magicLength)
        guard version.hasPrefix("PKGV") else { throw SceneLoadError.corruptPackage }
        let count = Int(try reader.uint32())
        guard count < 100_000 else { throw SceneLoadError.corruptPackage }
        var table: [(String, Int, Int)] = []
        table.reserveCapacity(count)
        for _ in 0..<count {
            let nameLength = Int(try reader.uint32())
            let name = try reader.string(length: nameLength)
            let offset = Int(try reader.uint32())
            let size = Int(try reader.uint32())
            table.append((name, offset, size))
        }
        let base = reader.offset
        var entries: [String: Range<Int>] = [:]
        for (name, offset, size) in table {
            let start = base + offset
            guard start >= 0, size >= 0, start + size <= data.count else { continue }
            entries[SceneFileSystem.normalize(name)] = start..<(start + size)
        }
        self.entries = entries
    }

    var fileNames: [String] { Array(entries.keys) }

    func data(_ path: String) -> Data? {
        guard let range = entries[path] else { return nil }
        return data.subdata(in: range)
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }
}

enum SceneLoadError: LocalizedError {
    case corruptPackage
    case missingFile(String)
    case unsupported(String)
    case noAssets

    var errorDescription: String? {
        switch self {
        case .corruptPackage: String(localized: "The scene package is damaged.")
        case .missingFile(let name): String(localized: "The scene needs “\(name)”, which isn't in the package or Wallpaper Engine's assets.")
        case .unsupported(let what): String(localized: "This scene uses \(what), which Lumen can't draw yet.")
        case .noAssets: String(localized: "Scenes need Wallpaper Engine's shared assets. Choose them in Settings › Wallpaper Engine.")
        }
    }
}

/// The files a scene can read, looked up the way Wallpaper Engine does: the scene's own
/// package first, then loose files in its folder, then Wallpaper Engine's shared `assets`.
final class SceneFileSystem: @unchecked Sendable {
    let projectFolder: URL
    let assets: URL?
    private let archive: PackageArchive?
    private let lock = NSLock()
    private var cache: [String: Data] = [:]

    init(projectFolder: URL, assets: URL?) throws {
        self.projectFolder = projectFolder
        self.assets = assets
        let packageURL = projectFolder.appending(path: "scene.pkg")
        archive = FileManager.default.fileExists(atPath: packageURL.path) ? try PackageArchive(url: packageURL) : nil
    }

    var packageVersion: String? { archive?.version }

    static func normalize(_ path: String) -> String {
        var result = path.replacingOccurrences(of: "\\", with: "/")
        while result.hasPrefix("./") { result.removeFirst(2) }
        while result.hasPrefix("/") { result.removeFirst() }
        return result
    }

    /// Reads a file, or nil if no source has it.
    func data(_ path: String) -> Data? {
        let key = Self.normalize(path)
        guard !key.isEmpty, !key.split(separator: "/").contains("..") else { return nil }
        if let archived = archive?.data(key) { return archived }
        if let loose = try? Data(contentsOf: projectFolder.appending(path: key), options: .mappedIfSafe) { return loose }
        if let assets, let shared = try? Data(contentsOf: assets.appending(path: key), options: .mappedIfSafe) { return shared }
        return nil
    }

    /// Reads a file that an effect names, trying the effect's own folder first: newer asset
    /// layouts keep an effect's materials and shaders beside its `effect.json`.
    func data(_ path: String, near base: String?) -> Data? {
        if let base, !base.isEmpty, let local = data(base + "/" + Self.normalize(path)) { return local }
        return data(path)
    }

    func exists(_ path: String) -> Bool {
        let key = Self.normalize(path)
        if archive?.contains(key) == true { return true }
        if FileManager.default.fileExists(atPath: projectFolder.appending(path: key).path) { return true }
        if let assets { return FileManager.default.fileExists(atPath: assets.appending(path: key).path) }
        return false
    }

    /// Parsed JSON object, cached because materials and models are shared between layers.
    func json(_ path: String, near base: String? = nil) -> [String: Any]? {
        let key = (base ?? "") + "|" + path
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        let bytes = cached ?? data(path, near: base)
        guard let bytes else { return nil }
        if cached == nil {
            lock.lock()
            cache[key] = bytes
            lock.unlock()
        }
        return LenientJSON.object(from: bytes)
    }

    func text(_ path: String, near base: String? = nil) -> String? {
        data(path, near: base).map { String(decoding: $0, as: UTF8.self) }
    }
}

/// Little-endian reader for Wallpaper Engine's binary formats.
struct ByteReader {
    let data: Data
    var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func uint32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw SceneLoadError.corruptPackage }
        let start = data.startIndex + offset
        let value = UInt32(data[start]) | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
        offset += 4
        return value
    }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func uint16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw SceneLoadError.corruptPackage }
        let start = data.startIndex + offset
        offset += 2
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    mutating func uint8() throws -> UInt8 {
        guard offset < data.count else { throw SceneLoadError.corruptPackage }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func float() throws -> Float { Float(bitPattern: try uint32()) }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw SceneLoadError.corruptPackage }
        let start = data.startIndex + offset
        offset += count
        return data.subdata(in: start..<(start + count))
    }

    mutating func string(length: Int) throws -> String {
        let raw = try bytes(length)
        return String(decoding: raw, as: UTF8.self)
    }

    /// A NUL-terminated string, as the texture and model headers use.
    mutating func cString(maxLength: Int = 256) throws -> String {
        var bytes: [UInt8] = []
        while bytes.count < maxLength {
            let byte = try uint8()
            if byte == 0 { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    mutating func skip(_ count: Int) throws {
        guard offset + count <= data.count else { throw SceneLoadError.corruptPackage }
        offset += count
    }
}
