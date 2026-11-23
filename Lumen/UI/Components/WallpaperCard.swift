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
        VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
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
            if hovering {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
                .transition(.opacity)
            }
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
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .strokeBorder(
                    isOnDesktop
                        ? Theme.playing.opacity(hovering ? 0.55 : 0.35)
                        : (hovering ? Theme.Surface.strokeHover : Theme.Surface.stroke),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(hovering ? 0.50 : 0.28), radius: hovering ? 22 : 12, y: hovering ? 12 : 6)
        .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: hovering)
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: previewing)
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: Theme.Space.xxs) {
            switch wallpaper.kind {
            case .video:
                if let video = wallpaper.video {
                    if let label = Format.resolutionClass(video.width, video.height) { ArtBadge(text: label) }
                    if video.isHDR { ArtBadge(text: "HDR") }
                    if video.optimized != nil { ArtBadge(text: String(localized: "Optimized"), symbol: "bolt.fill") }
                }
            case .shader:
                ArtBadge(text: "Live", symbol: "sparkles")
            case .web:
                ArtBadge(text: "Web", symbol: "globe")
            case .scene:
                ArtBadge(text: String(localized: "Scene"), symbol: "square.3.layers.3d")
            }
        }
    }

    private var quickActions: some View {
        GlassEffectContainer(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                Button {
                    model.library.toggleFavorite(wallpaper.id)
                } label: {
                    Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(wallpaper.isFavorite ? Theme.favorite : Color.primary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(wallpaper.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))

                if isOnEveryDisplay {
                    Label("In Use", systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                } else {
                    Button {
                        model.setWallpaper(wallpaper, on: .allDisplays)
                    } label: {
                        Label("Set as Wallpaper", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
    }

    private var caption: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.title)
                    .font(Theme.TypeScale.cardTitle)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if wallpaper.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.favorite)
            }
        }
        .padding(.horizontal, 2)
    }

    private var subtitle: String {
        switch wallpaper.kind {
        case .video:
            let category = WallpaperCategories.displayName(wallpaper.category)
            guard let video = wallpaper.video else { return category }
            return "\(category) · \(Format.duration(video.duration)) · \(video.codec)"
        case .shader:
            let category = WallpaperCategories.displayName(wallpaper.category)
            return wallpaper.isBuiltin
                ? String(localized: "Rendered live · \(category)")
                : String(localized: "Your shader · \(category)")
        case .web:
            let category = WallpaperCategories.displayName(wallpaper.category)
            if let host = wallpaper.package?.remoteURL.flatMap({ URL(string: $0)?.host() }) { return "\(category) · \(host)" }
            return String(localized: "Web page · \(category)")
        case .scene:
            let category = WallpaperCategories.displayName(wallpaper.category)
            return String(localized: "Scene · \(category)")
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

/// Primary "Set as Wallpaper" control; offers per-display targets when several are connected.
struct SetWallpaperButton: View {
    @Environment(AppModel.self) private var model
    var title: LocalizedStringKey = "Set as Wallpaper"
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
