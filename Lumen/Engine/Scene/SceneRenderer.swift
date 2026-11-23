import AppKit
import MetalKit
import simd

struct SceneRenderSettings: Equatable {
    var frameRate: Int
    /// Upper bound on pixels the scene is rendered at; the result is scaled to the display.
    var pixelBudget: Double
    var scaling: VideoScaling
    var muted = true
    var volume: Double = 1

    static let preview = SceneRenderSettings(frameRate: 30, pixelBudget: 900_000, scaling: .fill)
}

/// Draws a Wallpaper Engine scene with Metal.
@MainActor
final class SceneRenderer: NSObject, WallpaperRenderer, PointerAwareRenderer, PropertyAwareRenderer, MTKViewDelegate {
    struct Source {
        let id: UUID
        let folder: URL
        let entry: String
        let assets: URL?
        let preview: URL?
    }

    enum State: Equatable {
        case loading
        case ready
        case failed(String)
    }

    var view: NSView { container }
    private(set) var state: State = .loading
    /// Scene features Lumen skipped (particles, text…), for the details page.
    private(set) var skippedFeatures: [String] = []

    private let source: Source
    private let container = NSView()
    private let metalView: BudgetedMetalView
    private let fallbackView = NSImageView()
    private let commandQueue: MTLCommandQueue
    private let device: MTLDevice
    private var instance: SceneInstance?
    private var settings: SceneRenderSettings
    private var framing: WallpaperFraming
    private var values: [String: PropertyValue]
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    private var isActive = false
    private var isReady = false
    private var isTornDown = false
    private var readyHandlers: [@MainActor () -> Void] = []
    private var clock: Double = 0
    private var lastFrame: CFTimeInterval?
    private var pointer = SIMD2<Float>(0.5, 0.5)
    private var pointerTarget: SIMD2<Float>?
    private var pointerLast = SIMD2<Float>(0.5, 0.5)
    private var parallax = SIMD2<Float>(0, 0)
    private var presentRect = SIMD4<Float>(-1, -1, 2, 2)

    init(source: Source, values: [String: PropertyValue], settings: SceneRenderSettings, framing: WallpaperFraming) throws {
        guard let device = MetalContext.shared.device, let queue = MetalContext.shared.commandQueue else { throw ShaderError.noDevice }
        self.source = source
        self.values = values
        self.settings = settings
        self.framing = framing
        self.device = device
        commandQueue = queue
        metalView = BudgetedMetalView(frame: .zero, device: device)
        super.init()

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        fallbackView.imageScaling = .scaleProportionallyUpOrDown
        fallbackView.autoresizingMask = [.width, .height]
        fallbackView.isHidden = true
        container.addSubview(fallbackView)

        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = settings.frameRate
        metalView.pixelBudget = settings.pixelBudget * 1.5
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.autoresizingMask = [.width, .height]
        if let layer = metalView.layer as? CAMetalLayer {
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.maximumDrawableCount = 2
            layer.magnificationFilter = .linear
            layer.isOpaque = true
        }
        metalView.delegate = self
        metalView.isHidden = true
        container.addSubview(metalView)
        load()
    }

    // MARK: Loading

    private func load() {
        loadGeneration += 1
        let generation = loadGeneration
        let display = NSScreen.screens.map(\.pixelSize).max { $0.width * $0.height < $1.width * $1.height } ?? CGSize(width: 3840, height: 2160)
        let request = SceneLoader.Request(
            folder: source.folder, entry: source.entry, assets: source.assets, values: values,
            displaySize: SIMD2(Float(display.width), Float(display.height)),
            pixelBudget: settings.pixelBudget, device: device, queue: commandQueue
        )
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result: Result<SceneInstance, Error> = await Task.detached(priority: .userInitiated) {
                Result { try SceneLoader.load(request) }
            }.value
            guard let self, !self.isTornDown, generation == self.loadGeneration else { return }
            switch result {
            case .success(let instance):
                self.instance = instance
                self.skippedFeatures = instance.unsupported
                self.state = .ready
                self.fallbackView.isHidden = true
                self.metalView.isHidden = false
                self.layoutScene()
                self.metalView.isPaused = !self.isActive
                instance.sounds?.configure(muted: self.settings.muted, volume: Float(self.settings.volume))
                instance.setPlaying(self.isActive)
                if !self.isActive { self.metalView.draw() }
            case .failure(let error):
                Log.engine.error("Scene failed to load: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error.localizedDescription)
                if self.instance == nil { self.showFallback() }
            }
            self.markReady()
        }
    }

    private func showFallback() {
        metalView.isHidden = true
        guard let preview = source.preview, let image = NSImage(contentsOf: preview) else { return }
        fallbackView.image = image
        fallbackView.frame = container.bounds
        fallbackView.isHidden = false
    }

    private func markReady() {
        guard !isReady, !isTornDown else { return }
        isReady = true
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }

    // MARK: WallpaperRenderer

    func setActive(_ active: Bool) {
        guard !isTornDown, active != isActive else { return }
        isActive = active
        lastFrame = nil
        metalView.isPaused = !active || instance == nil
        instance?.setPlaying(active)
    }

    func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if isReady { handler() } else { readyHandlers.append(handler) }
    }

    func setFraming(_ framing: WallpaperFraming) {
        self.framing = framing
        layoutScene()
        if !isActive, instance != nil { metalView.draw() }
    }

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        loadTask?.cancel()
        metalView.isPaused = true
        metalView.delegate = nil
        readyHandlers.removeAll()
        instance = nil
        container.removeFromSuperview()
    }

    func update(settings newSettings: SceneRenderSettings) {
        guard newSettings != settings else { return }
        let needsReload = newSettings.pixelBudget != settings.pixelBudget
        settings = newSettings
        instance?.sounds?.configure(muted: newSettings.muted, volume: Float(newSettings.volume))
        metalView.preferredFramesPerSecond = newSettings.frameRate
        metalView.pixelBudget = newSettings.pixelBudget * 1.5
        layoutScene()
        if needsReload { load() }
    }

    /// Property changes can switch layers, effects and combos, so the scene is rebuilt; the
    /// old one keeps playing until the new one is ready, and textures load from cache quickly.
    func update(values newValues: [String: PropertyValue]) {
        guard newValues != values else { return }
        values = newValues
        load()
    }

    // MARK: Pointer

    func pointerMoved(to point: CGPoint?) {
        guard let point, container.bounds.width > 0, container.bounds.height > 0 else {
            pointerTarget = nil
            return
        }
        // Map from view points to the scene's 0…1 coordinates (y down) through the placement.
        let bounds = container.bounds
        let u = (Float(point.x / bounds.width) * 2 - 1 - presentRect.x) / presentRect.z
        let v = ((1 - Float(point.y / bounds.height)) * 2 - 1 - presentRect.y) / presentRect.w
        pointerTarget = SIMD2(min(max(u, 0), 1), min(max(1 - v, 0), 1))
    }

    func pointerPressed(_ isDown: Bool, at point: CGPoint) {}

    // MARK: Drawing

    private func layoutScene() {
        guard let instance else { return }
        let bounds = CGRect(x: 0, y: 0, width: max(metalView.drawableSize.width, 1), height: max(metalView.drawableSize.height, 1))
        let content = CGSize(width: CGFloat(instance.canvas.x), height: CGFloat(instance.canvas.y))
        let rect = framing.rect(for: content, in: bounds, scaling: settings.scaling)
        presentRect = SIMD4(
            Float(rect.minX / bounds.width * 2 - 1), Float(rect.minY / bounds.height * 2 - 1),
            Float(rect.width / bounds.width * 2), Float(rect.height / bounds.height * 2)
        )
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { layoutScene() }
    }

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let instance, !isTornDown else { return }
        // A hidden window gets no drawables; asking would stall the main thread for a second.
        if let window = view.window, !window.occlusionState.contains(.visible), isReady { return }
        let now = CACurrentMediaTime()
        let delta = lastFrame.map { min(now - $0, 0.1) } ?? 0
        if isActive { clock += delta }
        lastFrame = now
        advancePointer(delta: Float(delta), document: instance.document)

        guard let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer()
        else { return }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute, .second], from: Date())
        let daytime = Float((components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)) / 86400
        let pointerCanvas: SIMD2<Float>? = pointerTarget.map { SIMD2($0.x * instance.canvas.x, (1 - $0.y) * instance.canvas.y) }
        let frame = SceneInstance.Frame(
            time: Float(clock),
            delta: isActive ? Float(delta) : 0,
            pointerCanvas: pointerCanvas,
            daytime: daytime,
            pointer: pointer,
            pointerLast: pointerLast,
            cameraOffset: parallax,
            parallax: parallax / max(instance.canvas, SIMD2(1, 1))
        )
        instance.encode(into: buffer, frame: frame)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setRenderPipelineState(instanceUtility(instance).present)
            var rect = presentRect
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(instance.outputTexture, index: 0)
            encoder.setFragmentSamplerState(instance.textures.samplers.state(nearest: false, clamp: true), index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }

    private func instanceUtility(_ instance: SceneInstance) -> SceneUtilityPipelines {
        // Built on first load; never fails after a scene has loaded.
        try! SceneUtilityPipelines.shared(device: device)
    }

    /// Eases the pointer and the parallax camera towards where the pointer is.
    private func advancePointer(delta: Float, document: SceneDocument) {
        pointerLast = pointer
        let target = pointerTarget ?? SIMD2(0.5, 0.5)
        let ease = min(1, delta * 8)
        pointer += (target - pointer) * ease
        guard document.parallaxEnabled else { return }
        let centred = SIMD2(pointer.x - 0.5, 0.5 - pointer.y) * 2
        let reach = document.canvas.x * 0.025 * document.parallaxAmount * max(document.parallaxMouseInfluence, 0.2) * 2
        let goal = -centred * reach
        let follow = min(1, delta / max(document.parallaxDelay, 0.02))
        parallax += (goal - parallax) * follow
    }
}
