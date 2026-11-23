import SwiftUI

/// Floating glass capsule: what's on the desktop, its state, and global transport controls.
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        HStack(spacing: Theme.Space.sm) {
            info(wallpaper: wallpaper)
            Rectangle()
                .fill(Theme.Surface.divider)
                .frame(width: 1, height: 24)
            controls(hasWallpaper: wallpaper != nil)
        }
        .padding(.leading, Theme.Space.xs)
        .padding(.trailing, Theme.Space.sm - 2)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: wallpaper?.id)
    }

    @ViewBuilder
    private func info(wallpaper: Wallpaper?) -> some View {
        Button {
            guard let wallpaper else {
                model.router.show(.library)
                return
            }
            model.router.open(wallpaper.kind == .shader ? .studio(wallpaper.id) : .wallpaper(wallpaper.id))
        } label: {
            HStack(spacing: Theme.Space.sm - 2) {
                Group {
                    if let wallpaper {
                        ThumbnailView(wallpaper: wallpaper)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.Surface.elevated)
                    }
                }
                .frame(width: 48, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(Theme.Surface.scrimStroke, lineWidth: 0.75)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(wallpaper?.title ?? String(localized: "Nothing on your desktop yet"))
                        .font(Theme.TypeScale.bodyMedium.weight(.semibold))
                        .lineLimit(1)
                    statusLine(hasWallpaper: wallpaper != nil)
                }
                .frame(minWidth: 160, idealWidth: 204, maxWidth: 230, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(wallpaper == nil ? Text("Browse your library") : Text("Open"))
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
        HStack(spacing: Theme.Space.xxs) {
            if model.playlists.active != nil {
                Button { model.playlists.previous() } label: {
                    Image(systemName: "backward.fill")
                }
                .help("Previous in Playlist")
            }

            Button { engine.toggleUserPause() } label: {
                Image(systemName: engine.userPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BarIconButtonStyle(size: 36))
            .disabled(!hasWallpaper)
            .help(engine.userPaused ? Text("Resume all displays") : Text("Pause all displays"))

            if model.playlists.active != nil {
                Button { model.playlists.next() } label: {
                    Image(systemName: "forward.fill")
                }
                .help("Next in Playlist")
            }

            Button { settings.audioEnabled.toggle() } label: {
                Image(systemName: settings.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .help(settings.audioEnabled ? Text("Mute wallpaper audio") : Text("Play wallpaper audio"))

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
                Text(verbatim: Theme.rateLabel(settings.playbackRate))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: 38)
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
