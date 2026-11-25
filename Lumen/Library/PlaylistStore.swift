import Foundation
import Observation

/// Playlists rotate wallpapers across all displays on a timer.
@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []
    private(set) var activeID: UUID?
    private(set) var nextChange: Date?

    @ObservationIgnored var applyHandler: ((Wallpaper) -> Void)?
    /// The active rotation's running order (shuffled once per start when shuffle is on) and the
    /// index showing now. Observed, so the Playlists page can show what's up next.
    private(set) var order: [UUID] = []
    private(set) var position = 0

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var timer: Timer?
    private static let activeKey = "activePlaylist"

    init(library: LibraryStore) {
        self.library = library
    }

    var active: Playlist? { playlists.first { $0.id == activeID } }

    /// The wallpaper the active rotation is showing.
    var currentID: UUID? { order.indices.contains(position) ? order[position] : nil }

    func playlist(id: UUID) -> Playlist? { playlists.first { $0.id == id } }

    func start() {
        if let data = try? Data(contentsOf: AppPaths.playlistsFile),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
        // Resume the rotation timer; the engine already restored the current wallpaper.
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey),
           let id = UUID(uuidString: raw), playlist(id: id) != nil {
            activeID = id
            buildOrder()
            schedule()
        }
    }

    // MARK: Editing

    func create() -> Playlist {
        let playlist = Playlist(name: String(localized: "Playlist \(playlists.count + 1)"))
        playlists.insert(playlist, at: 0)
        save()
        return playlist
    }

    func update(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index] = playlist
        save()
        if playlist.id == activeID {
            buildOrder()
            schedule()
        }
    }

    func delete(_ id: UUID) {
        if id == activeID { stop() }
        playlists.removeAll { $0.id == id }
        save()
    }

    func removeWallpaper(_ wallpaperID: UUID) {
        for index in playlists.indices {
            playlists[index].wallpaperIDs.removeAll { $0 == wallpaperID }
        }
        save()
        if activeID != nil { buildOrder() }
    }

    // MARK: Playback

    func play(_ id: UUID) {
        guard playlist(id: id) != nil else { return }
        activeID = id
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
        buildOrder()
        position = 0
        applyCurrent()
        schedule()
    }

    func stop() {
        guard activeID != nil else { return }
        activeID = nil
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
        timer?.invalidate()
        timer = nil
        nextChange = nil
    }

    func next() { step(by: 1) }
    func previous() { step(by: -1) }

    /// Jumps the active rotation to one of its wallpapers; the interval starts over from there.
    func show(_ wallpaperID: UUID) {
        guard let index = order.firstIndex(of: wallpaperID) else { return }
        position = index
        applyCurrent()
        schedule()
    }

    private func step(by delta: Int) {
        guard !order.isEmpty else { return }
        position = (position + delta + order.count) % order.count
        applyCurrent()
        schedule()
    }

    private func buildOrder() {
        guard let playlist = active else {
            order = []
            return
        }
        let valid = playlist.wallpaperIDs.filter { library.wallpaper(id: $0) != nil }
        let showing = currentID
        order = playlist.shuffle ? valid.shuffled() : valid
        // Follow the wallpaper on screen, not the index: after a reorder the old index points at
        // a different wallpaper than the one the desktop is showing.
        if let showing, let index = order.firstIndex(of: showing) {
            position = index
        } else {
            position = min(position, max(order.count - 1, 0))
        }
    }

    private func applyCurrent() {
        guard order.indices.contains(position), let wallpaper = library.wallpaper(id: order[position]) else { return }
        applyHandler?(wallpaper)
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let playlist = active, order.count > 1 else {
            nextChange = nil
            return
        }
        let interval = TimeInterval(playlist.intervalMinutes * 60)
        nextChange = Date().addingTimeInterval(interval)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        timer.tolerance = min(30, interval * 0.05)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: AppPaths.playlistsFile, options: .atomic)
    }
}
