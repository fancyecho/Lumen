import Foundation
import Metal

let device = MTLCreateSystemDefaultDevice()!
let assets = URL(fileURLWithPath: CommandLine.arguments[1])
let library = URL(fileURLWithPath: CommandLine.arguments[2])
let verbose = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""

struct Pair { let name: String; let vert: String; let frag: String; let include: (String) -> String? }
var pairs: [Pair] = []
func assetInclude(_ name: String) -> String? {
    for base in ["shaders/"] {
        if let d = try? String(contentsOf: assets.appending(path: base + name), encoding: .utf8) { return d }
    }
    return nil
}
// Asset shaders (top-level and effect-local)
let fm = FileManager.default
let enumerator = fm.enumerator(at: assets, includingPropertiesForKeys: nil)!
var seenNames = Set<String>()
for case let url as URL in enumerator where url.pathExtension == "frag" {
    if url.path.contains("/preview/") || url.path.contains("/HLSL/") { continue }
    let vertURL = url.deletingPathExtension().appendingPathExtension("vert")
    guard let frag = try? String(contentsOf: url, encoding: .utf8), let vert = try? String(contentsOf: vertURL, encoding: .utf8) else { continue }
    let rel = String(url.path.dropFirst(assets.path.count + 1))
    pairs.append(Pair(name: "assets:" + rel, vert: vert, frag: frag, include: assetInclude))
}
// Package shaders
for item in (try? fm.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? [] {
    guard let files = try? SceneFileSystem(projectFolder: item, assets: assets), files.packageVersion != nil else { continue }
    let archive = try! PackageArchive(url: item.appending(path: "scene.pkg"))
    for name in archive.fileNames where name.hasPrefix("shaders/") && name.hasSuffix(".frag") {
        let vertName = String(name.dropLast(5)) + ".vert"
        guard let frag = archive.data(name), let vert = archive.data(vertName) else { continue }
        let key = name
        if seenNames.contains(key + "\(frag.count)") { continue }
        seenNames.insert(key + "\(frag.count)")
        pairs.append(Pair(name: item.lastPathComponent + ":" + name, vert: String(decoding: vert, as: UTF8.self), frag: String(decoding: frag, as: UTF8.self), include: { n in
            if let d = archive.data("shaders/" + n) { return String(decoding: d, as: UTF8.self) }
            return assetInclude(n)
        }))
    }
}
print("pairs:", pairs.count)
var ok = 0, failed = 0
var errorKinds: [String: Int] = [:]
let started = Date()
for pair in pairs {
    let combos = WEShaderTranslator.comboDefaults(in: pair.vert + "\n" + pair.frag)
    let program = WEShaderTranslator.translate(vertex: pair.vert, fragment: pair.frag, combos: combos, resolveInclude: pair.include)
    do {
        let options = MTLCompileOptions(); options.languageVersion = .version3_2; options.mathMode = .fast
        let lib = try device.makeLibrary(source: program.source, options: options)
        guard lib.makeFunction(name: "we_vertex") != nil, lib.makeFunction(name: "we_fragment") != nil else { throw NSError(domain: "nofunc", code: 0) }
        ok += 1
    } catch {
        failed += 1
        let lines = "\(error)".components(separatedBy: "\n").filter { $0.contains("error:") }
        let first = lines.first ?? "\(error)"
        let msg = first.replacingOccurrences(of: #"program_source:\d+:\d+: "#, with: "", options: .regularExpression)
        let kind = msg.replacingOccurrences(of: #"'[^']*'"#, with: "'_'", options: .regularExpression)
        errorKinds[String(kind.prefix(120)), default: 0] += 1
        if verbose == "v" || pair.name.contains(verbose) && !verbose.isEmpty {
            print("FAIL", pair.name, "::", lines.prefix(3).joined(separator: " || "))
        }
        if verbose.hasPrefix("dump:"), pair.name.contains(verbose.dropFirst(5)) {
            try? program.source.write(toFile: "dump.metal", atomically: true, encoding: .utf8)
            print(lines.prefix(6).joined(separator: "\n"))
            exit(0)
        }
    }
}
print("ok", ok, "failed", failed, "time", Date().timeIntervalSince(started))
for (k, v) in errorKinds.sorted(by: { $0.value > $1.value }).prefix(30) { print(v, k) }
