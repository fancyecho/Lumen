import AppKit

/// Follows the pointer while it rests on the desktop itself (not over another app's window)
/// and reports it per display, so web and scene wallpapers can react to it as they do in
/// Wallpaper Engine. Mouse monitors need no special permission.
///
/// Position is polled at the render frame rate (capped at 60 Hz) while an interactive wallpaper
/// is actively playing, because macOS stops delivering global `mouseMoved` events when the
/// pointer rests over the desktop or an `ignoresMouseEvents` wallpaper window. Stationary
/// ticks short-circuit before any window hit-testing; event monitors wake and forward clicks.
@MainActor
final class DesktopPointerMonitor {
    /// `point` is in the display's coordinates, top-left origin, in points; nil when the pointer left.
    var onMove: ((_ displayID: String, _ point: CGPoint?) -> Void)?
    var onButton: ((_ displayID: String, _ isDown: Bool, _ point: CGPoint) -> Void)?

    var isEnabled = false {
        didSet { if isEnabled != oldValue { isEnabled ? install() : uninstall() } }
    }

    /// Displays currently playing a wallpaper that consumes pointer input.
    /// When non-empty, hit-testing is skipped while the pointer is on other displays.
    var activeDisplayIDs: Set<String> = [] {
        didSet {
            guard activeDisplayIDs != oldValue else { return }
            if let lastDisplay, !activeDisplayIDs.contains(lastDisplay) {
                onMove?(lastDisplay, nil)
                self.lastDisplay = nil
            }
            lastLocation = nil
        }
    }

    /// Polling rate in Hz (matches render frame rate, clamped to 15...60).
    var pollRate: Int = 30 {
        didSet {
            let clamped = min(max(pollRate, 15), 60)
            if clamped != pollRate { pollRate = clamped; return }
            if clamped != oldValue, isEnabled { restartTimer() }
        }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private var lastLocation: NSPoint?
    private var lastDisplay: String?
    private var lastWindowNumber = -1
    private var lastWindowIsDesktop = false

    private func install() {
        lastLocation = nil
        lastWindowNumber = -1
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleEvent(event.type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handleEvent(event.type) }
            return event
        }
        restartTimer()
        poll(force: true)
    }

    private func uninstall() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        lastLocation = nil
        lastWindowNumber = -1
        if let lastDisplay { onMove?(lastDisplay, nil) }
        lastDisplay = nil
    }

    private func restartTimer() {
        pollTimer?.invalidate()
        let interval = 1.0 / Double(min(max(pollRate, 15), 60))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(force: false) }
        }
        timer.tolerance = min(interval * 0.25, 0.004)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func handleEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown, .leftMouseUp:
            // Clicks can bring another window forward or dismiss one; recheck window level.
            lastWindowNumber = -1
            let location = NSEvent.mouseLocation
            lastLocation = location
            forward(at: location, buttonDown: type == .leftMouseDown)
        case .leftMouseDragged, .mouseMoved:
            poll(force: false)
        default:
            break
        }
    }

    private func poll(force: Bool) {
        let location = NSEvent.mouseLocation
        if !force, let lastLocation, location == lastLocation { return }
        lastLocation = location
        forward(at: location, buttonDown: nil)
    }

    private func forward(at location: NSPoint, buttonDown: Bool?) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else {
            leaveLastDisplay()
            return
        }
        let displayID = screen.displayUUID
        if !activeDisplayIDs.isEmpty, !activeDisplayIDs.contains(displayID) {
            leaveLastDisplay()
            return
        }
        guard isDesktopUnder(location) else {
            leaveLastDisplay()
            return
        }
        if let lastDisplay, lastDisplay != displayID { onMove?(lastDisplay, nil) }
        lastDisplay = displayID
        // Display coordinates, top-left origin, in points.
        let point = CGPoint(x: location.x - screen.frame.minX, y: screen.frame.maxY - location.y)
        if let buttonDown {
            onButton?(displayID, buttonDown, point)
        } else {
            onMove?(displayID, point)
        }
    }

    private func leaveLastDisplay() {
        if let lastDisplay {
            onMove?(lastDisplay, nil)
            self.lastDisplay = nil
        }
    }

    /// True when the topmost window under the pointer is part of the desktop (Finder's icon
    /// layer or Lumen's own wallpaper window), i.e. the wallpaper is what the person points at.
    private func isDesktopUnder(_ location: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return true }
        if number == lastWindowNumber { return lastWindowIsDesktop }
        var isDesktop = false
        if let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]],
           let layer = info.first?[kCGWindowLayer as String] as? Int {
            isDesktop = layer <= Int(CGWindowLevelForKey(.desktopIconWindow))
        }
        lastWindowNumber = number
        lastWindowIsDesktop = isDesktop
        return isDesktop
    }
}
