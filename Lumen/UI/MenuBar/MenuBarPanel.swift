import SwiftUI

/// The menu bar popover: a compact "now playing" card for the desktop.
///
/// Artwork fades into a blurred echo of itself, transport controls sit in one glass
/// group, and the most-used switches live in a quick-settings card below.
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
            MenuArtwork(wallpaper: wallpaper, display: display, onOpen: openCurrent, onQuit: quit)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                titleBlock
                if displays.count > 1 { displayPicker }
                transport
                quickSettings
                footer
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.xxs)
            .padding(.bottom, Theme.Space.md)
        }
        .frame(width: 340)
        .background { MenuBackdrop(wallpaper: wallpaper) }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: Sections

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs + 2) {
            if let wallpaper {
                Text(WallpaperCategories.displayName(wallpaper.category).uppercased())
                    .font(Theme.TypeScale.eyebrow)
                    .tracking(1.8)
                    .foregroundStyle(Theme.accent)
                Text(wallpaper.title)
                    .font(Theme.TypeScale.panelTitle)
                    .lineLimit(2)
                Text(detailLine(for: wallpaper))
                    .font(Theme.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Nothing on your desktop yet")
                    .font(Theme.TypeScale.sectionTitle)
                Text("Pick one from the library, or let Lumen choose for you.")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayPicker: some View {
        HStack(spacing: Theme.Space.xxs + 2) {
            ForEach(displays) { item in
                let selected = item.id == display?.id
                Button {
                    withAnimation(reduceMotion ? nil : Theme.Motion.snappy) { focusedDisplayID = item.id }
                } label: {
                    HStack(spacing: Theme.Space.xxs + 1) {
                        Image(systemName: item.isBuiltin ? "laptopcomputer" : "display")
                        Text(item.name).lineLimit(1)
                    }
                    .font(Theme.TypeScale.caption.weight(.medium))
                    .padding(.horizontal, Theme.Space.sm - 2)
                    .padding(.vertical, Theme.Space.xxs + 2)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .background(Capsule().fill(selected ? Theme.Surface.pressed : Theme.Surface.base))
                    .overlay(Capsule().strokeBorder(selected ? Theme.Surface.strokeHover : Theme.Surface.stroke))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var transport: some View {
        let engine = model.engine
        let playlistActive = model.playlists.active != nil
        return GlassEffectContainer(spacing: Theme.Space.xl) {
            HStack(spacing: Theme.Space.xl) {
                Button {
                    if let wallpaper { model.library.toggleFavorite(wallpaper.id) }
                } label: {
                    Image(systemName: wallpaper?.isFavorite == true ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(wallpaper?.isFavorite == true ? Theme.favorite : Color.primary)
                        .frame(width: 26, height: 26)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(wallpaper == nil)
                .help(wallpaper?.isFavorite == true ? Text("Remove from Favorites") : Text("Add to Favorites"))

                Button {
                    engine.toggleUserPause()
                } label: {
                    Image(systemName: engine.userPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .disabled(!engine.isAnyWallpaperSet)
                .help(engine.userPaused ? Text("Resume all displays") : Text("Pause all displays"))

                Button {
                    if playlistActive { model.playlists.next() } else { shuffle() }
                } label: {
                    Image(systemName: playlistActive ? "forward.fill" : "shuffle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help(playlistActive ? Text("Next in Playlist") : Text("Surprise me with another wallpaper"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var quickSettings: some View {
        @Bindable var settings = model.settings
        return VStack(spacing: 0) {
            QuickToggleRow(symbol: "macwindow", title: "Pause when covered", isOn: $settings.pauseWhenCovered)
            QuickDivider()
            QuickToggleRow(symbol: "battery.50percent", title: "Pause on battery", isOn: $settings.pauseOnBattery)
            QuickDivider()
            QuickToggleRow(symbol: "speaker.wave.2.fill", title: "Wallpaper sound", isOn: $settings.audioEnabled)
            QuickDivider()
            HStack(spacing: Theme.Space.sm - 2) {
                QuickRowIcon(symbol: "gauge.with.dots.needle.50percent")
                Text("Playback speed").font(Theme.TypeScale.bodyMedium)
                Spacer()
                Picker("Playback speed", selection: $settings.playbackRate) {
                    ForEach(Theme.playbackRates, id: \.self) { rate in
                        Text(Theme.rateLabel(rate)).tag(rate)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            .padding(.vertical, Theme.Space.xs - 1)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, Theme.Space.xxs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(Theme.Surface.recessed))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.Surface.stroke))
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.sm - 2) {
            Button(action: openMainWindow) {
                Label("Open Lumen", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            if wallpaper == nil {
                Button(action: shuffle) {
                    Label("Surprise Me", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }

    // MARK: Helpers

    private func detailLine(for wallpaper: Wallpaper) -> String {
        if let video = wallpaper.video {
            return [Format.resolution(video.width, video.height), video.codec, Format.duration(video.duration)]
                .joined(separator: " · ")
        }
        return String(localized: "Rendered live · \(model.settings.shaderFrameRate) fps")
    }

    private func shuffle() {
        let pool = model.library.all.filter { $0.id != wallpaper?.id }
        guard let pick = pool.randomElement() else { return }
        let target: DisplayTarget = displays.count > 1 ? .display(display?.id ?? "") : .allDisplays
        model.setWallpaper(pick, on: display == nil ? .allDisplays : target)
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

/// Artwork header with the app mark, header actions and the display status.
private struct MenuArtwork: View {
    let wallpaper: Wallpaper?
    let display: WallpaperEngine.Display?
    let onOpen: () -> Void
    let onQuit: () -> Void

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        ZStack {
            Group {
                if let wallpaper {
                    ThumbnailView(wallpaper: wallpaper)
                } else {
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.55), Theme.Surface.canvas],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .overlay(
                        Image(systemName: "sparkles.rectangle.stack")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.white.opacity(0.8))
                    )
                }
            }
            .frame(height: 200)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "LUMEN")
                            .font(Theme.TypeScale.eyebrow)
                            .tracking(2.4)
                        Text(verbatim: "v\(version)")
                            .font(Theme.TypeScale.micro.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    GlassEffectContainer(spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.xs) {
                            SettingsLink {
                                Image(systemName: "gearshape")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Settings")

                            Button(action: onQuit) {
                                Image(systemName: "power")
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Quit Lumen")
                        }
                    }
                }
                Spacer()
                if let display, wallpaper != nil {
                    HStack(spacing: Theme.Space.xxs + 2) {
                        DisplayStatusPill(display: display)
                        if display.wallpaperID != nil {
                            Text(display.name)
                                .font(Theme.TypeScale.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
        }
        .frame(height: 200)
    }
}

/// Blurred, darkened echo of the artwork filling the whole panel.
private struct MenuBackdrop: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let wallpaper: Wallpaper?
    @State private var image: NSImage?

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
                    }
                }
                .clipped()
            LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .task(id: wallpaper.map { ThumbnailCache.shared.cacheKey(for: $0) }) {
            guard let wallpaper else {
                image = nil
                return
            }
            let loaded = await ThumbnailCache.shared.backdrop(for: wallpaper, library: model.library)
            withAnimation(reduceMotion ? nil : Theme.Motion.backdrop) { image = loaded }
        }
    }
}

private struct QuickRowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.accentSoft))
    }
}

/// Hairline between quick-settings rows, inset past the icon well.
private struct QuickDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Surface.divider)
            .frame(height: 1)
            .padding(.leading, 28 + Theme.Space.sm - 2)
    }
}

private struct QuickToggleRow: View {
    let symbol: String
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Space.sm - 2) {
            QuickRowIcon(symbol: symbol)
            Text(title).font(Theme.TypeScale.bodyMedium)
            Spacer(minLength: Theme.Space.xs)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, Theme.Space.xs - 1)
    }
}
