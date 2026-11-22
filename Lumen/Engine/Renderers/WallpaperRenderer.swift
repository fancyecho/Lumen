import AppKit

/// Something that can fill a desktop window: a looping video or a live shader.
@MainActor
protocol WallpaperRenderer: AnyObject {
    var view: NSView { get }
    /// Playback should run only while active; inactive renderers keep their last frame.
    func setActive(_ active: Bool)
    /// Called once the first frame is on screen, so swaps never flash black.
    func whenReady(_ handler: @escaping @MainActor () -> Void)
    func tearDown()
}
