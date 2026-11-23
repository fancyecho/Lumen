import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 264, maximum: 420), spacing: Theme.Space.lg, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(
                    eyebrow: "Playlists",
                    title: "Rotations",
                    subtitle: String(localized: "Cycle through wallpapers on a schedule, across every display.")
                ) {
                    if !model.playlists.playlists.isEmpty {
                        Button(action: createPlaylist) {
                            Label("New Playlist", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                }

                if model.playlists.playlists.isEmpty {
                    EmptyStatePanel(
                        symbol: "arrow.triangle.2.circlepath",
                        title: String(localized: "No rotations yet"),
                        message: String(localized: "Pick a few wallpapers and an interval. Lumen swaps them on every display and keeps pausing when nobody can see the desktop.")
                    ) {
                        Button(action: createPlaylist) {
                            Label("New Playlist", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xl + Theme.Space.xxs) {
                        ForEach(model.playlists.playlists) { playlist in
                            PlaylistCard(playlist: playlist)
                        }
                        NewPlaylistCard(action: createPlaylist)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl + Theme.Space.xs)
            .frame(maxWidth: Theme.Layout.galleryMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func createPlaylist() {
        let playlist = model.playlists.create()
        model.router.open(.playlist(playlist.id))
    }
}

/// Dashed placeholder at the end of the grid, sized like a playlist card.
struct NewPlaylistCard: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(hovering ? Theme.Surface.elevated : Theme.Surface.base)
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 7]))
                        .foregroundStyle(hovering ? Theme.accent.opacity(0.6) : Theme.Surface.strokeHover)
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.accent : .secondary)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(hovering ? Theme.accentSoft : Theme.Surface.elevated))
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                VStack(alignment: .leading, spacing: Theme.Space.xxs - 1) {
                    Text("New Playlist").font(Theme.TypeScale.cardTitle)
                    Text("Pick wallpapers and an interval")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
    }
}

struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playlist: Playlist
    @State private var hovering = false

    private var isActive: Bool { model.playlists.activeID == playlist.id }

    var body: some View {
        let wallpapers = playlist.wallpaperIDs.compactMap { model.library.wallpaper(id: $0) }
        VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
            collage(wallpapers)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if hovering {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(
                            isActive ? Theme.accent : (hovering ? Theme.Surface.strokeHover : Theme.Surface.stroke),
                            lineWidth: isActive ? 2 : 1
                        )
                )
                .overlay(alignment: .topLeading) {
                    if isActive {
                        ArtBadge(text: String(localized: "Rotating now"), symbol: "arrow.triangle.2.circlepath")
                            .padding(Theme.Space.sm - 2)
                    }
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
                            .font(Theme.TypeScale.bodyMedium)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(wallpapers.isEmpty)
                        .padding(Theme.Space.sm - 2)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.50 : 0.28), radius: hovering ? 22 : 12, y: hovering ? 12 : 6)
                .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)

            VStack(alignment: .leading, spacing: Theme.Space.xxs - 1) {
                Text(playlist.name).font(Theme.TypeScale.cardTitle).lineLimit(1)
                Text(summary(count: wallpapers.count))
                    .font(Theme.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.router.open(.playlist(playlist.id)) }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.router.open(.playlist(playlist.id)) }
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
                Theme.Surface.mediaFill
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
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
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(verbatim: "PLAYLIST")
                        .font(Theme.TypeScale.eyebrow)
                        .tracking(1.8)
                        .foregroundStyle(Theme.accent)
                    TextField("Name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(Theme.TypeScale.pageTitle)
                }

                HStack(spacing: Theme.Space.sm) {
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
                        .font(Theme.TypeScale.bodyMedium)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Space.sm)
                        .padding(.vertical, Theme.Space.xs)
                        .background(Capsule().fill(Theme.Surface.elevated))
                        .overlay(Capsule().strokeBorder(Theme.Surface.stroke))
                }

                SectionTitle(
                    "Wallpapers",
                    subtitle: String(localized: "\(playlist.wallpaperIDs.count) selected · click to add or remove. Order follows selection.")
                )
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: Theme.Space.md, alignment: .top)],
                    alignment: .leading,
                    spacing: Theme.Space.lg
                ) {
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
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl + Theme.Space.xs)
            .frame(maxWidth: Theme.Layout.galleryMaxWidth, alignment: .leading)
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
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ThumbnailView(wallpaper: wallpaper)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .strokeBorder(
                                position != nil ? Theme.accent : (hovering ? Theme.Surface.strokeHover : Theme.Surface.stroke),
                                lineWidth: position != nil ? 2 : 1
                            )
                    )
                    .overlay(alignment: .topTrailing) {
                        if let position {
                            Text(verbatim: "\(position + 1)")
                                .font(Theme.TypeScale.micro)
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.accent))
                                .padding(Theme.Space.xs)
                        }
                    }
                    .opacity(position == nil && !hovering ? 0.72 : 1)
                Text(wallpaper.title)
                    .font(Theme.TypeScale.bodyMedium)
                    .foregroundStyle(position == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: position)
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
    }
}

private extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
