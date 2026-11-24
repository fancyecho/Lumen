import SwiftUI

/// Grid card: thumbnail that turns into a live preview on hover.
struct WallpaperCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper
    var showsCaption = true

    @State private var hovering = false
    @State private var previewing = false
    @State private var hoverTask: Task<Void, Never>?

    private var isOnDesktop: Bool { !model.engine.displays(showing: wallpaper.id).isEmpty }
    private var isOnEveryDisplay: Bool {
        let engine = model.engine
        return !engine.displays.isEmpty && engine.displays(showing: wallpaper.id).count == engine.displays.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm - 1) {
            artwork
            if showsCaption { caption }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover(perform: setHovering)
        .onDisappear {
            hoverTask?.cancel()
            previewing = false
        }
        .contextMenu { WallpaperMenuItems(wallpaper: wallpaper) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private var artwork: some View {
        ZStack {
            ThumbnailView(wallpaper: wallpaper)
            if previewing {
                LiveWallpaperPreview(wallpaper: wallpaper)
                    .transition(.opacity)
            }
            LinearGradient(
                stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.6), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(false)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) { badges.padding(Theme.Space.sm - 2) }
        .overlay(alignment: .topTrailing) {
            if isOnDesktop {
                ArtBadge(text: String(localized: "On desktop"), dotColor: Theme.playing)
                    .padding(Theme.Space.sm - 2)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                quickActions
                    .padding(Theme.Space.sm - 2)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
            }
        }
        .artworkFrame(isHovering: hovering, highlight: isOnDesktop ? Theme.playing.opacity(0.5) : nil)
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: hovering)
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: previewing)
    }

    /// Only facts worth seeing at a glance sit on the artwork; the kind lives in the caption.
    @ViewBuilder
    private var badges: some View {
        if let video = wallpaper.video {
            HStack(spacing: Theme.Space.xxs) {
                if let label = Format.resolutionClass(video.width, video.height), video.width >= 3840 || video.height >= 2160 {
                    ArtBadge(text: label)
                }
                if video.isHDR { ArtBadge(text: "HDR") }
            }
        }
    }

    private var quickActions: some View {
        HStack(spacing: Theme.Space.xs) {
            Button {
                model.library.toggleFavorite(wallpaper.id)
            } label: {
                Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(wallpaper.isFavorite ? Theme.favorite : Theme.Ink.primary)
            }
            .buttonStyle(.lumenIcon)
            .accessibilityLabel(wallpaper.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))

            if isOnEveryDisplay {
                ChromeLabel { Label("In Use", systemImage: "checkmark") }
            } else {
                Button {
                    model.setWallpaper(wallpaper, on: .allDisplays)
                } label: {
                    Label("Set as Wallpaper", systemImage: "play.fill")
                }
                .buttonStyle(.lumenPrimary)
            }
        }
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.title)
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                Text(WallpaperDescriptor.subtitle(for: wallpaper))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if wallpaper.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.favorite)
                    .accessibilityLabel(Text("Favorite"))
            }
        }
    }

    private func open() {
        switch wallpaper.kind {
        case .shader: model.router.open(.studio(wallpaper.id))
        default: model.router.open(.wallpaper(wallpaper.id))
        }
    }

    private func setHovering(_ isHovering: Bool) {
        hovering = isHovering
        hoverTask?.cancel()
        if isHovering {
            // A short delay avoids spinning up decoders while the pointer sweeps across the grid.
            hoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                previewing = true
            }
        } else {
            previewing = false
        }
    }
}

/// Shared context-menu / overflow-menu items for a wallpaper.
struct WallpaperMenuItems: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    var body: some View {
        let displays = model.engine.displays
        if displays.count > 1 {
            Button("Set on All Displays") { model.setWallpaper(wallpaper, on: .allDisplays) }
            ForEach(displays) { display in
                Button("Set on \(display.name)") { model.setWallpaper(wallpaper, on: .display(display.id)) }
            }
        } else {
            Button("Set as Wallpaper") { model.setWallpaper(wallpaper, on: .allDisplays) }
        }
        Divider()
        Button {
            model.library.toggleFavorite(wallpaper.id)
        } label: {
            if wallpaper.isFavorite { Text("Remove from Favorites") } else { Text("Add to Favorites") }
        }
        if wallpaper.kind == .video || model.library.packageFolder(for: wallpaper) != nil {
            Button("Show in Finder") { model.revealInFinder(wallpaper) }
        }
        if !wallpaper.isBuiltin {
            Divider()
            Button("Delete…", role: .destructive) { model.pendingDeletion = wallpaper }
        }
    }
}

/// Primary "Set as Wallpaper" control. With several displays a small menu beside it picks one;
/// the main button always means "everywhere".
struct SetWallpaperButton: View {
    @Environment(AppModel.self) private var model
    var title: LocalizedStringKey = "Set as Wallpaper"
    let action: (DisplayTarget) -> Void

    var body: some View {
        let displays = model.engine.displays
        HStack(spacing: Theme.Space.xs) {
            Button { action(.allDisplays) } label: {
                Label(title, systemImage: "play.fill")
            }
            .buttonStyle(.lumenPrimary)

            if displays.count > 1 {
                Menu {
                    Button("All Displays") { action(.allDisplays) }
                    Divider()
                    ForEach(displays) { display in
                        Button(display.name) { action(.display(display.id)) }
                    }
                } label: {
                    ChromeLabel(isIconOnly: true) { Image(systemName: "display.2") }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose display")
            }
        }
    }
}

extension AppModel {
    /// Puts a random other wallpaper on one display (or everywhere, when there's only one display).
    func surpriseMe(on display: WallpaperEngine.Display?) {
        let pool = library.all.filter { $0.id != display?.wallpaperID }
        guard let pick = pool.randomElement() else { return }
        let target: DisplayTarget = engine.displays.count > 1 ? (display.map { .display($0.id) } ?? .allDisplays) : .allDisplays
        setWallpaper(pick, on: target)
    }
}
