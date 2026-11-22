import AppKit
import Foundation
import Observation

struct ImportJob: Identifiable, Equatable {
    let id: UUID
    let name: String
}

struct ImportResult {
    var added: [Wallpaper] = []
    var failures: [(name: String, reason: String)] = []
}

/// The user's wallpapers on disk, plus the built-in generative presets.
@MainActor
@Observable
final class LibraryStore {
    private(set) var items: [Wallpaper] = []
    private(set) var favoriteBuiltins: Set<UUID> = []
    private(set) var importJobs: [ImportJob] = []
    private(set) var optimizing: [UUID: Double] = [:]
    private(set) var revision = 0

    private static let favoritesKey = "favoriteBuiltinWallpapers"

    // MARK: Lookup

    var builtins: [Wallpaper] {
        BuiltinShaders.wallpapers.map { wallpaper in
            var copy = wallpaper
            copy.isFavorite = favoriteBuiltins.contains(wallpaper.id)
            return copy
        }
    }

    var all: [Wallpaper] { items + builtins }
    var videos: [Wallpaper] { items.filter { $0.kind == .video } }
    var customShaders: [Wallpaper] { items.filter { $0.kind == .shader } }
    var totalDiskUsage: Int64 {
        items.compactMap(\.video).reduce(0) { $0 + $1.fileSize + ($1.optimized?.fileSize ?? 0) }
    }

    func wallpaper(id: UUID) -> Wallpaper? {
        if let item = items.first(where: { $0.id == id }) { return item }
        guard var builtin = BuiltinShaders.preset(id: id)?.wallpaper else { return nil }
        builtin.isFavorite = favoriteBuiltins.contains(id)
        return builtin
    }

    /// The file the engine should decode: the optimised variant when one exists.
    func playbackURL(for wallpaper: Wallpaper) -> URL? {
        guard let video = wallpaper.video else { return nil }
        let folder = AppPaths.folder(for: wallpaper.id)
        if let optimized = video.optimized {
            let url = folder.appending(path: optimized.fileName)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return folder.appending(path: video.fileName)
    }

    func sourceURL(for wallpaper: Wallpaper) -> URL? {
        guard let video = wallpaper.video else { return nil }
        return AppPaths.folder(for: wallpaper.id).appending(path: video.fileName)
    }

    func thumbnailURL(for wallpaper: Wallpaper) -> URL? {
        guard wallpaper.kind == .video else { return nil }
        return AppPaths.folder(for: wallpaper.id).appending(path: "thumb.jpg")
    }

    // MARK: Persistence

    func load() {
        favoriteBuiltins = Set((UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []).compactMap(UUID.init(uuidString:)))
        guard let data = try? Data(contentsOf: AppPaths.libraryFile) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([Wallpaper].self, from: data)
        } catch {
            Log.library.error("Library file unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        revision += 1
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: AppPaths.libraryFile, options: .atomic)
        } catch {
            Log.library.error("Saving library failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Editing

    func update(_ wallpaper: Wallpaper) {
        guard let index = items.firstIndex(where: { $0.id == wallpaper.id }) else { return }
        items[index] = wallpaper
        save()
    }

    func toggleFavorite(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isFavorite.toggle()
            save()
        } else if BuiltinShaders.ids.contains(id) {
            if favoriteBuiltins.contains(id) { favoriteBuiltins.remove(id) } else { favoriteBuiltins.insert(id) }
            UserDefaults.standard.set(favoriteBuiltins.map(\.uuidString), forKey: Self.favoritesKey)
        }
    }

    func delete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        try? FileManager.default.removeItem(at: AppPaths.folder(for: id))
        save()
    }

    @discardableResult
    func saveShader(title: String, config: ShaderConfig, category: String) -> Wallpaper {
        let wallpaper = Wallpaper(
            id: UUID(), kind: .shader, title: title, category: category,
            author: "You", addedAt: Date(), shader: config
        )
        items.insert(wallpaper, at: 0)
        save()
        return wallpaper
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async -> ImportResult {
        var result = ImportResult()
        for url in urls {
            guard MediaInspector.isVideoFile(url) else {
                result.failures.append((url.lastPathComponent, String(localized: "Not a video file.")))
                continue
            }
            let job = ImportJob(id: UUID(), name: url.lastPathComponent)
            importJobs.append(job)
            do {
                let wallpaper = try await importVideo(from: url, id: job.id)
                items.insert(wallpaper, at: 0)
                save()
                result.added.append(wallpaper)
            } catch {
                result.failures.append((url.lastPathComponent, error.localizedDescription))
            }
            importJobs.removeAll { $0.id == job.id }
        }
        return result
    }

    private func importVideo(from source: URL, id: UUID) async throws -> Wallpaper {
        let folder = AppPaths.folder(for: id)
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let destination = folder.appending(path: "video.\(ext)")

        // Copies are APFS clones on the same volume; other volumes can take a while.
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }.value

        do {
            let meta = try await MediaInspector.inspect(destination)
            let thumbnail = try await MediaInspector.frame(of: destination, maxPixelSize: CGSize(width: 960, height: 960), at: 0.08)
            try MediaInspector.writeJPEG(thumbnail, to: folder.appending(path: "thumb.jpg"))
            return Wallpaper(
                id: id,
                kind: .video,
                title: Self.prettyTitle(for: source),
                category: "Other",
                author: "You",
                addedAt: Date(),
                video: VideoAsset(
                    fileName: destination.lastPathComponent,
                    originalName: source.lastPathComponent,
                    width: meta.width, height: meta.height,
                    duration: meta.duration, frameRate: meta.frameRate,
                    codec: meta.codec, fileSize: meta.fileSize,
                    isHDR: meta.isHDR, hasAudio: meta.hasAudio,
                    optimized: nil
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func prettyTitle(for url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        // UUIDs and hashes from download sites make poor titles.
        let compact = raw.filter { $0 != "-" && $0 != "_" && $0 != " " }
        if compact.count >= 16, compact.allSatisfy(\.isHexDigit) {
            return String(localized: "Untitled Video")
        }
        let base = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let words = base.split(separator: " ").map(String.init)
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return "Untitled" }
        return joined == joined.lowercased() ? joined.capitalized : joined
    }

    // MARK: Optimisation

    func optimize(_ wallpaperID: UUID, maxDisplayWidth: Int) async throws {
        guard let wallpaper = wallpaper(id: wallpaperID),
              let video = wallpaper.video,
              let source = sourceURL(for: wallpaper),
              let plan = VideoOptimizer.plan(for: video, maxDisplayWidth: maxDisplayWidth)
        else { return }

        optimizing[wallpaperID] = 0
        defer { optimizing[wallpaperID] = nil }
        let output = AppPaths.folder(for: wallpaperID).appending(path: "optimized.mp4")
        try await VideoOptimizer.export(source, to: output, preset: plan.preset) { [weak self] value in
            Task { @MainActor in
                guard let self, self.optimizing[wallpaperID] != nil else { return }
                self.optimizing[wallpaperID] = value
            }
        }
        let meta = try await MediaInspector.inspect(output)
        guard var current = self.wallpaper(id: wallpaperID), current.video != nil else { return }
        current.video?.optimized = OptimizedVideo(
            fileName: output.lastPathComponent, width: meta.width, height: meta.height, fileSize: meta.fileSize
        )
        update(current)
    }
}
