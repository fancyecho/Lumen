import SwiftUI

/// The window background: a softly blurred echo of what's on the desktop right now
/// (or of the wallpaper being viewed). It's a static, pre-blurred bitmap, so it
/// costs nothing per frame.
struct AmbientBackdrop: View {
    @Environment(AppModel.self) private var model
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
            Color(red: 0.03, green: 0.03, blue: 0.05)
            Color.clear
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .opacity(0.9)
                            .transition(.opacity)
                            .id(ObjectIdentifier(image))
                    }
                }
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .black.opacity(0.58), location: 0.5),
                    .init(color: .black.opacity(0.8), location: 1),
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
            withAnimation(.easeInOut(duration: 0.9)) { image = loaded }
        }
    }
}
