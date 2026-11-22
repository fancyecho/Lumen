import SwiftUI

/// Compact control panel shown from the menu bar item.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = model.settings
        let engine = model.engine

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Lumen").font(Theme.display(16))
                Spacer()
                Text(summary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(engine.displays) { display in
                    MenuDisplayRow(display: display)
                }
            }

            HStack(spacing: 8) {
                Button {
                    engine.toggleUserPause()
                } label: {
                    Label(engine.userPaused ? "Resume" : "Pause", systemImage: engine.userPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!engine.isAnyWallpaperSet)
                if model.playlists.active != nil {
                    Button { model.playlists.next() } label: {
                        Label("Next", systemImage: "forward.fill").frame(maxWidth: .infinity)
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Pause when covered by windows", isOn: $settings.pauseWhenCovered)
                Toggle("Pause on battery", isOn: $settings.pauseOnBattery)
                Toggle("Play wallpaper audio", isOn: $settings.audioEnabled)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 13))

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                MenuRow(title: "Open Lumen", shortcut: nil) {
                    openWindow(id: SceneID.main)
                    NSApp.activate()
                }
                SettingsLink {
                    MenuRowLabel(title: "Settings…", shortcut: "⌘,")
                }
                .buttonStyle(MenuRowButtonStyle())
                MenuRow(title: "Quit Lumen", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var summary: String {
        let displays = model.engine.displays
        let playing = displays.filter(\.isPlaying).count
        if model.engine.userPaused { return "Paused" }
        if !model.engine.isAnyWallpaperSet { return "No wallpaper set" }
        return playing == 0 ? "Paused automatically" : "\(playing) playing"
    }
}

private struct MenuDisplayRow: View {
    @Environment(AppModel.self) private var model
    let display: WallpaperEngine.Display

    var body: some View {
        let wallpaper = display.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
        HStack(spacing: 10) {
            Group {
                if let wallpaper {
                    ThumbnailView(wallpaper: wallpaper)
                } else {
                    Color.white.opacity(0.06)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper?.title ?? "System wallpaper")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if wallpaper != nil {
                        if let reason = display.pauseReason {
                            Image(systemName: reason.symbol)
                                .foregroundStyle(reason.savesEnergy ? Theme.saving : Theme.paused)
                            Text(reason.title)
                        } else {
                            StatusDot(color: Theme.playing)
                            Text("Playing")
                        }
                        Text("·")
                    }
                    Text(display.name)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MenuRowLabel: View {
    let title: String
    let shortcut: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
        }
        .font(.system(size: 13))
    }
}

private struct MenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, shortcut: shortcut)
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.accentColor.opacity(0.85) : .clear)
                )
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
