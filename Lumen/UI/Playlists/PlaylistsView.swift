import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                PageHeader(
                    eyebrow: "Playlists",
                    title: "Rotations",
                    subtitle: String(localized: "Cycle through wallpapers on a schedule, across every display.")
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 24, alignment: .top)], alignment: .leading, spacing: 30) {
                    NewPlaylistCard {
                        let playlist = model.playlists.create()
                        model.router.open(.playlist(playlist.id))
                    }
                    ForEach(model.playlists.playlists) { playlist in
                        PlaylistCard(playlist: playlist)
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: 1480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct NewPlaylistCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.07 : 0.035))
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                        .foregroundStyle(Color.white.opacity(hovering ? 0.35 : 0.18))
                    Image(systemName: "plus")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(hovering ? Theme.accent : .secondary)
                }
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Playlist").font(.system(size: 14, weight: .semibold))
                    Text("Pick wallpapers and an interval").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var hovering = false

    private var isActive: Bool { model.playlists.activeID == playlist.id }

    var body: some View {
        let wallpapers = playlist.wallpaperIDs.compactMap { model.library.wallpaper(id: $0) }
        VStack(alignment: .leading, spacing: 11) {
            collage(wallpapers)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(isActive ? Theme.accent : Color.white.opacity(hovering ? 0.28 : 0.08), lineWidth: isActive ? 2 : 1)
                )
                .overlay(alignment: .topLeading) {
                    if isActive { ArtBadge(text: String(localized: "Rotating now"), symbol: "arrow.triangle.2.circlepath").padding(10) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if hovering || isActive {
                        Button {
                            if isActive { model.playlists.stop() } else { model.playlists.play(playlist.id) }
                        } label: {
                            Group {
                                if isActive {
                                    Label("Stop", systemImage: "stop.fill")
                                } else {
                                    Label("Play", systemImage: "play.fill")
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(wallpapers.isEmpty)
                        .padding(10)
                    }
                }
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(summary(count: wallpapers.count))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.router.open(.playlist(playlist.id)) }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: hovering)
    }

    private func summary(count: Int) -> String {
        var parts = [String(localized: "\(count) wallpapers"), Format.interval(minutes: playlist.intervalMinutes)]
        if playlist.shuffle { parts.append(String(localized: "shuffled")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func collage(_ wallpapers: [Wallpaper]) -> some View {
        let tiles = Array(wallpapers.prefix(4))
        if tiles.isEmpty {
            ZStack {
                Color.white.opacity(0.04)
                Image(systemName: "rectangle.stack").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            }
        } else if tiles.count < 4 {
            ThumbnailView(wallpaper: tiles[0])
        } else {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ThumbnailView(wallpaper: tiles[0])
                    ThumbnailView(wallpaper: tiles[1])
                }
                GridRow {
                    ThumbnailView(wallpaper: tiles[2])
                    ThumbnailView(wallpaper: tiles[3])
                }
            }
        }
    }
}

struct PlaylistEditorView: View {
    @Environment(AppModel.self) private var model
    let playlistID: UUID
    @State private var draft: Playlist?

    private let intervals = [5, 15, 30, 60, 180, 360, 1440]

    var body: some View {
        Group {
            if let draft {
                editor(draft)
            } else {
                ContentUnavailableView("Playlist not found", systemImage: "questionmark.square.dashed")
            }
        }
        .onAppear { draft = model.playlists.playlist(id: playlistID) }
        .onChange(of: draft) { _, newValue in
            if let newValue { model.playlists.update(newValue) }
        }
    }

    private func editor(_ playlist: Playlist) -> some View {
        let isActive = model.playlists.activeID == playlist.id
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "PLAYLIST").font(Theme.eyebrow).tracking(1.8).foregroundStyle(Theme.accent)
                    TextField("Name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(Theme.display(40))
                }

                HStack(spacing: 14) {
                    Picker("Change wallpaper", selection: binding(\.intervalMinutes)) {
                        ForEach(intervals, id: \.self) { minutes in
                            Text(Format.interval(minutes: minutes).capitalizingFirstLetter).tag(minutes)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()

                    Toggle("Shuffle", isOn: binding(\.shuffle))
                        .toggleStyle(.switch)

                    Spacer()

                    if isActive {
                        Button { model.playlists.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                    } else {
                        Button { model.playlists.play(playlist.id) } label: { Label("Start Rotation", systemImage: "play.fill") }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .disabled(playlist.wallpaperIDs.isEmpty)
                    }
                    Button(role: .destructive) {
                        model.playlists.delete(playlist.id)
                        model.router.back()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .help("Delete playlist")
                }

                if isActive, let next = model.playlists.nextChange {
                    Label("Next change \(next.formatted(.relative(presentation: .named)))", systemImage: "timer")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                SectionTitle(
                    "Wallpapers",
                    subtitle: String(localized: "\(playlist.wallpaperIDs.count) selected · click to add or remove. Order follows selection.")
                )
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(model.library.all) { wallpaper in
                        SelectableWallpaperTile(
                            wallpaper: wallpaper,
                            position: playlist.wallpaperIDs.firstIndex(of: wallpaper.id)
                        ) {
                            toggle(wallpaper.id)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 22)
            .padding(.bottom, 32)
            .frame(maxWidth: 1480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Playlist, Value>) -> Binding<Value> {
        Binding(
            get: { draft![keyPath: keyPath] },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private func toggle(_ id: UUID) {
        guard var current = draft else { return }
        if let index = current.wallpaperIDs.firstIndex(of: id) {
            current.wallpaperIDs.remove(at: index)
        } else {
            current.wallpaperIDs.append(id)
        }
        draft = current
    }
}

struct SelectableWallpaperTile: View {
    let wallpaper: Wallpaper
    let position: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ThumbnailView(wallpaper: wallpaper)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(position != nil ? Theme.accent : Color.white.opacity(0.08), lineWidth: position != nil ? 2.5 : 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        if let position {
                            Text("\(position + 1)")
                                .font(.system(size: 12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.accent))
                                .padding(8)
                        }
                    }
                    .opacity(position == nil ? 0.75 : 1)
                Text(wallpaper.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.18), value: position)
    }
}

private extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
