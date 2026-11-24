import AppKit
import MetalKit
import QuartzCore

/// Draws PRO Strands on one display (or in a preview) at full pixel density, as the strands are a
/// pixel or two wide. Cost follows activity, as in the standalone app: 60 fps only while strands
/// move under the pointer, 30 fps for the idle light flow, and no drawing at all once everything
/// is at rest with the flow turned off.
@MainActor
final class PROStrandsRenderer: NSObject, WallpaperRenderer, PointerAwareRenderer, PropertyAwareRenderer, MTKViewDelegate {
    var view: NSView { metalView }

    private let metalView: BudgetedMetalView
    private let isPreview: Bool
    private var strands: PROStrands.StrandRenderer?
    private var options: PROStrands.Options
    private var settings: NativeRenderSettings
    private var isActive = false
    private var isReady = false
    private var isTornDown = false
    private var hasDrawable = false
    /// Stopped because nothing moves (strands at rest, flow off).
    private var isIdle = false
    private var readyHandlers: [@MainActor () -> Void] = []
    private var lastDraw: Double?
    private var pointerPoint: CGPoint?
    private var pressed = false

    var needsPointer: Bool { !isPreview }
    var onPointerNeedChange: (() -> Void)?

    init(imageURL: URL, values: [String: PropertyValue], settings: NativeRenderSettings, isPreview: Bool = false) throws {
        guard let device = MetalContext.shared.device else { throw CodeSea.SeaError("Metal unavailable") }
        options = PROStrands.Options(values: values)
        self.settings = settings
        self.isPreview = isPreview
        metalView = BudgetedMetalView(frame: .zero, device: device)
        super.init()

        metalView.colorPixelFormat = PROStrands.RenderContext.pixelFormat
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = min(30, settings.frameRate)
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let layer = metalView.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.maximumDrawableCount = 2
            layer.isOpaque = true
        }
        metalView.delegate = self
        metalView.onFirstDrawableSize = { [weak self] in
            MainActor.assumeIsolated {
                self?.hasDrawable = true
                self?.renderFirstFrame()
            }
        }
        Task { @MainActor [weak self] in
            do {
                let context = try await PROStrands.context(imageURL: imageURL)
                guard let self, !self.isTornDown else { return }
                self.strands = PROStrands.StrandRenderer(context: context)
                self.renderFirstFrame()
            } catch {
                Log.engine.error("PRO Strands unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: WallpaperRenderer

    func setActive(_ active: Bool) {
        guard !isTornDown, active != isActive else { return }
        isActive = active
        isIdle = false
        lastDraw = nil
        if !active, let strands {
            // As the standalone app does when it stops: strands settle back to the picture.
            strands.sim.reset()
            strands.upload()
        }
        metalView.isPaused = !active || strands == nil
    }

    func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if isReady { handler() } else { readyHandlers.append(handler) }
    }

    /// The artwork always fills the display, as in the standalone app.
    func setFraming(_ framing: WallpaperFraming) {}

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        onPointerNeedChange = nil
        metalView.isPaused = true
        metalView.delegate = nil
        metalView.onFirstDrawableSize = nil
        readyHandlers.removeAll()
        metalView.removeFromSuperview()
    }

    // MARK: Live updates

    func update(values: [String: PropertyValue]) {
        let newOptions = PROStrands.Options(values: values)
        guard newOptions != options else { return }
        options = newOptions
        if isActive { wake() } else if isReady { metalView.draw() }
    }

    func update(settings newSettings: NativeRenderSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        wake()
    }

    private func wake() {
        guard isActive, !isTornDown, isIdle, strands != nil else { return }
        isIdle = false
        lastDraw = nil
        metalView.isPaused = false
    }

    // MARK: PointerAwareRenderer

    func pointerMoved(to point: CGPoint?) {
        pointerPoint = point
        if point == nil { pressed = false }
        if point != nil { wake() }
    }

    func pointerPressed(_ isDown: Bool, at point: CGPoint) {
        pointerPoint = point
        pressed = isDown
        wake()
    }

    /// The pointer in the artwork's pixels (the picture covers the display, centred).
    private func pointerSample(for strands: PROStrands.StrandRenderer) -> PROStrands.PointerSample {
        guard let point = pointerPoint, metalView.bounds.width > 0 else { return PROStrands.PointerSample() }
        let size = metalView.drawableSize
        let density = size.width / metalView.bounds.width
        let layout = strands.ctx.layout
        let (scale, offset) = PROStrands.StrandRenderer.fit(target: size, source: CGSize(width: layout.srcWidth, height: layout.srcHeight))
        let device = SIMD2<Float>(Float(point.x * density), Float(point.y * density))
        return PROStrands.PointerSample(position: (device - offset) / scale, present: true, pressed: pressed)
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render() }
    }

    private func render() {
        if let window = metalView.window, !window.occlusionState.contains(.visible), isReady { return }
        guard let strands, metalView.drawableSize.width > 1 else { return }
        let now = CACurrentMediaTime()
        let dt = Float(lastDraw.map { now - $0 } ?? 1 / 60)
        lastDraw = now
        strands.sim.params = options.sim
        strands.look = options.look
        let pointer = pointerSample(for: strands)
        if strands.sim.advance(dt: dt, pointer: pointer) { strands.upload() }

        guard let pass = metalView.currentRenderPassDescriptor, let drawable = metalView.currentDrawable,
              let buffer = strands.ctx.queue.makeCommandBuffer() else { return }
        strands.encode(into: pass, size: metalView.drawableSize, commandBuffer: buffer)
        buffer.present(drawable)
        buffer.commit()

        let interacting = strands.sim.active || (pointer.present && pointer.pressed)
        let capped = options.batteryCap && settings.onBattery
        let fps: Int
        if interacting {
            fps = capped ? 30 : 60
        } else if options.look.flow > 0 {
            fps = capped ? 20 : 30
        } else {
            fps = 0
        }
        if fps == 0 {
            guard isActive else { return }
            isIdle = true
            metalView.isPaused = true
        } else {
            let target = max(1, min(fps, settings.frameRate))
            if metalView.preferredFramesPerSecond != target { metalView.preferredFramesPerSecond = target }
        }
    }

    /// Needs both the strand layout and a sized drawable.
    private func renderFirstFrame() {
        guard !isTornDown, !isReady, hasDrawable, strands != nil else { return }
        metalView.draw()
        isReady = true
        if isActive { metalView.isPaused = false }
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }
}
