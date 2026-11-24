import AppKit
import AVFoundation
import Metal

/// PRO Strands (PRO 光丝): the person's own native interactive wallpaper. The MacBook Pro artwork is
/// split into about 900 elastic strands the pointer can comb, press and pluck; at rest the picture is
/// the original image, with an optional idle light flow. Ported from its standalone app; the artwork
/// is imported from the project folder and never committed here (it isn't the person's to share).
enum PROStrands {
    static let imageFile = "image.png"

    static var properties: [WEProperty] {
        [
            .slider("strength", String(localized: "Strum strength", table: "Native"), order: 0, value: 32, range: 0...100),
            .slider("radius", String(localized: "Reach", table: "Native"), order: 1, value: 22, range: 0...100),
            .slider("recovery", String(localized: "Spring back", table: "Native"), order: 2, value: 55, range: 0...100),
            .slider("depth", String(localized: "Layer depth", table: "Native"), order: 3, value: 50, range: 0...100),
            .slider("twist", String(localized: "Strand twist", table: "Native"), order: 4, value: 40, range: 0...100),
            .slider("glow", String(localized: "Metallic sheen", table: "Native"), order: 5, value: 65, range: 0...100),
            .slider("flow", String(localized: "Idle light flow", table: "Native"), order: 6, value: 75, range: 0...100),
            .slider("flowSpeed", String(localized: "Flow speed", table: "Native"), order: 7, value: 50, range: 0...100),
            .toggle("batteryCap", String(localized: "Lower frame rate on battery", table: "Native"), order: 8, value: true),
        ]
    }

    struct Options: Equatable {
        var sim = SimParams()
        var look = LookParams()
        var batteryCap = true

        init(values: [String: PropertyValue]) {
            func number(_ key: String, _ fallback: Float) -> Float {
                min(max(values[key].map { Float($0.doubleValue) } ?? fallback, 0), 100)
            }
            sim = SimParams(strength: number("strength", 32), radius: number("radius", 22), depth: number("depth", 50),
                            twist: number("twist", 40), recovery: number("recovery", 55))
            look = LookParams(glow: number("glow", 65), flow: number("flow", 75), flowSpeed: number("flowSpeed", 50))
            batteryCap = values["batteryCap"]?.boolValue ?? true
        }
    }

    static func imageURL(in folder: URL) -> URL? {
        let url = folder.appending(path: imageFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Shared resources

    /// Builds the strand layout from the artwork (the slow part, done once per image).
    static func makeContext(imageURL: URL) throws -> RenderContext {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CodeSea.SeaError("Metal unavailable")
        }
        let library = try NativeShaders.library(named: "PROStrands", device: device)
        return try RenderContext(device: device, library: library, imageURL: imageURL)
    }

    @MainActor private static var loads: [String: Task<RenderContext, Error>] = [:]

    /// One context per image, shared by every display and preview, built off the main thread.
    @MainActor static func context(imageURL: URL) async throws -> RenderContext {
        let key = imageURL.path
        if let load = loads[key] { return try await load.value }
        let load = Task.detached(priority: .userInitiated) { try makeContext(imageURL: imageURL) }
        loads[key] = load
        do {
            return try await load.value
        } catch {
            loads[key] = nil
            throw error
        }
    }

    // MARK: Offscreen

    static func writeThumbnail(imageURL: URL, values: [String: PropertyValue], to url: URL) throws {
        let renderer = StrandRenderer(context: try makeContext(imageURL: imageURL))
        renderer.look = Options(values: values).look
        let width = 1440, height = 900
        let pixels = renderer.renderOffscreen(width: width, height: height, time: 0)
        try CodeSea.write(bgra: pixels, width: width, height: height, to: url, type: .jpeg)
    }

    /// Records the idle light flow for the Lock Screen (which plays it in the standalone app too).
    /// The schedule repeats every two rounds, so exactly two rounds loop without a seam.
    static func recordLoop(imageURL: URL, values: [String: PropertyValue], size: CGSize,
                           to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let context = try makeContext(imageURL: imageURL)
        let renderer = StrandRenderer(context: context)
        renderer.look = Options(values: values).look
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RenderContext.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = context.device.makeTexture(descriptor: descriptor) else { throw CodeSea.SeaError("no texture") }

        let frameRate = SceneLoopRecorder.frameRate
        let period = 20 - 12 * Double(renderer.look.flowSpeed) / 100
        // A still picture (flow off) needs only a moment; the builder repeats it to an hour.
        let seconds = renderer.look.flow > 0 ? 2 * period : 2
        let frames = Int((seconds * Double(frameRate)).rounded())
        let writer = try LoopVideoWriter(url: destination, width: width, height: height, frameRate: frameRate)
        for frame in 0..<frames {
            try Task.checkCancellation()
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let buffer = context.queue.makeCommandBuffer() else { throw CodeSea.SeaError("no command buffer") }
            renderer.encode(into: pass, size: CGSize(width: width, height: height), commandBuffer: buffer,
                            time: Float(Double(frame) / Double(frameRate)))
            buffer.commit()
            buffer.waitUntilCompleted()
            try writer.append(target, at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate)))
            if frame % 15 == 0 { progress(Double(frame) / Double(frames)) }
        }
        try writer.finish()
    }
}
