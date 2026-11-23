import AppKit
import QuartzCore

/// A borderless window that lives at the desktop level: above the system wallpaper,
/// below Finder's desktop icons, on every Space, and invisible to clicks and Mission Control cycling.
final class DesktopWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the desktop window for one display and cross-fades between renderers.
@MainActor
final class DesktopHost {
    let displayID: String
    private let window: DesktopWindow
    private let rootView: NSView

    /// The newest renderer. It may still be waiting for its first frame.
    private(set) var renderer: WallpaperRenderer?
    /// The renderer currently visible on screen.
    private var displayed: WallpaperRenderer?
    private(set) var wallpaperID: UUID?
    private var isShown = false
    private var isActive = false
    private var occlusionObserver: NSObjectProtocol?

    init(screen: NSScreen, displayID: String) {
        self.displayID = displayID
        window = DesktopWindow(screen: screen)
        rootView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.black.cgColor
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView
        window.alphaValue = 0

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.policy.debug("Desktop window \(self.displayID, privacy: .public) occlusion visible=\(self.window.occlusionState.contains(.visible))")
            }
        }
    }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }

    func updateScreen(_ screen: NSScreen) {
        if window.frame != screen.frame {
            window.setFrame(screen.frame, display: true)
        }
    }

    func present(_ newRenderer: WallpaperRenderer, wallpaperID: UUID, animated: Bool) {
        // A renderer that never reached the screen is simply dropped.
        if let pending = renderer, pending !== displayed {
            pending.tearDown()
        }
        renderer = newRenderer
        self.wallpaperID = wallpaperID

        let view = newRenderer.view
        view.frame = rootView.bounds
        view.autoresizingMask = [.width, .height]
        let crossfade = animated && isShown && displayed != nil
        if crossfade { view.alphaValue = 0 }
        rootView.addSubview(view)
        newRenderer.setActive(isActive)
        if !window.isVisible { window.orderFrontRegardless() }

        newRenderer.whenReady { [weak self, weak newRenderer] in
            guard let self, let newRenderer, self.renderer === newRenderer else { return }
            let previous = self.displayed
            self.displayed = newRenderer
            if !self.isShown {
                self.isShown = true
                self.fadeWindow(to: 1, duration: animated ? 0.7 : 0.3) { previous?.tearDown() }
            } else if crossfade {
                let tearDownPrevious: @MainActor () -> Void = { previous?.tearDown() }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.9
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    view.animator().alphaValue = 1
                } completionHandler: {
                    MainActor.assumeIsolated(tearDownPrevious)
                }
            } else {
                view.alphaValue = 1
                previous?.tearDown()
            }
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        renderer?.setActive(active)
        if let displayed, displayed !== renderer { displayed.setActive(active) }
    }

    func dismiss(animated: Bool) {
        let renderers = [renderer, displayed].compactMap { $0 }
        renderer = nil
        displayed = nil
        wallpaperID = nil
        let finish = { [window] in
            window.orderOut(nil)
            renderers.forEach { $0.tearDown() }
        }
        if animated, isShown {
            fadeWindow(to: 0, duration: 0.5, completion: finish)
        } else {
            finish()
        }
        isShown = false
    }

    private func fadeWindow(to alpha: CGFloat, duration: TimeInterval, completion: @escaping @MainActor () -> Void) {
        window.isOpaque = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = alpha
        } completionHandler: { [window] in
            MainActor.assumeIsolated {
                // Opaque windows let the window server skip compositing what's underneath.
                if alpha >= 1 { window.isOpaque = true }
                completion()
            }
        }
    }
}
