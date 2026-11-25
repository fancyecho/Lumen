import SwiftUI

// MARK: - Playlists page

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: Theme.Space.xl, alignment: .top)]

    var body: some View {
        let store = model.playlists
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(
                    eyebrow: "Playlists",
                    title: "Rotations",
                    subtitle: String(localized: "Cycle through wallpapers on a schedule, across every display.")
                ) {
                    if !store.playlists.isEmpty {
                        Button(action: createPlaylist) {
                            Label("New Playlist", systemImage: "plus")
                        }
                        .buttonStyle(.lumenPrimary)
                        .controlSize(.large)
                    }
                }

                if let active = store.active {
                    RotationStage(playlist: active)
                        .padding(.top, Theme.Space.xxl)
                }

                if store.playlists.isEmpty {
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
                    .padding(.top, Theme.Space.xl)
                } else {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        // With a rotation on stage, the grid below needs its own heading.
                        if store.active != nil {
                            SectionTitle("All Playlists", subtitle: String(localized: "\(store.playlists.count) playlists"))
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xxl) {
                            ForEach(store.playlists) { playlist in
                                PlaylistCard(playlist: playlist)
                            }
                            NewPlaylistCard(action: createPlaylist)
                        }
                    }
                    .padding(.top, store.active == nil ? Theme.Space.lg : Theme.Space.section)
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

enum PlaylistText {
    /// "3 wallpapers · every 30 min · shuffled"
    static func summary(_ playlist: Playlist, count: Int) -> String {
        var parts = [String(localized: "\(count) wallpapers"), Format.interval(minutes: playlist.intervalMinutes)]
        if playlist.shuffle { parts.append(String(localized: "shuffled")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Deck artwork

private enum DeckMetrics {
    /// Room above the front card for the two cards peeking out behind it. Every deck reserves it,
    /// filled or not, so front cards in a grid row share one top edge.
    static let headroom: CGFloat = 20
    static let aspectRatio: CGFloat = 16.0 / 10.0
}

/// A playlist's cover: its first wallpapers stacked like a small deck of prints, so a playlist reads
/// as a collection at a glance instead of as one more wallpaper card. The cards behind fan out a
/// little on hover.
struct PlaylistDeck<Overlay: View>: View {
    let wallpapers: [Wallpaper]
    var isHovering = false
    var radius: CGFloat = Theme.Radius.lg
    @ViewBuilder var overlay: Overlay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let spread: CGFloat = isHovering && !reduceMotion ? 10 : 8
        ZStack(alignment: .top) {
            ForEach([2, 1], id: \.self) { depth in
                plate(depth: depth, shape: shape)
                    .scaleEffect(1 - 0.06 * CGFloat(depth), anchor: .top)
                    .offset(y: -spread * CGFloat(depth))
            }
            front(shape: shape)
        }
        .padding(.top, DeckMetrics.headroom)
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: isHovering)
    }

    private func plate(depth: Int, shape: RoundedRectangle) -> some View {
        Group {
            if wallpapers.indices.contains(depth) {
                ThumbnailView(wallpaper: wallpapers[depth])
                    .overlay(Color.black.opacity(depth == 1 ? 0.18 : 0.36))
            } else {
                // Fewer than three wallpapers: blank prints keep the deck's silhouette.
                Theme.Surface.elevated
            }
        }
        .aspectRatio(DeckMetrics.aspectRatio, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.Surface.artworkEdge, lineWidth: 1))
    }

    private func front(shape: RoundedRectangle) -> some View {
        ZStack {
            if let first = wallpapers.first {
                ThumbnailView(wallpaper: first)
            } else {
                Theme.Surface.mediaFill
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.Ink.tertiary)
            }
        }
        .aspectRatio(DeckMetrics.aspectRatio, contentMode: .fit)
        .overlay { overlay }
        .background(Theme.Surface.canvas)
        .artworkFrame(radius: radius, isHovering: isHovering, lifts: false)
    }
}

extension PlaylistDeck where Overlay == EmptyView {
    init(wallpapers: [Wallpaper], isHovering: Bool = false, radius: CGFloat = Theme.Radius.lg) {
        self.init(wallpapers: wallpapers, isHovering: isHovering, radius: radius) { EmptyView() }
    }
}

// MARK: - Cards

struct PlaylistCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playlist: Playlist
    @State private var hovering = false

    private var isActive: Bool { model.playlists.activeID == playlist.id }

    var body: some View {
        let wallpapers = playlist.wallpaperIDs.compactMap { model.library.wallpaper(id: $0) }
        VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
            PlaylistDeck(wallpapers: wallpapers, isHovering: hovering) {
                ZStack {
                    if hovering {
                        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom)
                            .transition(.opacity)
                    }
                    if isActive {
                        ArtBadge(text: String(localized: "Rotating now"), dotColor: Theme.playing)
                            .padding(Theme.Space.sm - 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if hovering {
                        playButton(isEmpty: wallpapers.isEmpty)
                            .padding(Theme.Space.sm - 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                Text(PlaylistText.summary(playlist, count: wallpapers.count))
                    .font(Theme.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: hovering)
        .contextMenu {
            if isActive {
                Button("Stop") { model.playlists.stop() }
            } else {
                Button("Start Rotation") { model.playlists.play(playlist.id) }
                    .disabled(wallpapers.isEmpty)
            }
            Button("Edit Playlist", action: open)
            Divider()
            Button("Delete playlist", role: .destructive) { model.playlists.delete(playlist.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func playButton(isEmpty: Bool) -> some View {
        Button {
            if isActive { model.playlists.stop() } else { model.playlists.play(playlist.id) }
        } label: {
            if isActive {
                Label("Stop", systemImage: "stop.fill")
            } else {
                Label("Play", systemImage: "play.fill")
            }
        }
        .buttonStyle(.lumenPrimary)
        .disabled(isEmpty)
    }

    private func open() {
        model.router.open(.playlist(playlist.id))
    }
}

/// The last tile in the grid: an outline the size of a deck's front card, like Wallper's quiet "+".
struct NewPlaylistCard: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .fill(hovering ? Theme.Surface.base : Color.clear)
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        .foregroundStyle(hovering ? Theme.Ink.tertiary : Theme.Surface.strokeHover)
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(hovering ? Theme.Ink.primary : Theme.Ink.tertiary)
                }
                .aspectRatio(DeckMetrics.aspectRatio, contentMode: .fit)
                .padding(.top, DeckMetrics.headroom)
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

// MARK: - Now rotating

/// The active rotation, staged like Home: what's on the desktop now, when it changes, and what's next.
private struct RotationStage: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var hovering = false

    var body: some View {
        let current = model.playlists.currentID.flatMap { model.library.wallpaper(id: $0) }
        HStack(alignment: .bottom, spacing: Theme.Space.xxl + Theme.Space.xs) {
            artwork(current)
                .frame(minWidth: 400, maxWidth: 600)
                .layoutPriority(1)
            // Runs to the page's right edge (up to a comfortable measure), so "Edit Playlist" lines up
            // under the header's "New Playlist".
            caption
                .frame(minWidth: 320, maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func artwork(_ current: Wallpaper?) -> some View {
        ZStack {
            if let current {
                ThumbnailView(wallpaper: current)
            } else {
                Theme.Surface.mediaFill
            }
        }
        .aspectRatio(DeckMetrics.aspectRatio, contentMode: .fit)
        .overlay {
            LinearGradient(
                stops: [.init(color: .clear, location: 0.55), .init(color: .black.opacity(0.6), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            ArtBadge(text: String(localized: "Rotating now"), dotColor: Theme.playing)
                .padding(Theme.Space.md)
        }
        .overlay(alignment: .bottomLeading) {
            if let current {
                VStack(alignment: .leading, spacing: 3) {
                    Text(current.title)
                        .font(Theme.TypeScale.cardTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(WallpaperDescriptor.subtitle(for: current))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .padding(Theme.Space.lg)
            }
        }
        .artworkFrame(radius: Theme.Radius.xxl, isHovering: hovering, lifts: false)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard let current else { return }
            model.router.open(current.kind == .shader ? .studio(current.id) : .wallpaper(current.id))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var caption: some View {
        let store = model.playlists
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            Eyebrow(text: "Now Rotating")
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(playlist.name)
                    .font(Theme.TypeScale.artworkTitle)
                    .tracking(-0.4)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PlaylistText.summary(playlist, count: store.order.count))
                    .font(Theme.TypeScale.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }
            NextChangeMeter(nextChange: store.nextChange, intervalMinutes: playlist.intervalMinutes)
            transport
            if store.order.count > 1 {
                HairlineDivider().padding(.vertical, Theme.Space.xxs)
                upNext
            }
        }
    }

    private var transport: some View {
        let store = model.playlists
        let canStep = store.order.count > 1
        return HStack(spacing: Theme.Space.xs) {
            Button { store.previous() } label: {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.lumenIcon)
            .disabled(!canStep)
            .help("Previous in Playlist")
            .accessibilityLabel(Text("Previous in Playlist"))
            Button { store.next() } label: {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.lumenIcon)
            .disabled(!canStep)
            .help("Next in Playlist")
            .accessibilityLabel(Text("Next in Playlist"))
            Button { store.stop() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.lumenSecondary)
            Spacer(minLength: Theme.Space.xs)
            Button { model.router.open(.playlist(playlist.id)) } label: {
                Label("Edit Playlist", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.lumenSecondary)
        }
        .controlSize(.large)
    }

    private var upNext: some View {
        let store = model.playlists
        let order = store.order
        let upcoming = (1..<min(order.count, 5)).compactMap { offset in
            model.library.wallpaper(id: order[(store.position + offset) % order.count])
        }
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Eyebrow(text: "Up Next", color: Theme.Ink.tertiary)
            // Four fixed slots, so tiles keep one size however short the playlist is.
            HStack(spacing: Theme.Space.xs) {
                ForEach(0..<4, id: \.self) { slot in
                    if upcoming.indices.contains(slot) {
                        UpNextTile(wallpaper: upcoming[slot]) { store.show(upcoming[slot].id) }
                    } else {
                        Color.clear
                            .aspectRatio(DeckMetrics.aspectRatio, contentMode: .fit)
                            .frame(maxWidth: UpNextTile.maxWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct UpNextTile: View {
    static let maxWidth: CGFloat = 132
    let wallpaper: Wallpaper
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ThumbnailView(wallpaper: wallpaper)
                .aspectRatio(DeckMetrics.aspectRatio, contentMode: .fit)
                .artworkFrame(radius: Theme.Radius.sm, isHovering: hovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Self.maxWidth)
        .onHover { hovering = $0 }
        .help(Text(verbatim: wallpaper.title))
        .accessibilityLabel(Text("Show Now"))
        .accessibilityValue(Text(verbatim: wallpaper.title))
    }
}

/// A thin bar filling up towards the next change, with the time left beneath it.
private struct NextChangeMeter: View {
    let nextChange: Date?
    let intervalMinutes: Int

    var body: some View {
        if let nextChange {
            // A quarter-minute tick is plenty for a bar measured in minutes, and it only runs while
            // the page is on screen.
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let total = Double(max(intervalMinutes, 1) * 60)
                let remaining = max(0, nextChange.timeIntervalSince(context.date))
                let fraction = min(1, max(0, 1 - remaining / total))
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Capsule()
                        .fill(Theme.Surface.elevated)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Color.white.opacity(0.82))
                                    .frame(width: max(4, proxy.size.width * fraction))
                            }
                        }
                    Text("Next change \(nextChange.formatted(.relative(presentation: .named)))")
                        .font(Theme.TypeScale.label)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                .animation(.linear(duration: 0.6), value: fraction)
            }
        } else {
            Text("Only one wallpaper, so there's nothing to rotate yet.")
                .font(Theme.TypeScale.label)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }
}

// MARK: - Editor

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
        .onChange(of: draft) { oldValue, newValue in
            // Loading the draft isn't an edit: saving it would restart a running rotation's timer
            // every time the editor opened.
            guard oldValue != nil, let newValue, newValue != oldValue else { return }
            model.playlists.update(newValue)
        }
    }

    private func editor(_ playlist: Playlist) -> some View {
        let isActive = model.playlists.activeID == playlist.id
        let wallpapers = playlist.wallpaperIDs.compactMap { model.library.wallpaper(id: $0) }
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                header(playlist, wallpapers: wallpapers, isActive: isActive)
                queue(wallpapers, isActive: isActive)
                library(playlist)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl + Theme.Space.xs)
            .frame(maxWidth: Theme.Layout.galleryMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Header

    /// Album-style header: the deck on the left, name, summary and controls beside it.
    private func header(_ playlist: Playlist, wallpapers: [Wallpaper], isActive: Bool) -> some View {
        HStack(alignment: .bottom, spacing: Theme.Space.xxl) {
            PlaylistDeck(wallpapers: wallpapers, radius: Theme.Radius.xl)
                .frame(width: 300)
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                    Eyebrow(text: isActive ? "Now Rotating" : "Playlist")
                    TextField("Name", text: binding(\.name))
                        .textFieldStyle(.plain)
                        .font(Theme.TypeScale.pageTitle)
                        .foregroundStyle(Theme.Ink.primary)
                    Text(PlaylistText.summary(playlist, count: wallpapers.count))
                        .font(Theme.TypeScale.body)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ink.secondary)
                }
                controls(playlist, isActive: isActive)
                if isActive {
                    NextChangeMeter(nextChange: model.playlists.nextChange, intervalMinutes: playlist.intervalMinutes)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func controls(_ playlist: Playlist, isActive: Bool) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if isActive {
                Button { model.playlists.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.lumenSecondary)
            } else {
                Button { model.playlists.play(playlist.id) } label: { Label("Start Rotation", systemImage: "play.fill") }
                    .buttonStyle(.lumenPrimary)
                    .disabled(playlist.wallpaperIDs.isEmpty)
            }

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
            .help("Change wallpaper")

            Toggle("Shuffle", isOn: binding(\.shuffle))
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Theme.TypeScale.bodyMedium)
                .foregroundStyle(Theme.Ink.primary)
                .fixedSize()
                .padding(.leading, Theme.Space.xxs)

            Spacer(minLength: Theme.Space.sm)

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

    // MARK: Queue

    private func queue(_ wallpapers: [Wallpaper], isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle(
                "In This Rotation",
                subtitle: wallpapers.isEmpty ? nil : String(localized: "Drag to reorder. With Shuffle on, the order is mixed each time the rotation starts.")
            )
            if wallpapers.isEmpty {
                Text("No wallpapers yet. Pick some from your library below.")
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.Ink.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                            .foregroundStyle(Theme.Surface.strokeHover)
                    )
            } else {
                VStack(spacing: 2) {
                    QueueColumns.header
                    ForEach(Array(wallpapers.enumerated()), id: \.element.id) { index, wallpaper in
                        PlaylistQueueRow(
                            index: index,
                            wallpaper: wallpaper,
                            isCurrent: isActive && model.playlists.currentID == wallpaper.id,
                            isFirst: index == 0,
                            isLast: index == wallpapers.count - 1,
                            canShowNow: isActive,
                            move: { offset in move(wallpaper.id, by: offset) },
                            moveHere: { dragged in move(dragged, to: wallpaper.id) },
                            remove: { toggle(wallpaper.id) }
                        )
                    }
                }
            }
        }
    }

    // MARK: Library

    private func library(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle("Add from Library", subtitle: String(localized: "Click a wallpaper to add it, and click again to take it out."))
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: Theme.Space.lg, alignment: .top)],
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
    }

    // MARK: Editing

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

    private func move(_ id: UUID, by offset: Int) {
        guard var current = draft, let from = current.wallpaperIDs.firstIndex(of: id) else { return }
        let to = from + offset
        guard current.wallpaperIDs.indices.contains(to) else { return }
        current.wallpaperIDs.swapAt(from, to)
        draft = current
    }

    /// Drops `id` into `target`'s place: below it when dragged downwards, above it when dragged up.
    private func move(_ id: UUID, to target: UUID) {
        guard var current = draft,
              let from = current.wallpaperIDs.firstIndex(of: id),
              let to = current.wallpaperIDs.firstIndex(of: target),
              from != to
        else { return }
        current.wallpaperIDs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        draft = current
    }
}

/// Fixed column widths shared by the queue's header and rows, so every column lines up.
private enum QueueColumns {
    static let index: CGFloat = 26
    static let thumbnail: CGFloat = 72
    static let resolution: CGFloat = 120
    static let length: CGFloat = 64
    static let actions: CGFloat = 64
    static let spacing: CGFloat = 14
    static let inset: CGFloat = 10

    static var header: some View {
        HStack(spacing: spacing) {
            label("#").frame(width: index, alignment: .trailing)
            label(String(localized: "Title"))
                .padding(.leading, thumbnail + spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            label(String(localized: "Resolution")).frame(width: resolution, alignment: .leading)
            label(String(localized: "Length")).frame(width: length, alignment: .trailing)
            Color.clear.frame(width: actions, height: 1)
        }
        .padding(.horizontal, inset)
        .padding(.bottom, Theme.Space.xxs)
    }

    private static func label(_ text: String) -> some View {
        Eyebrow(text: text, color: Theme.Ink.tertiary, isCompact: true)
    }
}

/// One wallpaper in the playlist's order, laid out like a track list: number, artwork, title, facts.
private struct PlaylistQueueRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let wallpaper: Wallpaper
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    let canShowNow: Bool
    let move: (Int) -> Void
    let moveHere: (UUID) -> Void
    let remove: () -> Void
    @State private var hovering = false
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: QueueColumns.spacing) {
            Group {
                if isCurrent {
                    StatusDot(color: Theme.playing)
                } else {
                    Text(verbatim: "\(index + 1)")
                        .font(Theme.TypeScale.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
            .frame(width: QueueColumns.index, alignment: .trailing)

            ThumbnailView(wallpaper: wallpaper)
                .frame(width: QueueColumns.thumbnail, height: QueueColumns.thumbnail / DeckMetrics.aspectRatio)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs + 2, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.xs + 2, style: .continuous)
                        .strokeBorder(Theme.Surface.artworkEdge, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.title)
                    .font(Theme.TypeScale.bodyMedium.weight(.semibold))
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                Text(WallpaperDescriptor.subtitle(for: wallpaper))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(WallpaperDescriptor.resolution(for: wallpaper) ?? "—")
                .font(Theme.TypeScale.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: QueueColumns.resolution, alignment: .leading)
            Text(WallpaperDescriptor.length(for: wallpaper) ?? "—")
                .font(Theme.TypeScale.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.secondary)
                .frame(width: QueueColumns.length, alignment: .trailing)

            HStack(spacing: Theme.Space.xxs) {
                Button(action: remove) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.lumenIcon)
                .controlSize(.small)
                .opacity(hovering ? 1 : 0)
                .help("Remove from Playlist")
                .accessibilityLabel(Text("Remove from Playlist"))
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hovering ? Theme.Ink.secondary : Theme.Ink.quaternary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }
            .frame(width: QueueColumns.actions, alignment: .trailing)
        }
        .padding(.horizontal, QueueColumns.inset)
        .padding(.vertical, Theme.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(isDropTarget ? Theme.Surface.hover : (hovering || isCurrent ? Theme.Surface.base : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .strokeBorder(isDropTarget ? Theme.Surface.strokeHover : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .draggable(wallpaper.id.uuidString) {
            ThumbnailView(wallpaper: wallpaper)
                .frame(width: 120, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != wallpaper.id else { return false }
            moveHere(id)
            return true
        } isTargeted: { isDropTarget = $0 }
        .contextMenu {
            if canShowNow, !isCurrent {
                Button("Show Now") { model.playlists.show(wallpaper.id) }
                Divider()
            }
            Button("Move Up") { move(-1) }.disabled(isFirst)
            Button("Move Down") { move(1) }.disabled(isLast)
            Divider()
            Button("Remove from Playlist", role: .destructive, action: remove)
        }
        .animation(Theme.Motion.quick, value: hovering)
        .animation(Theme.Motion.quick, value: isDropTarget)
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
                                .foregroundStyle(Theme.Ink.onLight)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.92)))
                                .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                                .padding(Theme.Space.xs)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .artworkFrame(
                        radius: Theme.Radius.md,
                        isHovering: hovering,
                        highlight: position != nil ? Color.white.opacity(0.75) : nil,
                        lifts: false
                    )
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
        .accessibilityAddTraits(position != nil ? .isSelected : [])
    }
}

private extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
