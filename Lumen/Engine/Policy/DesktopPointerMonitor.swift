import AppKit

/// Follows the pointer while it rests on the desktop itself (not over another app's window)
/// and reports it per display, so web and scene wallpapers can react to it as they do in
/// Wallpaper Engine. Mouse monitors need no special permission.
@MainActor
final class DesktopPointerMonitor {
    /// `point` is in the display's coordinates, top-left origin, in points; nil when the pointer left.
    var onMove: ((_ displayID: String, _ point: CGPoint?) -> Void)?
    var onButton: ((_ displayID: String, _ isDown: Bool, _ point: CGPoint) -> Void)?

    var isEnabled = false {
        didSet { if isEnabled != oldValue { isEnabled ? install() : uninstall() } }
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastCheck: CFTimeInterval = 0
    private var lastDisplay: String?
    private var lastWindowNumber = -1
    private var lastWindowIsDesktop = false

    private func install() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
            return event
        }
    }

    private func uninstall() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let lastDisplay { onMove?(lastDisplay, nil) }
        lastDisplay = nil
    }

    private func handle(_ type: NSEvent.EventType) {
        let location = NSEvent.mouseLocation
        let isButton = type == .leftMouseDown || type == .leftMouseUp
        if !isButton {
            // Moves arrive at the hardware rate; the desktop needs far fewer.
            let now = CACurrentMediaTime()
            guard now - lastCheck > 1.0 / 90 else { return }
            lastCheck = now
        }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(location, $0.frame, false) }) else { return }
        let displayID = screen.displayUUID
        let point = CGPoint(x: location.x - screen.frame.minX, y: screen.frame.maxY - location.y)

        guard isDesktopUnder(location) else {
            if let lastDisplay {
                onMove?(lastDisplay, nil)
                self.lastDisplay = nil
            }
            return
        }
        if let lastDisplay, lastDisplay != displayID { onMove?(lastDisplay, nil) }
        lastDisplay = displayID
        if isButton {
            onButton?(displayID, type == .leftMouseDown, point)
        } else {
            onMove?(displayID, point)
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
