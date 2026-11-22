import SwiftUI

/// The menu bar popover: a compact "now playing" card for the desktop.
///
/// Artwork fades into a blurred echo of itself, transport controls sit in one glass
/// group, and the most-used switches live in a quick-settings card below.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
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
            VStack(alignment: .leading, spacing: 18) {
                titleBlock
                if displays.count > 1 { displayPicker }
                transport
                quickSettings
                footer
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 16)
        }
        .frame(width: 340)
        .background { MenuBackdrop(wallpaper: wallpaper) }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    // MARK: Sections

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let wallpaper {
                Text(WallpaperCategories.displayName(wallpaper.category).uppercased())
                    .font(Theme.eyebrow)
                    .tracking(1.6)
                    .foregroundStyle(Theme.accent)
                Text(wallpaper.title)
                    .font(Theme.display(22))
                    .lineLimit(2)
                Text(detailLine(for: wallpaper))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Nothing on your desktop yet")
                    .font(.system(size: 17, weight: .semibold))
                Text("Pick one from the library, or let Lumen choose for you.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayPicker: some View {
        HStack(spacing: 6) {
            ForEach(displays) { item in
                let selected = item.id == display?.id
                Button {
                    withAnimation(.snappy(duration: 0.2)) { focusedDisplayID = item.id }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.isBuiltin ? "laptopcomputer" : "display")
                        Text(item.name).lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.16) : Color.white.opacity(0.05)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var transport: some View {
        let engine = model.engine
        let playlistActive = model.playlists.active != nil
        return GlassEffectContainer(spacing: 24) {
            HStack(spacing: 26) {
                Button {
                    if let wallpaper { model.library.toggleFavorite(wallpaper.id) }
                } label: {
                    Image(systemName: wallpaper?.isFavorite == true ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(wallpaper?.isFavorite == true ? Color.pink : Color.primary)
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
            Divider().opacity(0.4).padding(.leading, 42)
            QuickToggleRow(symbol: "battery.50percent", title: "Pause on battery", isOn: $settings.pauseOnBattery)
            Divider().opacity(0.4).padding(.leading, 42)
            QuickToggleRow(symbol: "speaker.wave.2.fill", title: "Wallpaper sound", isOn: $settings.audioEnabled)
            Divider().opacity(0.4).padding(.leading, 42)
            HStack(spacing: 10) {
                QuickRowIcon(symbol: "gauge.with.dots.needle.50percent")
                Text("Playback speed").font(.system(size: 13))
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
            .padding(.vertical, 7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
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
            model.router.open(wallpaper.kind == .video ? .wallpaper(wallpaper.id) : .studio(wallpaper.id))
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
                        colors: [Theme.accent.opacity(0.55), Color(red: 0.08, green: 0.05, blue: 0.2)],
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
                            .font(Theme.eyebrow)
                            .tracking(2.4)
                        Text(verbatim: "v\(version)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
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
                    HStack(spacing: 6) {
                        DisplayStatusPill(display: display)
                        if display.wallpaperID != nil {
                            Text(display.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(height: 200)
    }
}

/// Blurred, darkened echo of the artwork filling the whole panel.
private struct MenuBackdrop: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.08)
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
            withAnimation(.easeInOut(duration: 0.5)) { image = loaded }
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
            .background(Circle().fill(Theme.accent.opacity(0.16)))
    }
}

private struct QuickToggleRow: View {
    let symbol: String
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            QuickRowIcon(symbol: symbol)
            Text(title).font(.system(size: 13))
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 7)
    }
}
