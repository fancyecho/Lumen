import AppKit
import MetalKit
import QuartzCore

/// Where she appears. As in the standalone app she forms on one display only: the one under the
/// pointer when she starts (or where the person triple-clicked), and only that display moves her
/// timeline forward, so a covered display pauses her instead of letting another play on.
@MainActor
final class CodeSeaStage {
    let director: CodeSea.AvatarDirector
    private var members: [ObjectIdentifier: () -> CodeSeaRenderer?] = [:]
    private var shownOn: ObjectIdentifier?
    private var timer: Timer?

    private static var stages: [String: CodeSeaStage] = [:]

    static func stage(for avatarURL: URL?) -> CodeSeaStage {
        let key = avatarURL?.path ?? ""
        if let stage = stages[key] { return stage }
        let stage = CodeSeaStage()
        stages[key] = stage
        return stage
    }

    private init() {
        director = CodeSea.AvatarDirector(interval: 180, firstDelay: 20)
    }

    func configure(_ options: CodeSea.Options) {
        if director.interval != options.interval { director.interval = options.interval }
        if director.persistent != options.persistent { director.persistent = options.persistent }
    }

    func join(_ renderer: CodeSeaRenderer) {
        members[ObjectIdentifier(renderer)] = { [weak renderer] in renderer }
        updateTimer()
    }

    func leave(_ renderer: CodeSeaRenderer) {
        members[ObjectIdentifier(renderer)] = nil
        if shownOn == ObjectIdentifier(renderer) { shownOn = nil }
        updateTimer()
    }

    private var renderers: [CodeSeaRenderer] { members.values.compactMap { $0() } }

    /// This display's view of her: hidden unless she is (or is about to be) on it.
    func frame(for renderer: CodeSeaRenderer, now: Double) -> CodeSea.AvatarFrame {
        let me = ObjectIdentifier(renderer)
        if director.isActive, let shown = shownOn, shown != me, members[shown]?() != nil { return .hidden }
        let frame = director.frame(now: now)
        guard frame.present else {
            shownOn = nil
            return .hidden
        }
        if shownOn == nil || members[shownOn!]?() == nil { shownOn = elect() }
        return shownOn == me ? frame : .hidden
    }

    /// The display under the pointer, else any.
    private func elect() -> ObjectIdentifier? {
        let pointer = NSEvent.mouseLocation
        let candidates = renderers
        let chosen = candidates.first { $0.screenFrame?.contains(pointer) == true } ?? candidates.first
        return chosen.map(ObjectIdentifier.init)
    }

    func summon(on renderer: CodeSeaRenderer) {
        if !director.isActive { shownOn = ObjectIdentifier(renderer) }
        director.summon()
        renderers.forEach { $0.wake() }
    }

    /// The display showing her stopped drawing for `gap` seconds: her timeline waits too.
    func held(_ renderer: CodeSeaRenderer, gap: Double) {
        if director.isActive, shownOn == ObjectIdentifier(renderer) { director.hold(gap) }
    }

    /// When the sea is still and nothing moves, displays stop drawing; this wakes them when she is due.
    private func updateTimer() {
        if members.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let next = self.director.nextAppearance,
                          CACurrentMediaTime() >= next || self.director.isActive else { return }
                    self.renderers.forEach { $0.wake() }
                }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}

/// Draws Code Sea on one display (or in a preview), at the display's full pixel density: the
/// characters are rasterised one-to-one, so a pixel budget would blur them. Cost is kept down by
/// the frame rate instead (20 fps while only the sea drifts, about 2 ms of GPU per frame at
/// 2940×1912; 30 fps with her, 5–6.5 ms; 60 fps only while the pointer glow fades).
@MainActor
final class CodeSeaRenderer: NSObject, WallpaperRenderer, PointerAwareRenderer, PropertyAwareRenderer, MTKViewDelegate {
    var view: NSView { metalView }

    private let metalView: BudgetedMetalView
    private var context: CodeSea.SeaContext?
    private var hasDrawable = false
    /// Desktop renderers share one; previews show her on their own, from the start.
    private let stage: CodeSeaStage?
    private let previewDirector: CodeSea.AvatarDirector?
    private var sea: CodeSea.SeaRenderer?
    private var options: CodeSea.Options
    private var settings: NativeRenderSettings
    private var isActive = false
    private var isReady = false
    private var isTornDown = false
    /// Stopped because nothing on screen moves (sea motion 0, no glow, no figure).
    private var isIdle = false
    private var readyHandlers: [@MainActor () -> Void] = []
    private var lastDraw: Double?
    private var pointerPoint: CGPoint?
    private var clickTimes: [Double] = []

    /// The pointer glow and the triple-click summon both need the pointer.
    var needsPointer: Bool { stage != nil }
    var onPointerNeedChange: (() -> Void)?

    init(avatarURL: URL?, values: [String: PropertyValue], settings: NativeRenderSettings, isPreview: Bool = false) throws {
        guard let device = MetalContext.shared.device else { throw CodeSea.SeaError("Metal unavailable") }
        options = CodeSea.Options(values: values)
        self.settings = settings
        if isPreview {
            stage = nil
            previewDirector = CodeSea.AvatarDirector(interval: nil, firstDelay: 0)
        } else {
            stage = CodeSeaStage.stage(for: avatarURL)
            previewDirector = nil
        }
        metalView = BudgetedMetalView(frame: .zero, device: device)
        super.init()
        Task { @MainActor [weak self] in
            do {
                let context = try await CodeSea.context(avatarURL: avatarURL)
                guard let self, !self.isTornDown else { return }
                self.context = context
                // A preview shows her from the start, if there is a portrait to show.
                self.previewDirector?.persistent = context.hasFigure
                self.renderFirstFrame()
            } catch {
                Log.engine.error("Code Sea unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        stage?.configure(options)
        stage?.join(self)
        metalView.colorPixelFormat = CodeSea.SeaContext.pixelFormat
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = min(20, settings.frameRate)
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
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
    }

    /// The display this renderer covers, in global points (nil for previews).
    var screenFrame: NSRect? { stage == nil ? nil : metalView.window?.screen?.frame }

    // MARK: WallpaperRenderer

    func setActive(_ active: Bool) {
        guard !isTornDown, active != isActive else { return }
        isActive = active
        isIdle = false
        metalView.isPaused = !active || context == nil
    }

    func whenReady(_ handler: @escaping @MainActor () -> Void) {
        if isReady { handler() } else { readyHandlers.append(handler) }
    }

    /// She always stands centred, clear of the menu bar and Dock, as in the standalone app.
    func setFraming(_ framing: WallpaperFraming) {}

    func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        stage?.leave(self)
        onPointerNeedChange = nil
        metalView.isPaused = true
        metalView.delegate = nil
        metalView.onFirstDrawableSize = nil
        readyHandlers.removeAll()
        metalView.removeFromSuperview()
    }

    // MARK: Live updates

    func update(values: [String: PropertyValue]) {
        let newOptions = CodeSea.Options(values: values)
        guard newOptions != options else { return }
        options = newOptions
        stage?.configure(newOptions)
        if isActive { wake() } else if isReady { metalView.draw() }
    }

    func update(settings newSettings: NativeRenderSettings) {
        guard newSettings != settings else { return }
        settings = newSettings
        wake()
    }

    /// Resumes drawing after an idle stop (she is due, the pointer moved, a setting changed).
    func wake() {
        guard isActive, !isTornDown, isIdle, context != nil else { return }
        isIdle = false
        metalView.isPaused = false
    }

    // MARK: PointerAwareRenderer

    func pointerMoved(to point: CGPoint?) {
        pointerPoint = point
        if point != nil, options.look.hover { wake() }
    }

    func pointerPressed(_ isDown: Bool, at point: CGPoint) {
        pointerPoint = point
        guard isDown, let stage else { return }
        // The standalone app's easter egg: three quick clicks on the desktop summon her.
        let now = CACurrentMediaTime()
        clickTimes = clickTimes.filter { now - $0 < 1.2 } + [now]
        if clickTimes.count >= 3, context?.hasFigure == true {
            clickTimes.removeAll()
            stage.summon(on: self)
        }
        wake()
    }

    // MARK: MTKViewDelegate

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render() }
    }

    private func render() {
        // A hidden window gets no drawables; asking would stall the main thread for a second.
        if let window = metalView.window, !window.occlusionState.contains(.visible), isReady { return }
        guard let context, metalView.bounds.width > 1, metalView.drawableSize.width > 1 else { return }
        let sea = self.sea ?? makeSea(context)
        let now = CACurrentMediaTime()
        // After a pause (covered, other Space, locked, idle) the picture continues from where it
        // stopped instead of jumping ahead by the time it was away.
        if let last = lastDraw, now - last > 0.25 {
            let gap = now - last - 1 / Double(max(metalView.preferredFramesPerSecond, 1))
            sea.hold(gap)
            stage?.held(self, gap: gap)
        }
        lastDraw = now

        let scale = metalView.drawableSize.width / metalView.bounds.width
        sea.look = options.look
        sea.reserved = reservedInsets()
        if !context.hasFigure {
            sea.avatar = .hidden
        } else if let stage {
            sea.avatar = stage.frame(for: self, now: now)
        } else {
            sea.avatar = previewDirector?.frame(now: now) ?? .hidden
        }
        let pointer = pointerPoint.map { SIMD2(Float($0.x * scale), Float($0.y * scale)) }
        sea.updatePointer(pointer, scale: Float(scale), now: now)

        guard let pass = metalView.currentRenderPassDescriptor, let drawable = metalView.currentDrawable,
              let buffer = context.queue.makeCommandBuffer() else { return }
        sea.encode(into: pass, width: Int(metalView.drawableSize.width), height: Int(metalView.drawableSize.height),
                   scale: scale, now: now, commandBuffer: buffer)
        buffer.present(drawable)
        buffer.commit()
        pace(sea)
    }

    /// The standalone app's rates: the glow follows the hand, her drifting needs 30, the slow swell 20.
    private func pace(_ sea: CodeSea.SeaRenderer) {
        let capped = options.batteryCap && settings.onBattery
        let fps: Int
        if sea.hasGlow {
            fps = capped ? 30 : 60
        } else if sea.avatar.present {
            fps = capped ? 20 : 30
        } else if options.look.motion > 0 {
            fps = capped ? 15 : 20
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

    /// Menu bar and Dock edges (points: top, left, bottom, right); she stands in the rest.
    private func reservedInsets() -> SIMD4<Float> {
        guard stage != nil, let screen = metalView.window?.screen else { return .zero }
        let f = screen.frame, v = screen.visibleFrame
        return SIMD4(Float(f.maxY - v.maxY), Float(v.minX - f.minX), Float(v.minY - f.minY), Float(f.maxX - v.maxX))
    }

    /// Each display gets its own (stable) arrangement of characters, as in the standalone app.
    private func makeSea(_ context: CodeSea.SeaContext) -> CodeSea.SeaRenderer {
        let number = metalView.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = number?.uint64Value ?? 1
        let sea = CodeSea.SeaRenderer(context: context, seed: displayID &* 2_654_435_761 &+ 7)
        self.sea = sea
        return sea
    }

    /// Needs both the shared resources and a sized drawable.
    private func renderFirstFrame() {
        guard !isTornDown, !isReady, hasDrawable, context != nil else { return }
        metalView.draw()
        isReady = true
        if isActive { metalView.isPaused = false }
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0() }
    }
}
