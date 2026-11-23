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
    /// Built-in presets are immutable, so their position/zoom lives here.
    private(set) var builtinFramings: [UUID: WallpaperFraming] = [:]

    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    private static let favoritesKey = "favoriteBuiltinWallpapers"
    private static let builtinFramingsKey = "builtinWallpaperFramings"

    // MARK: Lookup

    var builtins: [Wallpaper] {
        BuiltinShaders.wallpapers.map(decorated)
    }

    private func decorated(_ builtin: Wallpaper) -> Wallpaper {
        var copy = builtin
        copy.isFavorite = favoriteBuiltins.contains(builtin.id)
        copy.framing = builtinFramings[builtin.id]
        return copy
    }

    var all: [Wallpaper] { items + builtins }
    var videos: [Wallpaper] { items.filter { $0.kind == .video } }
    var customShaders: [Wallpaper] { items.filter { $0.kind == .shader } }
    var webPages: [Wallpaper] { items.filter { $0.kind == .web } }
    var scenes: [Wallpaper] { items.filter { $0.kind == .scene } }
    var totalDiskUsage: Int64 {
        items.reduce(0) { total, item in
            let video = item.video.map { $0.fileSize + ($0.optimized?.fileSize ?? 0) } ?? 0
            return total + video + (item.package?.byteCount ?? 0)
        }
    }

    /// Workshop items already imported, so discovery can mark them and skip duplicates.
    var workshopIDs: Set<String> { Set(items.compactMap { $0.package?.workshopID }) }

    func wallpaper(workshopID: String) -> Wallpaper? {
        items.first { $0.package?.workshopID == workshopID }
    }

    func wallpaper(id: UUID) -> Wallpaper? {
        if let item = items.first(where: { $0.id == id }) { return item }
        guard let builtin = BuiltinShaders.preset(id: id)?.wallpaper else { return nil }
        return decorated(builtin)
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
        guard wallpaper.kind != .shader, !wallpaper.isBuiltin else { return nil }
        return AppPaths.folder(for: wallpaper.id).appending(path: "thumb.jpg")
    }

    /// The folder holding a web or scene project's files.
    func packageFolder(for wallpaper: Wallpaper) -> URL? {
        guard let package = wallpaper.package, package.remoteURL == nil else { return nil }
        return AppPaths.folder(for: wallpaper.id).appending(path: package.folder, directoryHint: .isDirectory)
    }

    /// Animated or still preview shipped with a project.
    func previewURL(for wallpaper: Wallpaper) -> URL? {
        guard let folder = packageFolder(for: wallpaper), let preview = wallpaper.package?.preview else { return nil }
        let url = folder.appending(path: preview)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Persistence

    func load() {
        favoriteBuiltins = Set((UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []).compactMap(UUID.init(uuidString:)))
        if let data = UserDefaults.standard.data(forKey: Self.builtinFramingsKey),
           let stored = try? JSONDecoder().decode([UUID: WallpaperFraming].self, from: data) {
            builtinFramings = stored
        }
        guard let data = try? Data(contentsOf: AppPaths.libraryFile) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([Wallpaper].self, from: data)
        } catch {
            Log.library.error("Library file unreadable: \(error.localizedDescription, privacy: .public)")
        }
        dropOversizedOptimizedCopies()
    }

    /// Earlier builds could produce an "optimised" copy larger than the source. Remove those
    /// so playback falls back to the original and the improved optimiser can be run again.
    private func dropOversizedOptimizedCopies() {
        var changed = false
        for index in items.indices {
            guard let video = items[index].video, let optimized = video.optimized,
                  Double(optimized.fileSize) > Double(video.fileSize) * VideoOptimizer.requiredSaving
            else { continue }
            try? FileManager.default.removeItem(at: AppPaths.folder(for: items[index].id).appending(path: optimized.fileName))
            items[index].video?.optimized = nil
            changed = true
            Log.library.info("Removed an optimised copy that wasn't smaller than its source")
        }
        if changed { save() }
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

    /// Updates position/zoom immediately; the file write is coalesced while a slider is dragged.
    func setFraming(_ framing: WallpaperFraming, for id: UUID) {
        let stored: WallpaperFraming? = framing.isCentered ? nil : framing.clamped
        if let index = items.firstIndex(where: { $0.id == id }) {
            guard items[index].framing != stored else { return }
            items[index].framing = stored
            pendingSave?.cancel()
            pendingSave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.save()
            }
        } else if BuiltinShaders.ids.contains(id) {
            guard builtinFramings[id] != stored else { return }
            builtinFramings[id] = stored
            if let data = try? JSONEncoder().encode(builtinFramings) {
                UserDefaults.standard.set(data, forKey: Self.builtinFramingsKey)
            }
        }
    }

    /// Changes one user property; `nil` returns it to the project's default.
    func setPropertyValue(_ value: PropertyValue?, key: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].package != nil else { return }
        guard items[index].package?.values[key] != value else { return }
        items[index].package?.values[key] = value
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func resetProperties(for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].package != nil else { return }
        items[index].package?.values = [:]
        save()
    }

    /// Records a thumbnail rendered after import (web snapshot, scene frame).
    func noteThumbnailChanged() { revision += 1 }

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

    func importFiles(_ urls: [URL], source: String = "folder") async -> ImportResult {
        var result = ImportResult()
        for url in urls {
            let candidate = PackageImporter.classify(url)
            if case .unsupported(let reason) = candidate {
                result.failures.append((url.lastPathComponent, reason))
                continue
            }
            let job = ImportJob(id: UUID(), name: url.lastPathComponent)
            importJobs.append(job)
            do {
                let wallpaper: Wallpaper
                switch candidate {
                case .video(let file):
                    wallpaper = try await importVideo(from: file, id: job.id)
                case .project(let folder):
                    wallpaper = try await importProject(at: folder, id: job.id, source: source)
                case .webFolder(let folder, let entry):
                    wallpaper = try await PackageImporter.importWebFolder(folder, entry: entry, id: job.id)
                case .unsupported:
                    throw PackageImporter.ImportError.notAWallpaper
                }
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

    /// Adds a web page shown straight from its address.
    func addWebPage(_ url: URL, title: String?) throws -> Wallpaper {
        let wallpaper = try PackageImporter.webPage(url, id: UUID(), title: title)
        items.insert(wallpaper, at: 0)
        save()
        return wallpaper
    }

    private func importProject(at folder: URL, id: UUID, source: String) async throws -> Wallpaper {
        let project = try await Task.detached(priority: .userInitiated) { try WEProject.load(folder: folder) }.value
        if let workshopID = project.workshopID, let existing = wallpaper(workshopID: workshopID) {
            throw PackageImporter.ImportError.alreadyInLibrary(existing.title)
        }
        guard project.kind == .video else {
            return try await PackageImporter.importProject(project, id: id, source: source)
        }
        // A video project becomes an ordinary video wallpaper that remembers where it came from.
        var wallpaper = try await importVideo(from: project.entryURL, id: id, title: project.title)
        var package = PackageAsset(entry: project.entry)
        package.folder = ""
        package.workshopID = project.workshopID
        package.source = source
        package.tags = project.tags
        package.contentRating = project.contentRating
        wallpaper.package = package
        wallpaper.category = PackageImporter.category(for: project.tags)
        wallpaper.author = source == "folder" ? "You" : "Steam Workshop"
        if let preview = project.previewURL, wallpaper.kind == .video {
            // Wallpaper Engine previews are hand-picked frames; prefer them to an arbitrary one.
            PackageImporter.writeThumbnail(from: preview, to: AppPaths.folder(for: id).appending(path: "thumb.jpg"))
        }
        return wallpaper
    }

    private func importVideo(from source: URL, id: UUID, title: String? = nil) async throws -> Wallpaper {
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
            let meta: MediaMetadata
            do {
                meta = try await MediaInspector.inspect(destination)
            } catch MediaError.notPlayable(let ext) where ext == "WEBM" {
                // AVFoundation has no WebM decoder, but WebKit does.
                try? FileManager.default.removeItem(at: folder)
                return try await PackageImporter.webVideoPackage(from: source, id: id, title: title ?? Self.prettyTitle(for: source))
            }
            let thumbnail = try await MediaInspector.frame(of: destination, maxPixelSize: CGSize(width: 960, height: 960), at: 0.08)
            try MediaInspector.writeJPEG(thumbnail, to: folder.appending(path: "thumb.jpg"))
            return Wallpaper(
                id: id,
                kind: .video,
                title: title ?? Self.prettyTitle(for: source),
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

    nonisolated static func prettyTitle(for url: URL) -> String {
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

    enum OptimizationOutcome {
        case optimized(saved: Int64)
        /// The HEVC copy wasn't clearly smaller; the original is kept and optimisation isn't offered again.
        case keptOriginal
        case notNeeded
    }

    func optimize(_ wallpaperID: UUID, maxDisplayWidth: Int) async throws -> OptimizationOutcome {
        guard let wallpaper = wallpaper(id: wallpaperID),
              let video = wallpaper.video,
              let source = sourceURL(for: wallpaper),
              let plan = VideoOptimizer.plan(for: video, maxDisplayWidth: maxDisplayWidth)
        else { return .notNeeded }

        optimizing[wallpaperID] = 0
        defer { optimizing[wallpaperID] = nil }
        let output = AppPaths.folder(for: wallpaperID).appending(path: "optimized.mp4")
        try await VideoOptimizer.export(source, to: output, plan: plan) { [weak self] value in
            Task { @MainActor in
                guard let self, self.optimizing[wallpaperID] != nil else { return }
                self.optimizing[wallpaperID] = value
            }
        }
        let meta = try await MediaInspector.inspect(output)
        guard var current = self.wallpaper(id: wallpaperID), current.video != nil else { return .notNeeded }

        if Double(meta.fileSize) > Double(video.fileSize) * VideoOptimizer.requiredSaving {
            try? FileManager.default.removeItem(at: output)
            current.video?.optimizationDeclined = true
            update(current)
            return .keptOriginal
        }
        current.video?.optimized = OptimizedVideo(
            fileName: output.lastPathComponent, width: meta.width, height: meta.height, fileSize: meta.fileSize
        )
        update(current)
        return .optimized(saved: video.fileSize - meta.fileSize)
    }
}
