import SwiftUI

/// Grid card: thumbnail that turns into a live preview on hover.
struct WallpaperCard: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    var showsCaption = true

    @State private var hovering = false
    @State private var previewing = false
    @State private var hoverTask: Task<Void, Never>?

    private var isOnDesktop: Bool { !model.engine.displays(showing: wallpaper.id).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
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
    }

    private var artwork: some View {
        ZStack {
            ThumbnailView(wallpaper: wallpaper)
            if previewing {
                LiveWallpaperPreview(wallpaper: wallpaper)
                    .transition(.opacity)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) { badges.padding(10) }
        .overlay(alignment: .topTrailing) {
            if isOnDesktop {
                ArtBadge(text: "On desktop", symbol: "display").padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering {
                quickActions
                    .padding(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.3 : 0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.5 : 0.28), radius: hovering ? 24 : 12, y: hovering ? 14 : 6)
        .scaleEffect(hovering ? 1.018 : 1)
        .animation(.snappy(duration: 0.28), value: hovering)
        .animation(.easeOut(duration: 0.3), value: previewing)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 5) {
            switch wallpaper.kind {
            case .video:
                if let video = wallpaper.video {
                    if let label = Format.resolutionClass(video.width, video.height) { ArtBadge(text: label) }
                    if video.isHDR { ArtBadge(text: "HDR") }
                    if video.optimized != nil { ArtBadge(text: "Optimized", symbol: "bolt.fill") }
                }
            case .shader:
                ArtBadge(text: "Live", symbol: "sparkles")
            }
        }
    }

    private var quickActions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    model.library.toggleFavorite(wallpaper.id)
                } label: {
                    Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(wallpaper.isFavorite ? Color.pink : Color.primary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(wallpaper.isFavorite ? "Remove from favorites" : "Add to favorites")

                Button {
                    model.setWallpaper(wallpaper, on: .allDisplays)
                } label: {
                    Label("Set", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.glassProminent)
                .accessibilityLabel("Set as wallpaper")
            }
        }
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if wallpaper.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.pink)
            }
        }
    }

    private var subtitle: String {
        switch wallpaper.kind {
        case .video:
            guard let video = wallpaper.video else { return wallpaper.category }
            return "\(wallpaper.category) · \(Format.duration(video.duration)) · \(video.codec)"
        case .shader:
            return wallpaper.isBuiltin ? "Generative · \(wallpaper.category)" : "Your shader · \(wallpaper.category)"
        }
    }

    private func open() {
        switch wallpaper.kind {
        case .video: model.router.open(.wallpaper(wallpaper.id))
        case .shader: model.router.open(.studio(wallpaper.id))
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
        Button(wallpaper.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            model.library.toggleFavorite(wallpaper.id)
        }
        if wallpaper.kind == .video {
            Button("Show in Finder") { model.revealInFinder(wallpaper) }
        }
        if !wallpaper.isBuiltin {
            Divider()
            Button("Delete…", role: .destructive) { model.pendingDeletion = wallpaper }
        }
    }
}

/// Primary "Set as Wallpaper" control; offers per-display targets when several are connected.
struct SetWallpaperButton: View {
    @Environment(AppModel.self) private var model
    var title = "Set as Wallpaper"
    let action: (DisplayTarget) -> Void

    var body: some View {
        let displays = model.engine.displays
        if displays.count > 1 {
            Menu {
                Button("All Displays") { action(.allDisplays) }
                Divider()
                ForEach(displays) { display in
                    Button(display.name) { action(.display(display.id)) }
                }
            } label: {
                Label(title, systemImage: "play.fill")
            } primaryAction: {
                action(.allDisplays)
            }
            .menuStyle(.button)
            .buttonStyle(.glassProminent)
            .fixedSize()
        } else {
            Button { action(.allDisplays) } label: {
                Label(title, systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
        }
    }
}
