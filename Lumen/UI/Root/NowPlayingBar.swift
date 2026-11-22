import SwiftUI

/// Floating glass capsule: what's on the desktop, its state, and global transport controls.
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    @State private var focusedDisplayID: String?

    private var display: WallpaperEngine.Display? {
        let displays = model.engine.displays
        return displays.first { $0.id == focusedDisplayID }
            ?? displays.first { $0.wallpaperID != nil && $0.isPrimary }
            ?? displays.first { $0.wallpaperID != nil }
            ?? displays.first
    }

    var body: some View {
        let wallpaper = display?.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
        HStack(spacing: 12) {
            info(wallpaper: wallpaper)
            Rectangle()
                .fill(.white.opacity(0.14))
                .frame(width: 1, height: 26)
            controls(hasWallpaper: wallpaper != nil)
        }
        .padding(.leading, 7)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy(duration: 0.25), value: wallpaper?.id)
    }

    @ViewBuilder
    private func info(wallpaper: Wallpaper?) -> some View {
        Button {
            guard let wallpaper else {
                model.router.show(.library)
                return
            }
            model.router.open(wallpaper.kind == .video ? .wallpaper(wallpaper.id) : .studio(wallpaper.id))
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let wallpaper {
                        ThumbnailView(wallpaper: wallpaper)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.white.opacity(0.08))
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(wallpaper?.title ?? "Nothing on your desktop yet")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    statusLine(hasWallpaper: wallpaper != nil)
                }
                .frame(width: 210, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(wallpaper == nil ? "Browse your library" : "Open")
    }

    @ViewBuilder
    private func statusLine(hasWallpaper: Bool) -> some View {
        let displays = model.engine.displays
        HStack(spacing: 5) {
            if let display, hasWallpaper {
                if let reason = display.pauseReason {
                    Image(systemName: reason.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(reason.savesEnergy ? Theme.saving : Theme.paused)
                    Text(reason.title)
                } else {
                    StatusDot(color: Theme.playing)
                    Text(display.name)
                }
            } else {
                Text("Pick something from your library")
            }
            if displays.count > 1 {
                Menu {
                    ForEach(displays) { item in
                        Button(item.name) { focusedDisplayID = item.id }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose display")
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func controls(hasWallpaper: Bool) -> some View {
        let engine = model.engine
        let settings = model.settings
        HStack(spacing: 4) {
            if model.playlists.active != nil {
                Button { model.playlists.previous() } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous in playlist")
            }

            Button { engine.toggleUserPause() } label: {
                Image(systemName: engine.userPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BarIconButtonStyle(size: 38))
            .disabled(!hasWallpaper)
            .help(engine.userPaused ? "Resume all displays" : "Pause all displays")

            if model.playlists.active != nil {
                Button { model.playlists.next() } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next in playlist")
            }

            Button { settings.audioEnabled.toggle() } label: {
                Image(systemName: settings.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(settings.audioEnabled ? "Mute wallpaper audio" : "Play wallpaper audio")

            Menu {
                Picker("Speed", selection: Binding(
                    get: { settings.playbackRate },
                    set: { settings.playbackRate = $0 }
                )) {
                    ForEach(Theme.playbackRates, id: \.self) { rate in
                        Text(Theme.rateLabel(rate)).tag(rate)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(Theme.rateLabel(settings.playbackRate))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 40)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Video playback speed")
        }
        .buttonStyle(BarIconButtonStyle())
        .font(.system(size: 13, weight: .semibold))
    }
}
