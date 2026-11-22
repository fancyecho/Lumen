import AppKit
import CoreGraphics

/// Measures how much of each display's desktop is hidden behind regular windows
/// (maximised apps, full-screen Spaces) so a wallpaper can stop decoding once the
/// covered share passes the user's threshold.
///
/// Window bounds and layers come from `CGWindowListCopyWindowInfo`, which needs no
/// Screen Recording permission. Checks run on app/Space changes plus a slow,
/// tolerance-coalesced timer for windows being moved or resized.
@MainActor
final class OcclusionMonitor {
    var onChange: (() -> Void)?

    /// Covered share of each display's usable area (0...1), keyed by display UUID.
    private(set) var coverage: [String: Double] = [:]

    /// Pause once at least this share of the desktop is covered (0.5...1).
    var threshold: Double = 0.95 {
        didSet { if oldValue != threshold { onChange?() } }
    }

    var isEnabled = false {
        didSet {
            guard oldValue != isEnabled else { return }
            isEnabled ? start() : stop()
        }
    }

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settleTask: Task<Void, Never>?

    func isCovered(_ displayID: String) -> Bool {
        guard isEnabled, let share = coverage[displayID] else { return false }
        return share >= threshold - 0.001
    }

    func evaluate() {
        guard isEnabled else { return }
        let measured = Self.measureCoverage()
        // Notify only on whole-percent changes so the UI stays live without churn.
        let rounded = measured.mapValues { ($0 * 100).rounded() }
        if rounded != coverage.mapValues({ ($0 * 100).rounded() }) {
            coverage = measured
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
        if !coverage.isEmpty {
            coverage.removeAll()
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

    static func measureCoverage() -> [String: Double] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [:] }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
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

        // CoreGraphics window bounds use a top-left origin on the primary display.
        // The usable area excludes the menu bar and Dock, which never count as desktop.
        let primaryHeight = primary.frame.height
        var result: [String: Double] = [:]
        for screen in screens {
            let visible = screen.visibleFrame
            let area = CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
            result[screen.displayUUID] = coveredFraction(of: area, by: rects)
        }
        return result
    }

    /// Exact area of the union of `rects` inside `area`, via coordinate compression.
    nonisolated static func coveredFraction(of area: CGRect, by rects: [CGRect]) -> Double {
        guard area.width > 0, area.height > 0 else { return 0 }
        let clipped = rects.compactMap { rect -> CGRect? in
            let piece = rect.intersection(area)
            return piece.isNull || piece.isEmpty ? nil : piece
        }
        guard !clipped.isEmpty else { return 0 }

        let xs = Array(Set(clipped.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set(clipped.flatMap { [$0.minY, $0.maxY] })).sorted()
        var covered: CGFloat = 0
        for i in 0..<(xs.count - 1) {
            let midX = (xs[i] + xs[i + 1]) / 2
            let column = clipped.filter { $0.minX <= midX && midX <= $0.maxX }
            guard !column.isEmpty else { continue }
            for j in 0..<(ys.count - 1) {
                let midY = (ys[j] + ys[j + 1]) / 2
                if column.contains(where: { $0.minY <= midY && midY <= $0.maxY }) {
                    covered += (xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])
                }
            }
        }
        return min(1, Double(covered / (area.width * area.height)))
    }
}
