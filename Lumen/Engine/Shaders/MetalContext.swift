import CoreGraphics
import Foundation
import Metal

enum ShaderError: LocalizedError {
    case noDevice
    case missingEntryPoint
    case missingSource
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .noDevice: String(localized: "This Mac has no Metal device.")
        case .missingEntryPoint: String(localized: "The shader must define `fragment float4 lumen_fragment(...)`.")
        case .missingSource: String(localized: "This wallpaper has no shader source.")
        case .renderFailed: String(localized: "The shader could not be rendered.")
        }
    }
}

/// Shared Metal device, command queue and a cache of compiled pipelines.
@MainActor
final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var pipelineOrder: [String] = []
    private let headerLineCount = ShaderSources.header.components(separatedBy: "\n").count

    private init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
    }

    func pipeline(for fragmentSource: String) throws -> MTLRenderPipelineState {
        if let cached = pipelines[fragmentSource] { return cached }
        guard let device else { throw ShaderError.noDevice }

        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library = try device.makeLibrary(source: ShaderSources.header + "\n" + fragmentSource, options: options)
        guard let vertex = library.makeFunction(name: "lumen_vertex"),
              let fragment = library.makeFunction(name: "lumen_fragment")
        else { throw ShaderError.missingEntryPoint }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let state = try device.makeRenderPipelineState(descriptor: descriptor)

        pipelines[fragmentSource] = state
        pipelineOrder.append(fragmentSource)
        if pipelineOrder.count > 24 {
            pipelines[pipelineOrder.removeFirst()] = nil
        }
        return state
    }

    /// Compiles user source and returns a readable error, with line numbers relative to their code.
    func compileError(for fragmentSource: String) -> String? {
        do {
            _ = try pipeline(for: fragmentSource)
            return nil
        } catch {
            return readableMessage(for: error)
        }
    }

    func readableMessage(for error: Error) -> String {
        let raw = (error as NSError).localizedDescription
        let offset = headerLineCount
        let lines = raw.components(separatedBy: "\n").filter { $0.contains("error") }
        let cleaned = lines.map { line -> String in
            guard let match = line.firstMatch(of: /program_source:(\d+):(\d+):\s*(.*)/),
                  let number = Int(match.1)
            else { return line }
            return String(localized: "Line \(max(1, number - offset)): \(String(match.3))")
        }
        return cleaned.isEmpty ? raw : cleaned.prefix(6).joined(separator: "\n")
    }

    /// Renders one frame offscreen — used for thumbnails and the system still frame.
    func snapshot(of config: ShaderConfig, size: CGSize, time: Double = 12, framing: WallpaperFraming = .centered) throws -> CGImage {
        guard let device, let commandQueue else { throw ShaderError.noDevice }
        guard let source = config.resolvedSource else { throw ShaderError.missingSource }
        let pipeline = try pipeline(for: source)

        let width = max(1, Int(size.width))
        let height = max(1, Int(size.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = commandQueue.makeCommandBuffer()
        else { throw ShaderError.renderFailed }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        var uniforms = ShaderUniforms(params: config.params)
        uniforms.time = Float(time * config.params.speed)
        uniforms.resolution = SIMD2(Float(width), Float(height))
        uniforms.framing = framing.shaderVector

        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { throw ShaderError.renderFailed }
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &uniforms) { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ShaderError.renderFailed }
        return image
    }
}
