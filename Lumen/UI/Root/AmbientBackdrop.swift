import SwiftUI

/// The window background: the room takes on the colour of the active (or inspected) wallpaper.
///
/// The image is `ThumbnailCache.atmosphere` — blurred and brightness-normalised once per wallpaper —
/// so it can sit at full strength without ever washing out text. Two soft bands keep the toolbar and
/// the floating Now Playing bar grounded, and a gentle vignette draws the eye to the centre.
/// Everything here is static: no per-frame work while the window is open.
struct AmbientBackdrop: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var focus: Wallpaper?
    @State private var image: NSImage?

    private var source: Wallpaper? {
        if let focus { return focus }
        if let id = model.engine.primaryDisplay?.wallpaperID, let wallpaper = model.library.wallpaper(id: id) {
            return wallpaper
        }
        if let id = model.engine.displays.lazy.compactMap(\.wallpaperID).first, let wallpaper = model.library.wallpaper(id: id) {
            return wallpaper
        }
        return model.library.builtins.first
    }

    var body: some View {
        ZStack {
            Theme.Surface.canvas
            Color.clear
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                            .id(ObjectIdentifier(image))
                    }
                }
                .clipped()
            RadialGradient(
                colors: [.clear, .black.opacity(0.32)],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 120,
                endRadius: 1100
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.34), location: 0),
                    .init(color: .clear, location: 0.18),
                    .init(color: .clear, location: 0.72),
                    .init(color: .black.opacity(0.38), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: source.map { ThumbnailCache.shared.cacheKey(for: $0) }) {
            guard let source else {
                image = nil
                return
            }
            let loaded = await ThumbnailCache.shared.atmosphere(for: source, library: model.library)
            if reduceMotion {
                image = loaded
            } else {
                withAnimation(Theme.Motion.backdrop) { image = loaded }
            }
        }
    }
}
