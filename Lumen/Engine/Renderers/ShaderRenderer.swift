import AppKit
import MetalKit
import QuartzCore

struct ShaderRenderSettings: Equatable {
    var frameRate: Int
    /// Upper bound on rendered pixels; the drawable is upscaled to fill the display.
    var pixelBudget: Double

    static let preview = ShaderRenderSettings(frameRate: 30, pixelBudget: 900_000)
}

/// MTKView whose drawable is sized to a pixel budget instead of the full backing size.
final class BudgetedMetalView: MTKView {
    var pixelBudget: Double = .infinity { didSet { updateDrawableSize() } }
    var onFirstDrawableSize: (() -> Void)?

    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    func updateDrawableSize() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let native = CGSize(width: bounds.width * backing, height: bounds.height * backing)
        let scale = min(1, sqrt(pixelBudget / (native.width * native.height)))
        let target = CGSize(width: (native.width * scale).rounded(), height: (native.height * scale).rounded())
        if drawableSize != target { drawableSize = target }
        if window != nil, let callback = onFirstDrawableSize {
            onFirstDrawableSize = nil
            callback()
        }
    }
}

@MainActor
final class ShaderRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    var view: NSView { metalView }

    private let metalView: BudgetedMetalView
    private let commandQueue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState
    private var source: String
    private var params: ShaderParams
    private var detail: Double
    private var uniforms: ShaderUniforms
    private var settings: ShaderRenderSettings
    /// Animation clock in "shader seconds" (already multiplied by speed), so speed
    /// changes and pauses never make the animation jump.
    private var clock: Double = 12
    private var lastFrame: CFTimeInterval?
    private var isActive = false
    private var isReady = false
    private var isTornDown = false
    private var readyHandlers: [@MainActor () -> Void] = []

    init(config: ShaderConfig, settings: ShaderRenderSettings) throws {
        let context = MetalContext.shared
        guard let device = context.device, let queue = context.commandQueue else { throw ShaderError.noDevice }
        guard let source = config.resolvedSource else { throw ShaderError.missingSource }
        pipeline = try context.pipeline(for: source)
        commandQueue = queue
        self.source = source
        params = config.params
        detail = config.detail
        uniforms = ShaderUniforms(params: config.params)
        self.settings = settings
        metalView = BudgetedMetalView(frame: .zero, device: device)
        super.init()

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = settings.frameRate
        metalView.pixelBudget = settings.pixelBudget * detail
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metalLayer.maximumDrawableCount = 2
            metalLayer.magnificationFilter = .linear
            metalLayer.isOpaque = true
        }
        metalView.delegate = self
        metalView.onFirstDrawableSize = { [weak self] in
            MainActor.assumeIsolated { self?.renderFirstFrame() }
        }
    }

    // MARK: WallpaperRenderer

    func setActive(_ active: Bool) {
        guard !isTornDown, active != isActive else { return }
        isActive = active
        lastFrame = nil
        metalView.isPaused = !active
    }

    func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if isReady { handler() } else { readyHandlers.append(handler) }
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        metalView.isPaused = true
        metalView.delegate = nil
        metalView.onFirstDrawableSize = nil
        readyHandlers.removeAll()
        metalView.removeFromSuperview()
    }

    // MARK: Live updates

    func update(config: ShaderConfig) throws {
        if let newSource = config.resolvedSource, newSource != source {
            pipeline = try MetalContext.shared.pipeline(for: newSource)
            source = newSource
        }
        params = config.params
        uniforms.apply(config.params)
        if config.detail != detail {
            detail = config.detail
            metalView.pixelBudget = settings.pixelBudget * detail
        }
        if !isActive, isReady { metalView.draw() }
    }

    func update(settings newSettings: ShaderRenderSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        metalView.preferredFramesPerSecond = newSettings.frameRate
        metalView.pixelBudget = newSettings.pixelBudget * detail
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        let now = CACurrentMediaTime()
        if isActive, let lastFrame {
            clock += min(now - lastFrame, 0.1) * params.speed
        }
        lastFrame = now

        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        uniforms.time = Float(clock)
        uniforms.resolution = SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &uniforms) { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func renderFirstFrame() {
        guard !isTornDown else { return }
        metalView.draw()
        isReady = true
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }
}
