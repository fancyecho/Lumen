import Foundation
import Observation

/// A Wallpaper Engine project found on this Mac, not yet (or already) in the library.
struct DiscoveredProject: Identifiable, Hashable {
    let id: String
    let folder: URL
    let title: String
    let kind: WEProject.Kind
    let workshopID: String?
    let preview: URL?
    let tags: [String]
    let contentRating: String?
    let source: WorkshopSource.Kind
    let byteCount: Int64

    var isSupported: Bool { kind == .scene || kind == .web || kind == .video }
}

/// A folder Lumen looks in for Wallpaper Engine projects. Lumen only reads these folders;
/// adding a project to the library copies it (as an APFS clone on the same disk).
struct WorkshopSource: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        /// Steam's Wallpaper Engine Workshop downloads (`steamapps/workshop/content/431960`).
        case steam
        /// Another Mac app's library of Wallpaper Engine projects.
        case wallpaperMachine
        /// A folder the person chose (an external disk, a copy from a Windows PC…).
        case folder
    }

    var url: URL
    var kind: Kind
    var id: String { url.path }

    var title: String {
        switch kind {
        case .steam: String(localized: "Steam Workshop")
        case .wallpaperMachine: "WallpaperMachine"
        case .folder: url.lastPathComponent
        }
    }

    var importSource: String {
        switch kind {
        case .steam: "steam"
        case .wallpaperMachine: "wallpapermachine"
        case .folder: "folder"
        }
    }
}

/// Finds Wallpaper Engine projects in Steam's Workshop folders, other apps' libraries and
/// folders the person added.
@MainActor
@Observable
final class WorkshopLibrary {
    private(set) var projects: [DiscoveredProject] = []
    private(set) var sources: [WorkshopSource] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    @ObservationIgnored private static let customKey = "workshopCustomFolders"

    var customFolders: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func addFolder(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        guard !paths.contains(url.path) else { return }
        paths.append(url.path)
        UserDefaults.standard.set(paths, forKey: Self.customKey)
        scan()
    }

    func removeFolder(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: Self.customKey) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: Self.customKey)
        scan()
    }

    static func defaultSources(custom: [URL]) -> [WorkshopSource] {
        var sources = SteamLibrary.workshopFolders().map { WorkshopSource(url: $0, kind: .steam) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let wallpaperMachine = support.appending(path: "WallpaperMachine/Library", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: wallpaperMachine.path) {
            sources.append(WorkshopSource(url: wallpaperMachine, kind: .wallpaperMachine))
        }
        for url in custom where FileManager.default.fileExists(atPath: url.path) {
            sources.append(WorkshopSource(url: url, kind: .folder))
        }
        return sources
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let sources = Self.defaultSources(custom: customFolders)
        self.sources = sources
        Task {
            let found = await Task.detached(priority: .userInitiated) { Self.projects(in: sources) }.value
            projects = found
            isScanning = false
            lastScan = Date()
        }
    }

    nonisolated static func projects(in sources: [WorkshopSource]) -> [DiscoveredProject] {
        var result: [DiscoveredProject] = []
        var seen = Set<String>()
        for source in sources {
            // A chosen folder may itself be one project.
            let candidates: [URL]
            if WEProject.isProjectFolder(source.url) {
                candidates = [source.url]
            } else {
                candidates = ((try? FileManager.default.contentsOfDirectory(
                    at: source.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )) ?? []).filter { WEProject.isProjectFolder($0) }
            }
            for folder in candidates {
                guard let project = try? WEProject.load(folder: folder) else { continue }
                let key = project.workshopID ?? folder.path
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                let size = (try? FileManager.default.attributesOfItem(atPath: project.entryURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                result.append(DiscoveredProject(
                    id: key,
                    folder: folder,
                    title: project.title,
                    kind: project.kind,
                    workshopID: project.workshopID,
                    preview: project.previewURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
                    tags: project.tags,
                    contentRating: project.contentRating,
                    source: source.kind,
                    byteCount: size
                ))
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
