import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns dropped folders, Wallpaper Engine projects, HTML files and web addresses into library items.
enum PackageImporter {
    enum Candidate {
        case video(URL)
        /// A folder with `project.json`.
        case project(URL)
        /// A folder of HTML without a project file; `entry` is relative to the folder.
        case webFolder(URL, entry: String)
        /// The project folder of a wallpaper whose renderer is built into Lumen.
        case native(URL, NativeWallpaper)
        case unsupported(String)
    }

    enum ImportError: LocalizedError {
        case alreadyInLibrary(String)
        case notAWallpaper
        case missingNativeResource(String)

        var errorDescription: String? {
            switch self {
            case .alreadyInLibrary(let title): String(localized: "“\(title)” is already in your library.")
            case .notAWallpaper: String(localized: "Not a video, web page or Wallpaper Engine project.")
            case .missingNativeResource(let title):
                String(localized: "The \(title) project folder is missing its artwork. Prepare its assets first, as its README describes.", table: "Native")
            }
        }
    }

    static func classify(_ url: URL) -> Candidate {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .unsupported(String(localized: "The file is missing."))
        }
        if isDirectory.boolValue {
            if let native = NativeWallpaper.detect(folder: url) { return .native(url, native) }
            if WEProject.isProjectFolder(url) { return .project(url) }
            for entry in ["index.html", "index.htm"] where FileManager.default.fileExists(atPath: url.appending(path: entry).path) {
                return .webFolder(url, entry: entry)
            }
            return .unsupported(String(localized: "The folder has no project.json or index.html."))
        }
        let ext = url.pathExtension.lowercased()
        if url.lastPathComponent.lowercased() == "project.json" { return .project(url.deletingLastPathComponent()) }
        if ext == "pkg", WEProject.isProjectFolder(url.deletingLastPathComponent()) {
            return .project(url.deletingLastPathComponent())
        }
        if ext == "html" || ext == "htm" {
            let folder = url.deletingLastPathComponent()
            if WEProject.isProjectFolder(folder) { return .project(folder) }
            return .webFolder(folder, entry: url.lastPathComponent)
        }
        if MediaInspector.isVideoFile(url) { return .video(url) }
        return .unsupported(String(localized: "Not a video, web page or Wallpaper Engine project."))
    }

    // MARK: Projects

    /// Copies a web or scene project into the item folder. Same-volume copies are APFS clones,
    /// so even large projects take no extra space and import instantly.
    static func importProject(_ project: WEProject, id: UUID, source: String) async throws -> Wallpaper {
        switch project.kind {
        case .web, .scene:
            break
        case .application:
            throw WEProject.ProjectError.unsupported("Application")
        default:
            throw WEProject.ProjectError.unsupported(project.kind.rawValue.capitalized)
        }
        let kind: WallpaperKind = project.kind == .web ? .web : .scene
        let folder = AppPaths.folder(for: id)
        let content = folder.appending(path: "content", directoryHint: .isDirectory)
        try await copyFolder(project.folder, to: content, parent: folder)

        do {
            let entryExists = FileManager.default.fileExists(atPath: content.appending(path: project.entry).path)
            let packed = FileManager.default.fileExists(atPath: content.appending(path: "scene.pkg").path)
            guard !project.entry.isEmpty, entryExists || (kind == .scene && packed) else {
                throw WEProject.ProjectError.missingEntry(project.entry)
            }
            var package = PackageAsset(entry: project.entry)
            package.workshopID = project.workshopID
            package.source = source
            package.tags = project.tags
            package.contentRating = project.contentRating
            package.properties = project.properties
            package.preview = project.preview
            package.supportsAudio = project.supportsAudio
            package.byteCount = await Task.detached(priority: .utility) { folderSize(content) }.value
            if kind == .scene, let canvas = SceneCanvas.size(of: content, entry: project.entry) {
                package.width = Int(canvas.width)
                package.height = Int(canvas.height)
            }
            if let preview = project.preview {
                writeThumbnail(from: content.appending(path: preview), to: folder.appending(path: "thumb.jpg"))
            }
            return Wallpaper(
                id: id, kind: kind, title: project.title,
                category: category(for: project.tags), author: author(for: source),
                addedAt: Date(), package: package
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// A plain folder of HTML (a CodePen export, a self-made page).
    static func importWebFolder(_ source: URL, entry: String, id: UUID) async throws -> Wallpaper {
        let folder = AppPaths.folder(for: id)
        let content = folder.appending(path: "content", directoryHint: .isDirectory)
        try await copyFolder(source, to: content, parent: folder)
        var package = PackageAsset(entry: entry)
        package.source = "folder"
        package.byteCount = await Task.detached(priority: .utility) { folderSize(content) }.value
        let title = LibraryStore.prettyTitle(for: source)
        return Wallpaper(id: id, kind: .web, title: title, category: "Other", author: "You", addedAt: Date(), package: package)
    }

    /// Copies the person's resources for a native wallpaper (Code Sea's portrait and preview) out of
    /// its project folder; the renderer itself is part of Lumen, so nothing else is needed.
    static func importNative(_ source: URL, native: NativeWallpaper, id: UUID) async throws -> Wallpaper {
        let folder = AppPaths.folder(for: id)
        let content = folder.appending(path: "content", directoryHint: .isDirectory)
        var package = PackageAsset(entry: native.rawValue)
        package.source = NativeWallpaper.packageSource
        package.properties = native.properties
        let values = package.resolvedValues
        do {
            try await Task.detached(priority: .userInitiated) {
                let scoped = source.startAccessingSecurityScopedResource()
                defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
                for file in native.importedFiles {
                    let from = source.appending(path: file.source)
                    guard FileManager.default.fileExists(atPath: from.path) else { continue }
                    try FileManager.default.copyItem(at: from, to: content.appending(path: file.stored))
                }
                if let required = native.requiredFile, !FileManager.default.fileExists(atPath: content.appending(path: required).path) {
                    throw ImportError.missingNativeResource(native.title)
                }
                let preview = content.appending(path: "preview.jpg")
                if !FileManager.default.fileExists(atPath: preview.path) {
                    switch native {
                    case .codeSea:
                        try? CodeSea.writeThumbnail(avatarURL: CodeSea.avatarURL(in: content), values: values, to: preview)
                    case .proStrands:
                        if let image = PROStrands.imageURL(in: content) {
                            try? PROStrands.writeThumbnail(imageURL: image, values: values, to: preview)
                        }
                    }
                }
            }.value
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let preview = content.appending(path: "preview.jpg")
        if FileManager.default.fileExists(atPath: preview.path) {
            package.preview = "preview.jpg"
            writeThumbnail(from: preview, to: folder.appending(path: "thumb.jpg"))
        }
        package.byteCount = await Task.detached(priority: .utility) { folderSize(content) }.value
        return Wallpaper(id: id, kind: .native, title: native.title, category: native.category, author: "You",
                         addedAt: Date(), package: package)
    }

    /// A web page shown straight from the internet.
    static func webPage(_ url: URL, id: UUID, title: String?) throws -> Wallpaper {
        try FileManager.default.createDirectory(at: AppPaths.folder(for: id), withIntermediateDirectories: true)
        var package = PackageAsset(entry: "")
        package.remoteURL = url.absoluteString
        package.source = "web"
        let name = title?.trimmingCharacters(in: .whitespaces)
        return Wallpaper(
            id: id, kind: .web, title: (name?.isEmpty == false ? name : url.host()) ?? url.absoluteString,
            category: "Other", author: url.host() ?? "Web", addedAt: Date(), package: package
        )
    }

    /// A video that AVFoundation can't decode (WebM) still plays through WebKit.
    static func webVideoPackage(from source: URL, id: UUID, title: String) async throws -> Wallpaper {
        let folder = AppPaths.folder(for: id)
        let content = folder.appending(path: "content", directoryHint: .isDirectory)
        let fileName = "video." + source.pathExtension.lowercased()
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: content.appending(path: fileName))
        }.value
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:#000;overflow:hidden}
        video{width:100%;height:100%;object-fit:cover}
        </style></head><body><video src="\(fileName)" autoplay loop muted playsinline></video></body></html>
        """
        try Data(page.utf8).write(to: content.appending(path: "index.html"))
        var package = PackageAsset(entry: "index.html")
        package.source = "folder"
        package.byteCount = await Task.detached(priority: .utility) { folderSize(content) }.value
        return Wallpaper(id: id, kind: .web, title: title, category: "Other", author: "You", addedAt: Date(), package: package)
    }

    // MARK: Helpers

    private static func copyFolder(_ source: URL, to destination: URL, parent: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }.value
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey], options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// First frame of a preview (JPEG, PNG or GIF), scaled for the grid.
    @discardableResult
    static func writeThumbnail(from preview: URL, to destination: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(preview as CFURL, nil) else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 960,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return false }
        return (try? MediaInspector.writeJPEG(image, to: destination, quality: 0.88)) != nil
    }

    static func category(for tags: [String]) -> String {
        let map: [String: String] = [
            "anime": "Anime", "landscape": "Nature", "nature": "Nature", "game": "Games",
            "sci-fi": "Sci-Fi", "abstract": "Abstract", "cyberpunk": "City", "relaxing": "Minimal",
            "pixel art": "Games", "fantasy": "Anime", "girls": "Anime", "space": "Space",
        ]
        for tag in tags {
            if let category = map[tag.lowercased()] { return category }
        }
        return "Other"
    }

    private static func author(for source: String) -> String {
        switch source {
        case "steam", "wallpapermachine": "Steam Workshop"
        default: "You"
        }
    }
}

/// Reads the canvas size a scene was authored for, without building the scene.
enum SceneCanvas {
    static func size(of folder: URL, entry: String) -> CGSize? {
        guard let files = try? SceneFileSystem(projectFolder: folder, assets: nil),
              let data = files.data(entry),
              let json = LenientJSON.object(from: data),
              let general = json["general"] as? [String: Any],
              let projection = general["orthogonalprojection"] as? [String: Any],
              let width = (projection["width"] as? NSNumber)?.doubleValue,
              let height = (projection["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
