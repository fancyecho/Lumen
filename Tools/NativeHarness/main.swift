// Renders key frames of the native wallpapers offscreen from the ported code, with GPU timings.
//   native-harness codesea <avatar.png|-> <out dir>
//   native-harness prostrands <image.png> <out dir>
// Shaders compile from Lumen/Engine/Native/*/*.msl, as in the app.
import AppKit
import Metal
import QuartzCore

enum CodeSea {}
enum PROStrands {}

let args = CommandLine.arguments
guard args.count >= 4, let device = MTLCreateSystemDefaultDevice() else {
    print("usage: native-harness codesea|prostrands <resource|-> <out dir>")
    exit(2)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let width = 2940, height = 1912

func library(_ path: String) -> MTLLibrary {
    let source = try! String(contentsOf: root.appending(path: path), encoding: .utf8)
    return try! device.makeLibrary(source: source, options: nil)
}

func write(_ bgra: [UInt8], _ name: String, w: Int = width, h: Int = height) {
    var rgba = bgra
    for k in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(k, k + 2); rgba[k + 3] = 255 }
    let provider = CGDataProvider(data: Data(rgba) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appending(path: "\(name).png"))
}

func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = CACurrentMediaTime()
    let value = try body()
    print(String(format: "%@ %.0f ms", label, (CACurrentMediaTime() - start) * 1000))
    return value
}

switch args[1] {
case "codesea":
    let avatar = args[2] == "-" ? nil : URL(fileURLWithPath: args[2])
    let lib = timed("compile") { library("Lumen/Engine/Native/CodeSea/CodeSea.msl") }
    let context = try timed("context") {
        try CodeSea.SeaContext(device: device, library: lib, avatarURL: avatar,
                               versesURL: root.appending(path: "Lumen/Engine/Native/CodeSea/CodeSeaVerses.txt"))
    }
    print("figure:", context.hasFigure)
    func shot(_ name: String, _ setup: (CodeSea.SeaRenderer) -> Double) {
        let r = CodeSea.SeaRenderer(context: context, seed: 7)
        _ = r.uniforms(width: width, height: height, scale: 2, now: r.epoch)
        let now = setup(r)
        write(r.renderOffscreen(width: width, height: height, scale: 2, now: now), name)
        print(String(format: "%@ GPU %.2f ms", name, r.benchmark(width: width, height: height, scale: 2, now: now, frames: 30)))
    }
    shot("codesea-sea") { r in r.epoch + 4 }
    shot("codesea-hover") { r in
        for k in 0..<12 { r.updatePointer(SIMD2(900 + Float(k) * 28, 760), scale: 2, now: r.epoch + Double(k) / 60) }
        return r.epoch + 11.0 / 60
    }
    if context.hasFigure {
        shot("codesea-shown") { r in
            r.avatar = CodeSea.AvatarFrame(reveal: 1, dissolve: 0, elapsed: 7, present: true)
            return r.epoch + 7
        }
        shot("codesea-wings-1.5") { r in
            r.avatar = CodeSea.AvatarFrame(reveal: 0.44, dissolve: 0, elapsed: 3.5, present: true, unfurl: 1.5)
            return r.epoch + 3.5
        }
    }
case "prostrands":
    let lib = timed("compile") { library("Lumen/Engine/Native/PROStrands/PROStrands.msl") }
    let context = try timed("context (strand layout)") {
        try PROStrands.RenderContext(device: device, library: lib, imageURL: URL(fileURLWithPath: args[2]))
    }
    print("strands:", context.layout.count, "rows:", context.layout.rows)
    let r = PROStrands.StrandRenderer(context: context)
    // A new simulation marks every strand dirty until it settles; the original's benchmark resets first.
    r.sim.reset(); r.upload()
    write(r.renderOffscreen(width: width, height: height, time: 0), "prostrands-rest")
    _ = r.benchmark(width: width, height: height, frames: 120)   // let the GPU clock ramp up first
    print(String(format: "rest GPU %.2f ms", r.benchmark(width: width, height: height, frames: 200)))
    let W = Float(context.layout.srcWidth), H = Float(context.layout.srcHeight)
    for k in 0..<24 {
        let t = Float(k) / 60
        let p = SIMD2(W * (0.36 + 0.28 * min(1, t / 0.4)), H * 0.44)
        if r.sim.advance(dt: 1 / 60, pointer: PROStrands.PointerSample(position: p, present: true, pressed: false)) { r.upload() }
    }
    write(r.renderOffscreen(width: width, height: height, time: 0.4), "prostrands-hover")
    for _ in 0..<30 {
        if r.sim.advance(dt: 1 / 60, pointer: PROStrands.PointerSample(position: SIMD2(W * 0.55, H * 0.4), present: true, pressed: true)) { r.upload() }
    }
    write(r.renderOffscreen(width: width, height: height, time: 0.9), "prostrands-press")
    print(String(format: "interacting GPU %.2f ms", r.benchmark(width: width, height: height, frames: 60)))
    r.sim.reset(); r.upload()
    r.look = PROStrands.LookParams(glow: 65, flow: 75, flowSpeed: 50)
    write(r.renderOffscreen(width: width, height: height, time: 3.5), "prostrands-flow")
default:
    print("unknown wallpaper \(args[1])")
    exit(2)
}
