import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let args = CommandLine.arguments
let library = URL(fileURLWithPath: args[1])
let assets = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
let ids = args.count > 4 ? args[4].split(separator: ",").map(String.init) : []
let time = Float(args.count > 5 ? args[5] : "2") ?? 2
if args.count > 6 { SceneLoader.debugLayerFilter = Set(args[6].split(separator: ",").compactMap { Int($0) }) }

func savePNG(_ texture: MTLTexture, to url: URL) {
    let w = texture.width, h = texture.height
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    desc.storageMode = .shared
    let shared = device.makeTexture(descriptor: desc)!
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: texture, to: shared)
    blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    shared.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var magenta = 0
    for i in stride(from: 3, to: bytes.count, by: 4) {
        bytes[i] = 255
        if bytes[i-3] > 200 && bytes[i-2] < 60 && bytes[i-1] > 200 { magenta += 1 }
    }
    print("magenta%", magenta * 100 / max(1, w * h))
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
}

let items = ids.isEmpty ? ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).sorted() : ids
var summary: [String] = []
for id in items {
    let folder = library.appending(path: id)
    guard let project = try? WEProject.load(folder: folder), project.kind == .scene else { continue }
    var values: [String: PropertyValue] = [:]
    for p in project.properties { values[p.id] = p.defaultValue }
    let start = Date()
    do {
        let request = SceneLoader.Request(folder: folder, entry: project.entry, assets: assets, values: values, displaySize: SIMD2(2560, 1600), pixelBudget: 2_100_000, device: device, queue: queue)
        let instance = try SceneLoader.load(request)
        let loadTime = Date().timeIntervalSince(start)
        if ProcessInfo.processInfo.environment["DUMPLAYERS"] != nil {
            for layer in instance.layers {
                var tex = ""
                for (slot, source) in layer.base.textures.sorted(by: { $0.key < $1.key }) {
                    switch source {
                    case .texture(let t): tex += " \(slot):tex \(t.textureSize) img \(t.imageSize) fmt \(t.format) frames \(t.frames.count)"
                    case .previous: tex += " \(slot):prev"
                    case .named(let n): tex += " \(slot):\(n)"
                    case .frameBuffer: tex += " \(slot):fb"
                    }
                }
                print("  layer", layer.object.id, layer.object.name, "vis", layer.object.visible, "size", layer.size, "alpha", layer.object.alpha, "pass", layer.isPassthrough, "steps", layer.steps.count, "origin", layer.object.origin, tex, "uniforms", layer.base.program.info.uniforms.map(\.name))
            }
        }
        let videoWait = !instance.textures.videoTextures.isEmpty
        if videoWait { RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }
        // Warm up a few frames (effects with feedback), then capture.
        var t: Float = 0
        let frames = 3
        var gpu: Double = 0
        for i in 0..<frames {
            t = time + Float(i) / 30
            let cb = queue.makeCommandBuffer()!
            instance.encode(into: cb, frame: .init(time: t, delta: 1.0 / 30, pointerCanvas: nil, daytime: 0.5, pointer: SIMD2(0.5, 0.5), pointerLast: SIMD2(0.5, 0.5), cameraOffset: .zero, parallax: .zero))
            cb.commit(); cb.waitUntilCompleted()
            gpu = cb.gpuEndTime - cb.gpuStartTime
        }
        savePNG(instance.outputTexture, to: out.appending(path: "\(id).png"))
        let line = String(format: "%@ OK load %.2fs gpu %.2fms particles %d layers %d size %dx%d skipped %@ — %@", id, loadTime, gpu * 1000, instance.particleLayers.reduce(0) { $0 + $1.systems.reduce(0) { $0 + $1.particles.count } }, instance.layers.count, instance.renderSize.x, instance.renderSize.y, instance.unsupported.joined(separator: ","), project.title)
        print(line); summary.append(line)
        print(String(format: "  translate %.2fs total(translate+compile) %.2fs compiles %d", SceneShaderLibrary.translateTime, SceneShaderLibrary.compileTime, SceneShaderLibrary.compileCount))
    } catch {
        let line = "\(id) FAIL \(error.localizedDescription) — \(project.title)"
        print(line); summary.append(line)
    }
    // Reference preview for comparison
    if let preview = project.previewURL, let src = CGImageSourceCreateWithURL(preview as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        let dest = CGImageDestinationCreateWithURL(out.appending(path: "\(id)-ref.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    }
}
