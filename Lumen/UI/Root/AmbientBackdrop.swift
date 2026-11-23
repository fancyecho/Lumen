import SwiftUI

/// The window background: a calm, deep neutral obsidian canvas with a restrained,
/// pre-blurred echo of the active (or inspected) wallpaper so artwork always stays the hero.
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
                            .opacity(0.34)
                            .transition(.opacity)
                            .id(ObjectIdentifier(image))
                    }
                }
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: Theme.Surface.canvas.opacity(0.52), location: 0),
                    .init(color: Theme.Surface.canvas.opacity(0.78), location: 0.48),
                    .init(color: Theme.Surface.canvas.opacity(0.95), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .task(id: source.map { ThumbnailCache.shared.cacheKey(for: $0) }) {
            guard let source else {
                image = nil
                return
            }
            let loaded = await ThumbnailCache.shared.backdrop(for: source, library: model.library)
            if reduceMotion {
                image = loaded
            } else {
                withAnimation(Theme.Motion.backdrop) { image = loaded }
            }
        }
    }
}
