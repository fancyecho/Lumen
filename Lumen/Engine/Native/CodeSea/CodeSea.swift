import AppKit
import AVFoundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Code Sea (代码海): the person's own native wallpaper, a sea of code-like characters from which a
/// winged figure occasionally forms. The renderer is ported from its standalone app; Lumen supplies
/// the desktop windows, pausing, pointer input, settings and the Lock Screen.
enum CodeSea {
    /// Portrait copied from the project's `Resources/avatar.png` on import (never committed here).
    static let avatarFile = "avatar.png"

    /// Settings of the standalone app's menu and settings window, as Customize properties.
    static var properties: [WEProperty] {
        [
            .slider("motion", String(localized: "Sea motion", table: "Native"), order: 0, value: 50, range: 0...100),
            .slider("brightness", String(localized: "Character brightness", table: "Native"), order: 1, value: 50, range: 0...100),
            .choice("avatarMode", String(localized: "She appears", table: "Native"), order: 2, value: "occasional", options: [
                ("off", String(localized: "Only when summoned", table: "Native")),
                ("occasional", String(localized: "Occasionally (about every 3 minutes)", table: "Native")),
                ("often", String(localized: "Often (about every minute)", table: "Native")),
                ("always", String(localized: "Always", table: "Native")),
            ]),
            .toggle("wings", String(localized: "Wings", table: "Native"), order: 3, value: true),
            .toggle("nightSea", String(localized: "Night sea tone", table: "Native"), order: 4, value: true),
            .toggle("hover", String(localized: "Glow under the pointer", table: "Native"), order: 5, value: true),
            .toggle("batteryCap", String(localized: "Lower frame rate on battery", table: "Native"), order: 6, value: true),
        ]
    }

    /// What the properties mean to the renderer.
    struct Options: Equatable {
        var look = SeaLook()
        /// Seconds between appearances; nil means only when summoned (or always, with `persistent`).
        var interval: Double? = 180
        var persistent = false
        var batteryCap = true

        init(values: [String: PropertyValue]) {
            func number(_ key: String, _ fallback: Float) -> Float { values[key].map { Float($0.doubleValue) } ?? fallback }
            func flag(_ key: String, _ fallback: Bool) -> Bool { values[key]?.boolValue ?? fallback }
            look.motion = min(max(number("motion", 50), 0), 100)
            look.brightness = min(max(number("brightness", 50), 0), 100)
            look.hover = flag("hover", true)
            look.nightSea = flag("nightSea", true)
            look.wings = flag("wings", true)
            batteryCap = flag("batteryCap", true)
            switch values["avatarMode"]?.stringValue ?? "occasional" {
            case "off": interval = nil
            case "often": interval = 65
            case "always": interval = nil; persistent = true
            default: interval = 180
            }
        }

        static func == (a: Options, b: Options) -> Bool {
            a.look.motion == b.look.motion && a.look.brightness == b.look.brightness && a.look.hover == b.look.hover
                && a.look.nightSea == b.look.nightSea && a.look.wings == b.look.wings
                && a.interval == b.interval && a.persistent == b.persistent && a.batteryCap == b.batteryCap
        }
    }

    // MARK: Shared resources

    static func makeContext(avatarURL: URL?) throws -> SeaContext {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SeaError("Metal unavailable") }
        let library = try NativeShaders.library(named: "CodeSea", device: device)
        let verses = Bundle.main.url(forResource: "CodeSeaVerses", withExtension: "txt")
        return try SeaContext(device: device, library: library, avatarURL: avatarURL, versesURL: verses)
    }

    @MainActor private static var loads: [String: Task<SeaContext, Error>] = [:]

    /// One context per portrait, shared by every display and preview, built off the main thread
    /// (shader compilation and the mipmapped portrait are the slow parts).
    @MainActor static func context(avatarURL: URL?) async throws -> SeaContext {
        let key = avatarURL?.path ?? ""
        if let load = loads[key] { return try await load.value }
        let load = Task.detached(priority: .userInitiated) { try makeContext(avatarURL: avatarURL) }
        loads[key] = load
        do {
            return try await load.value
        } catch {
            loads[key] = nil
            throw error
        }
    }

    static func avatarURL(in folder: URL) -> URL? {
        let url = folder.appending(path: avatarFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Offscreen

    /// The figure fully formed, as the standalone app's Lock Screen thumbnail shows her.
    static func shownFrame(at seconds: Float) -> AvatarFrame {
        AvatarFrame(reveal: 1, dissolve: 0, elapsed: seconds, present: true)
    }

    /// Writes a still for the library card when the project folder had no preview.
    static func writeThumbnail(avatarURL: URL?, values: [String: PropertyValue], to url: URL) throws {
        let context = try makeContext(avatarURL: avatarURL)
        let renderer = SeaRenderer(context: context, seed: 7)
        renderer.look = Options(values: values).look
        if context.hasFigure { renderer.avatar = shownFrame(at: 7) }
        let width = 1440, height = 900
        let pixels = renderer.renderOffscreen(width: width, height: height, scale: 1, now: renderer.epoch + 7)
        try write(bgra: pixels, width: width, height: height, to: url, type: .jpeg)
    }

    static func write(bgra: [UInt8], width: Int, height: Int, to url: URL, type: UTType) throws {
        var rgba = bgra
        for k in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(k, k + 2); rgba[k + 3] = 255 }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw SeaError("Couldn't encode the image") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SeaError("Couldn't write the image") }
    }

    // MARK: Lock Screen

    /// Records a seamless loop for the Lock Screen: the sea with her fully formed (the standalone
    /// app's Lock Screen shows her every ~45 s; a short loop would otherwise rarely include her).
    static func recordLoop(avatarURL: URL?, values: [String: PropertyValue], size: CGSize, scale: CGFloat,
                           to destination: URL, progress: @escaping @Sendable (Double) -> Void) throws {
        let context = try makeContext(avatarURL: avatarURL)
        let device = context.device
        let width = Int(size.width), height = Int(size.height)
        let renderer = SeaRenderer(context: context, seed: 7)
        renderer.look = Options(values: values).look

        func texture(shared: Bool) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SeaContext.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = shared ? .shared : .private
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw SeaError("no texture") }
            return texture
        }
        let target = try texture(shared: true)
        let firstFrame = try texture(shared: false)
        let fade = try SceneLoopRecorder.fadePipeline(device: device)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { throw SeaError("no sampler") }

        let frameRate = SceneLoopRecorder.frameRate
        let loopFrames = Int(SceneLoopRecorder.loopSeconds * Double(frameRate))
        let fadeStart = loopFrames - Int(SceneLoopRecorder.crossfadeSeconds * Double(frameRate))
        let writer = try LoopVideoWriter(url: destination, width: width, height: height, frameRate: frameRate)
        let start = renderer.epoch + 100

        for frame in 0..<loopFrames {
            try Task.checkCancellation()
            let seconds = Double(frame) / Double(frameRate)
            if context.hasFigure { renderer.avatar = shownFrame(at: Float(8 + seconds)) }
            renderer.render(to: target, scale: scale, now: start + seconds)
            guard let buffer = context.queue.makeCommandBuffer() else { throw SeaError("no command buffer") }
            if frame == 0, let blit = buffer.makeBlitCommandEncoder() {
                blit.copy(from: target, to: firstFrame)
                blit.endEncoding()
            } else if frame >= fadeStart {
                var full = SIMD4<Float>(-1, -1, 2, 2)
                let weight = Float(frame - fadeStart + 1) / Float(loopFrames - fadeStart)
                SceneLoopRecorder.draw(firstFrame, into: target, pipeline: fade, rect: &full, sampler: sampler,
                                       buffer: buffer, clear: false, alpha: weight)
            }
            buffer.commit()
            buffer.waitUntilCompleted()
            try writer.append(target, at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate)))
            if frame % 15 == 0 { progress(Double(frame) / Double(loopFrames)) }
        }
        try writer.finish()
    }
}
