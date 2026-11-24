import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: Theme.Space.xl, alignment: .top)]

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
                        .buttonStyle(.lumenPrimary)
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
                        .buttonStyle(.lumenPrimary)
                        .controlSize(.large)
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xxl) {
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
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                        .foregroundStyle(hovering ? Theme.accentInk.opacity(0.7) : Theme.Surface.strokeHover)
                    IconWell(symbol: "plus", tint: hovering ? Theme.accentInk : Theme.Ink.secondary, size: 44)
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Playlist")
                        .font(Theme.TypeScale.cardTitle)
                        .foregroundStyle(Theme.Ink.primary)
                    Text("Pick wallpapers and an interval")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.Ink.secondary)
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
                        }
                        .buttonStyle(.lumenPrimary)
                        .disabled(wallpapers.isEmpty)
                        .padding(Theme.Space.sm - 2)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
                    }
                }
                .artworkFrame(isHovering: hovering, highlight: isActive ? Theme.accentInk : nil)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                Text(summary(count: wallpapers.count))
                    .font(Theme.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
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
                    .foregroundStyle(Theme.Ink.tertiary)
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
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    Eyebrow(text: "Playlist")
                    TextField("Name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(Theme.TypeScale.pageTitle)
                        .foregroundStyle(Theme.Ink.primary)
                }

                HStack(spacing: Theme.Space.sm) {
                    Menu {
                        Picker("Change wallpaper", selection: binding(\.intervalMinutes)) {
                            ForEach(intervals, id: \.self) { minutes in
                                Text(Format.interval(minutes: minutes).capitalizingFirstLetter).tag(minutes)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        ChromeLabel {
                            HStack(spacing: 6) {
                                Image(systemName: "timer").imageScale(.small).accessibilityHidden(true)
                                Text(Format.interval(minutes: playlist.intervalMinutes).capitalizingFirstLetter)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.Ink.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.large)
                    .help("Change wallpaper")

                    Toggle("Shuffle", isOn: binding(\.shuffle))
                        .toggleStyle(.switch)
                        .foregroundStyle(Theme.Ink.primary)
                        .padding(.leading, Theme.Space.xs)

                    Spacer()

                    Group {
                        if isActive {
                            Button { model.playlists.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                                .buttonStyle(.lumenSecondary)
                        } else {
                            Button { model.playlists.play(playlist.id) } label: { Label("Start Rotation", systemImage: "play.fill") }
                                .buttonStyle(.lumenPrimary)
                                .disabled(playlist.wallpaperIDs.isEmpty)
                        }
                        Button(role: .destructive) {
                            model.playlists.delete(playlist.id)
                            model.router.back()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.lumenIcon)
                        .help("Delete playlist")
                        .accessibilityLabel(Text("Delete playlist"))
                    }
                    .controlSize(.large)
                }

                if isActive, let next = model.playlists.nextChange {
                    Label("Next change \(next.formatted(.relative(presentation: .named)))", systemImage: "timer")
                        .font(Theme.TypeScale.bodyMedium)
                        .foregroundStyle(Theme.Ink.secondary)
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
                    columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: Theme.Space.lg, alignment: .top)],
                    alignment: .leading,
                    spacing: Theme.Space.xl
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
                    .artworkFrame(radius: Theme.Radius.md, isHovering: hovering, highlight: position != nil ? Theme.accentInk : nil, lifts: false)
                    .opacity(position == nil && !hovering ? 0.62 : 1)
                Text(wallpaper.title)
                    .font(Theme.TypeScale.bodyMedium)
                    .foregroundStyle(position == nil ? Theme.Ink.secondary : Theme.Ink.primary)
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
