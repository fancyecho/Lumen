import AppKit
import CoreGraphics

/// Detects displays whose desktop is fully hidden behind regular windows
/// (maximised apps, full-screen Spaces) so their wallpaper can stop decoding.
///
/// Window bounds and layers come from `CGWindowListCopyWindowInfo`, which needs no
/// Screen Recording permission. Checks run on app/Space changes plus a slow,
/// tolerance-coalesced timer for windows being moved or resized.
@MainActor
final class OcclusionMonitor {
    var onChange: (() -> Void)?
    private(set) var coveredDisplays: Set<String> = []

    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            isEnabled ? start() : stop()
        }
    }

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settleTask: Task<Void, Never>?

    func isCovered(_ displayID: String) -> Bool { coveredDisplays.contains(displayID) }

    func evaluate() {
        guard isEnabled else { return }
        let covered = Self.computeCoveredDisplays()
        if covered != coveredDisplays {
            coveredDisplays = covered
            Log.policy.info("Covered displays: \(covered.count)")
            onChange?()
        }
    }

    private func start() {
        evaluate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateAfterAnimations() }
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        settleTask?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if !coveredDisplays.isEmpty {
            coveredDisplays.removeAll()
            onChange?()
        }
    }

    /// Space and app switches animate; check now and again once windows settle.
    private func evaluateAfterAnimations() {
        evaluate()
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.evaluate()
            try? await Task.sleep(for: .milliseconds(800))
            self?.evaluate()
        }
    }

    static func computeCoveredDisplays() -> Set<String> {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var rects: [CGRect] = []
        rects.reserveCapacity(windows.count)
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha < 0.9 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 80, rect.height > 80
            else { continue }
            rects.append(rect)
        }
        guard !rects.isEmpty, let primary = NSScreen.screens.first else { return [] }

        // CoreGraphics window bounds use a top-left origin on the primary display.
        let primaryHeight = primary.frame.height
        var covered = Set<String>()
        for screen in NSScreen.screens {
            let visible = screen.visibleFrame
            let area = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
            if isCovered(area, by: rects) { covered.insert(screen.displayUUID) }
        }
        return covered
    }

    /// Samples a 12×8 grid of points; every one must sit inside some window.
    private static func isCovered(_ area: CGRect, by rects: [CGRect]) -> Bool {
        let candidates = rects.filter { $0.intersects(area) }
        guard !candidates.isEmpty else { return false }
        let columns = 12, rows = 8
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(
                    x: area.minX + (CGFloat(column) + 0.5) / CGFloat(columns) * area.width,
                    y: area.minY + (CGFloat(row) + 0.5) / CGFloat(rows) * area.height
                )
                if !candidates.contains(where: { $0.contains(point) }) { return false }
            }
        }
        return true
    }
}
