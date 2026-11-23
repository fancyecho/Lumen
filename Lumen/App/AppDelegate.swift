import AppKit
import CoreServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnostics = LocalDiagnostics()

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppModel.shared.launchedAsLoginItem = Self.isLoginItemLaunch()
        _ = AppLanguage.atLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        diagnostics.start()
        AppModel.shared.start()
    }

    /// "Open With → Lumen" and drops on the Dock icon import the videos.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.start()
        AppModel.shared.router.show(.library)
        AppModel.shared.importFiles(urls)
    }

    /// Wallpapers keep playing after the window closes; the menu bar item stays.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        diagnostics.stop()
        AppModel.shared.shutdown()
    }

    private static func isLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
