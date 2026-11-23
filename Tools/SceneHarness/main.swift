import Foundation
import Metal
import ImageIO

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let args = CommandLine.arguments
let library = URL(fileURLWithPath: args[1])
let assets = URL(fileURLWithPath: args[2])
let out = URL(fileURLWithPath: args[3])
let ids = args.count > 4 ? args[4].split(separator: ",").map(String.init) : []
let time = Float(args.count > 5 ? args[5] : "2") ?? 2
// LUMEN_DISPLAY=2560x1664 and LUMEN_BUDGET=4900000 match a specific screen and quality setting.
let environment = ProcessInfo.processInfo.environment
let harnessDisplay: SIMD2<Float> = {
    let parts = (environment["LUMEN_DISPLAY"] ?? "2560x1600").split(separator: "x").compactMap { Float($0) }
    return parts.count == 2 ? SIMD2(parts[0], parts[1]) : SIMD2(2560, 1600)
}()
let harnessBudget = Double(environment["LUMEN_BUDGET"] ?? "") ?? 6_000_000  // the app's Balanced scene budget
// LUMEN_FAKE_AUDIO=1 feeds a synthetic spectrum (loud bass falling to quiet treble) to check audio-reactive paths.
let fakeAudio: AudioBands = {
    guard ProcessInfo.processInfo.environment["LUMEN_FAKE_AUDIO"] != nil else { return .silent }
    let bands = (0..<AudioBands.bandCount).map { 0.95 - Float($0) / Float(AudioBands.bandCount) * 0.8 }
    return AudioBands(left: bands, right: bands)
}()
// LUMEN_POINTER=0.3,0.6 or LUMEN_POINTER=0.2,0.7;0.8,0.3 injects a simulated pointer (normalized top-left 0..1)
// or polyline path interpolated across frames. LUMEN_FRAMES overrides the 30fps step count (default 3, or 30 with LUMEN_POINTER).
let pointerPath: [SIMD2<Float>] = {
    guard let raw = environment["LUMEN_POINTER"], !raw.isEmpty else { return [] }
    return raw.split(separator: ";").compactMap { segment in
        let parts = segment.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return SIMD2(parts[0], parts[1])
    }
}()
let harnessFrames: Int = {
    if let raw = environment["LUMEN_FRAMES"], let n = Int(raw), n > 0 { return n }
    return pointerPath.isEmpty ? 3 : 30
}()
func samplePointer(at progress: Float) -> SIMD2<Float>? {
    guard !pointerPath.isEmpty else { return nil }
    guard pointerPath.count > 1 else { return pointerPath[0] }
    let clamped = min(max(progress, 0), 1)
    let scaled = clamped * Float(pointerPath.count - 1)
    let idx = min(Int(scaled), pointerPath.count - 2)
    let frac = scaled - Float(idx)
    return pointerPath[idx] + (pointerPath[idx + 1] - pointerPath[idx]) * frac
}
if args.count > 6 { SceneLoader.debugLayerFilter = Set(args[6].split(separator: ",").compactMap { Int($0) }) }

func savePNG(_ texture: MTLTexture, to url: URL) throws {
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
    try writePNG(image, to: url)
}

let items = ids.isEmpty ? ((try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []).sorted() : ids
var visualScenes: [SceneVisualRun.Scene] = []
for id in items {
    let folder = library.appending(path: id)
    guard let project = try? WEProject.load(folder: folder), project.kind == .scene else { continue }
    var values: [String: PropertyValue] = [:]
    for p in project.properties { values[p.id] = p.defaultValue }
    let start = Date()
    var renderSaved = false
    do {
        let request = SceneLoader.Request(folder: folder, entry: project.entry, assets: assets, values: values, displaySize: harnessDisplay, pixelBudget: harnessBudget, device: device, queue: queue)
        let instance = try SceneLoader.load(request)
        let loadTime = Date().timeIntervalSince(start)
        if environment["LUMEN_MEMORY"] != nil { print(String(format: "  memory %.0f MB", Double(device.currentAllocatedSize) / 1_048_576)) }
        if ProcessInfo.processInfo.environment["DUMPLAYERS"] != nil {
            for layer in instance.layers {
                var tex = ""
                for (slot, source) in layer.base.textures.sorted(by: { $0.key < $1.key }) {
                    switch source {
                    case .texture(let t): tex += " \(slot):tex \(t.textureSize) img \(t.imageSize) fmt \(t.format) frames \(t.frames.count)"
                    case .previous: tex += " \(slot):prev"
                    case .named(let n): tex += " \(slot):\(n)"
                    case .frameBuffer: tex += " \(slot):fb"
                    case .layerComposite(let id): tex += " \(slot):layer(\(id))"
                    case .clippingMask: tex += " \(slot):clipmask"
                    }
                }
                print("  layer", layer.object.id, layer.object.name, "vis", layer.object.visible, "size", layer.size, "alpha", layer.object.alpha, "pass", layer.isPassthrough, "steps", layer.steps.count, "origin", layer.object.origin, tex, "uniforms", layer.base.program.info.uniforms.map(\.name))
            }
        }
        let videoWait = !instance.textures.videoTextures.isEmpty
        if videoWait { RunLoop.main.run(until: Date().addingTimeInterval(1.5)) }
        // Warm up a few frames (effects with feedback, or simulated pointer motion), then capture.
        var t: Float = 0
        let frames = harnessFrames
        var gpu: Double = 0
        var lastPointer = samplePointer(at: 0) ?? SIMD2<Float>(0.5, 0.5)
        for i in 0..<frames {
            t = time + Float(i) / 30
            let progress = frames > 1 ? Float(i) / Float(frames - 1) : 1
            let simulated = samplePointer(at: progress)
            let pointer = simulated ?? SIMD2<Float>(0.5, 0.5)
            let pointerCanvas = simulated.map { SIMD2($0.x * instance.canvas.x, (1 - $0.y) * instance.canvas.y) }
            let cb = queue.makeCommandBuffer()!
            instance.encode(into: cb, frame: .init(time: t, delta: 1.0 / 30, pointerCanvas: pointerCanvas, daytime: 0.5, pointer: pointer, pointerLast: lastPointer, cameraOffset: .zero, parallax: pointer, audio: fakeAudio))
            cb.commit(); cb.waitUntilCompleted()
            gpu = cb.gpuEndTime - cb.gpuStartTime
            lastPointer = pointer
        }
        if environment["LUMEN_BENCH"] != nil {
            let times = UnsafeMutableBufferPointer<Double>.allocate(capacity: 60)
            times.initialize(repeating: 0)
            defer { times.deallocate() }
            var last: MTLCommandBuffer?
            let benchPointer = samplePointer(at: 1)
            let benchNorm = benchPointer ?? SIMD2<Float>(0.5, 0.5)
            let benchCanvas = benchPointer.map { SIMD2($0.x * instance.canvas.x, (1 - $0.y) * instance.canvas.y) }
            for i in 0..<60 {
                let cb = queue.makeCommandBuffer()!
                instance.encode(into: cb, frame: .init(time: time + Float(frames + i) / 30, delta: 1.0 / 30, pointerCanvas: benchCanvas, daytime: 0.5, pointer: benchNorm, pointerLast: benchNorm, cameraOffset: .zero, parallax: benchNorm, audio: fakeAudio))
                cb.addCompletedHandler { times[i] = $0.gpuEndTime - $0.gpuStartTime }
                cb.commit()
                last = cb
            }
            last?.waitUntilCompleted()
            Thread.sleep(forTimeInterval: 0.05)
            gpu = Array(times).sorted()[30]
        }
        try savePNG(instance.outputTexture, to: out.appending(path: "\(id).png"))
        renderSaved = true
        let line = String(format: "%@ OK load %.2fs gpu %.2fms particles %d layers %d size %dx%d skipped %@ — %@", id, loadTime, gpu * 1000, instance.particleLayers.reduce(0) { $0 + $1.systems.reduce(0) { $0 + $1.particles.count } }, instance.layers.count, instance.renderSize.x, instance.renderSize.y, instance.unsupported.joined(separator: ","), project.title)
        print(line)
        print(String(format: "  translate %.2fs total(translate+compile) %.2fs compiles %d", SceneShaderLibrary.translateTime, SceneShaderLibrary.compileTime, SceneShaderLibrary.compileCount))
    } catch {
        let line = "\(id) FAIL \(error.localizedDescription) — \(project.title)"
        print(line)
    }
    // Snapshot the author preview at index 0 so animated GIFs have a reproducible reference.
    var outcome: SceneVisualRun.Scene.Outcome = renderSaved ? .previewUnavailable : .renderFailed
    if let preview = project.previewURL,
       let source = CGImageSourceCreateWithURL(preview as CFURL, nil),
       let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
           kCGImageSourceCreateThumbnailFromImageAlways: true,
           kCGImageSourceCreateThumbnailWithTransform: true,
       ] as CFDictionary) {
        do {
            try writePNG(image, to: out.appending(path: "\(id)-ref.png"))
            if renderSaved { outcome = .ready }
        } catch {
            print("  Could not save author preview for \(id): \(error.localizedDescription)")
        }
    }
    visualScenes.append(.init(id: id, title: project.title, outcome: outcome))
}
let run = SceneVisualRun(id: UUID(), time: time, scenes: visualScenes)
try JSONEncoder().encode(run).write(to: out.appending(path: SceneVisualRun.filename), options: .atomic)
