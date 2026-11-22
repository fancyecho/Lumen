import AppKit
import Foundation
import IOKit.ps
import Observation

/// Watches every system condition that should stop wallpapers from animating.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var systemSleeping = false
    private(set) var displaysAsleep = false
    private(set) var screenLocked = false
    private(set) var screenSaverRunning = false
    private(set) var sessionInactive = false
    private(set) var onBattery = false
    private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var thermalState = ProcessInfo.processInfo.thermalState

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onWake: (() -> Void)?
    @ObservationIgnored private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var started = false

    var thermalPressureHigh: Bool { thermalState == .serious || thermalState == .critical }

    var thermalDescription: String {
        switch thermalState {
        case .nominal: String(localized: "Normal")
        case .fair: String(localized: "Warm")
        case .serious: String(localized: "Hot")
        case .critical: String(localized: "Critical")
        @unknown default: String(localized: "Unknown")
        }
    }

    func start() {
        guard !started else { return }
        started = true

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemSleeping = true }
        observe(workspace, NSWorkspace.didWakeNotification) { monitor in
            monitor.systemSleeping = false
            monitor.onWake?()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { monitor in
            monitor.displaysAsleep = false
            monitor.onWake?()
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screenSaverRunning = true }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screenSaverRunning = false }

        let local = NotificationCenter.default
        observe(local, Notification.Name.NSProcessInfoPowerStateDidChange) {
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        observe(local, ProcessInfo.thermalStateDidChangeNotification) {
            $0.thermalState = ProcessInfo.processInfo.thermalState
        }

        startPowerSourceMonitoring()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ update: @escaping @MainActor (SystemMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self)
                Log.policy.info("System event \(name.rawValue, privacy: .public)")
                self.onChange?()
            }
        }
        tokens.append((center, token))
    }

    private func startPowerSourceMonitoring() {
        refreshPowerSource()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.refreshPowerSource()
                monitor.onChange?()
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    private func refreshPowerSource() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return }
        onBattery = (type as String) == kIOPMBatteryPowerKey
    }
}
