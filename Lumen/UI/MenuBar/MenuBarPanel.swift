import SwiftUI

/// The menu bar popover: the wallpaper itself, with just enough on top of it.
///
/// The artwork fills the whole panel; its lower half melts into the artwork's own atmosphere so the
/// caption and transport sit on calm colour instead of a separate card. Settings live in the app —
/// the panel only answers "what's playing" and offers play/pause, favourite and another pick.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusedDisplayID: String?

    private var displays: [WallpaperEngine.Display] { model.engine.displays }

    private var display: WallpaperEngine.Display? {
        displays.first { $0.id == focusedDisplayID }
            ?? displays.first { $0.wallpaperID != nil && $0.isPrimary }
            ?? displays.first { $0.wallpaperID != nil }
            ?? displays.first
    }

    private var wallpaper: Wallpaper? {
        display?.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            caption
            transport
                .padding(.top, Theme.Space.xl)
            footer
                .padding(.top, Theme.Space.xl)
        }
        .padding(Theme.Space.lg)
        .frame(width: 300, height: 540)
        .background { PanelArtwork(wallpaper: wallpaper, onOpen: openCurrent) }
        .clipped()
        // The menu bar window follows the system appearance; this panel is designed dark only,
        // and without this its text and controls render for light mode on a dark picture.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "LUMEN")
                    .font(Theme.TypeScale.eyebrow)
                    .tracking(2.4)
                    .foregroundStyle(Theme.Ink.primary)
                Text(verbatim: "v\(version)")
                    .font(Theme.TypeScale.label)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
            }
            Spacer()
            HStack(spacing: Theme.Space.xs) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.lumenIcon)
                .help("Settings")
                .accessibilityLabel(Text("Settings"))

                Button(action: quit) {
                    Image(systemName: "power")
                }
                .buttonStyle(.lumenIcon)
                .help("Quit Lumen")
                .accessibilityLabel(Text("Quit Lumen"))
            }
        }
    }

    private var caption: some View {
        VStack(spacing: Theme.Space.xs) {
            if let wallpaper {
                Eyebrow(text: WallpaperCategories.displayName(wallpaper.category), color: Theme.Ink.secondary)
                Text(wallpaper.title)
                    .font(Theme.TypeScale.compactArtworkTitle)
                    .tracking(-0.3)
                    .foregroundStyle(Theme.Ink.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                Text(detailLine(for: wallpaper))
                    .font(Theme.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            } else {
                Text("Nothing on your desktop yet")
                    .font(Theme.TypeScale.compactArtworkTitle)
                    .foregroundStyle(Theme.Ink.primary)
                    .multilineTextAlignment(.center)
                Text("Pick one from the library, or let Lumen choose for you.")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        let engine = model.engine
        let playlistActive = model.playlists.active != nil
        return HStack(spacing: Theme.Space.xxl + Theme.Space.xs) {
            Button {
                if let wallpaper { model.library.toggleFavorite(wallpaper.id) }
            } label: {
                Image(systemName: wallpaper?.isFavorite == true ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(wallpaper?.isFavorite == true ? Theme.favorite : Theme.Ink.primary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BarIconButtonStyle(size: 42))
            .disabled(wallpaper == nil)
            .help(wallpaper?.isFavorite == true ? Text("Remove from Favorites") : Text("Add to Favorites"))
            .accessibilityLabel(wallpaper?.isFavorite == true ? Text("Remove from Favorites") : Text("Add to Favorites"))

            Button {
                if engine.isAnyWallpaperSet { engine.toggleUserPause() } else { shuffle() }
            } label: {
                Image(systemName: engine.isAnyWallpaperSet ? (engine.userPaused ? "play.fill" : "pause.fill") : "shuffle")
                    .font(.system(size: 22, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PlayButtonStyle())
            .disabled(!engine.isAnyWallpaperSet && model.library.all.isEmpty)
            .help(engine.isAnyWallpaperSet ? (engine.userPaused ? Text("Resume all displays") : Text("Pause all displays")) : Text("Surprise Me"))
            .accessibilityLabel(engine.isAnyWallpaperSet ? (engine.userPaused ? Text("Resume all displays") : Text("Pause all displays")) : Text("Surprise Me"))

            Button {
                if playlistActive { model.playlists.next() } else { shuffle() }
            } label: {
                Image(systemName: playlistActive ? "forward.fill" : "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Ink.primary)
            }
            .buttonStyle(BarIconButtonStyle(size: 42))
            .disabled(!playlistActive && model.library.all.count < 2)
            .help(playlistActive ? Text("Next in Playlist") : Text("Surprise me with another wallpaper"))
            .accessibilityLabel(playlistActive ? Text("Next in Playlist") : Text("Surprise me with another wallpaper"))
        }
    }

    /// Where it's playing (and which display, when there are several) on the left; the way into the app on the right.
    private var footer: some View {
        HStack(spacing: Theme.Space.xs) {
            if let display, displays.count < 2 {
                displayChip(display)
            } else if let display {
                Menu {
                    ForEach(displays) { item in
                        Button {
                            withAnimation(reduceMotion ? nil : Theme.Motion.snappy) { focusedDisplayID = item.id }
                        } label: {
                            if item.id == display.id { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                        }
                    }
                } label: {
                    displayChip(display)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose display")
            }
            Spacer(minLength: Theme.Space.xs)
            Button(action: openMainWindow) {
                HStack(spacing: 4) {
                    Text("Open Lumen")
                    Image(systemName: "arrow.up.right").imageScale(.small)
                }
            }
            .buttonStyle(.lumenSecondary)
            .controlSize(.small)
        }
    }

    private func displayChip(_ display: WallpaperEngine.Display) -> some View {
        HStack(spacing: 6) {
            if display.wallpaperID == nil {
                Image(systemName: "circle.dashed").font(.system(size: 9, weight: .bold))
            } else if let reason = display.pauseReason {
                Image(systemName: reason.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(reason.savesEnergy ? Theme.saving : Theme.paused)
            } else {
                StatusDot(color: Theme.playing)
            }
            Text(display.name)
                .lineLimit(1)
            if displays.count > 1 {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
        .font(Theme.TypeScale.label.weight(.semibold))
        .foregroundStyle(Theme.Ink.primary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background { Color.clear.glassEffect(.regular, in: Capsule()) }
        .accessibilityElement(children: .combine)
        .help(display.pauseReason?.title ?? String(localized: "Playing"))
    }

    // MARK: Helpers

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private func detailLine(for wallpaper: Wallpaper) -> String {
        guard wallpaper.kind == .shader else { return WallpaperDescriptor.specLine(for: wallpaper) }
        return String(localized: "Rendered live · \(model.settings.shaderFrameRate) fps")
    }

    private func shuffle() {
        model.surpriseMe(on: display)
    }

    private func openMainWindow() {
        openWindow(id: SceneID.main)
        NSApp.activate()
    }

    private func openCurrent() {
        if let wallpaper {
            model.router.open(wallpaper.kind == .shader ? .studio(wallpaper.id) : .wallpaper(wallpaper.id))
        } else {
            model.router.show(.library)
        }
        openMainWindow()
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}

/// The whole-panel picture: the artwork on top, melting into its brightness-normalised atmosphere
/// below so text keeps contrast on any wallpaper. Static bitmaps only.
private struct PanelArtwork: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper?
    let onOpen: () -> Void
    @State private var atmosphere: NSImage?

    var body: some View {
        ZStack {
            Theme.Surface.canvas
            if let wallpaper {
                ThumbnailView(wallpaper: wallpaper, resolution: .poster)
            } else if let featured = model.library.builtins.first {
                ThumbnailView(wallpaper: featured, resolution: .poster).opacity(0.6)
            }
            Color.clear
                .overlay {
                    if let atmosphere {
                        Image(nsImage: atmosphere)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        Theme.Surface.canvas
                    }
                }
                .clipped()
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.28),
                            .init(color: .black.opacity(0.85), location: 0.6),
                            .init(color: .black, location: 0.78),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.45), location: 0),
                    .init(color: .clear, location: 0.2),
                    .init(color: .clear, location: 0.7),
                    .init(color: .black.opacity(0.3), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement()
        .accessibilityLabel(Text("Open Lumen"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
        .task(id: wallpaper.map { ThumbnailCache.shared.cacheKey(for: $0) }) {
            guard let source = wallpaper ?? model.library.builtins.first else {
                atmosphere = nil
                return
            }
            let loaded = await ThumbnailCache.shared.atmosphere(for: source, library: model.library)
            withAnimation(reduceMotion ? nil : Theme.Motion.backdrop) { atmosphere = loaded }
        }
    }
}

/// Large light circle for play/pause — the one bright element in the panel.
private struct PlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PlayButton(configuration: configuration)
    }

    private struct PlayButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.Ink.onLight)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.white.opacity(hovering && isEnabled ? 1 : 0.92)))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
                .animation(reduceMotion ? nil : Theme.Motion.quick, value: configuration.isPressed)
        }
    }
}
