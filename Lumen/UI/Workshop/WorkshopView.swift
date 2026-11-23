import ImageIO
import SwiftUI

enum WorkshopFilter: String, CaseIterable, Identifiable {
    case all, scenes, web, videos, notAdded
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .scenes: String(localized: "Scenes")
        case .web: String(localized: "Web")
        case .videos: String(localized: "Videos")
        case .notAdded: String(localized: "Not in Library")
        }
    }
}

/// Wallpaper Engine projects already on this Mac (Steam Workshop downloads, other apps,
/// chosen folders), ready to add to the library.
struct WorkshopView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: WorkshopFilter = .all

    var body: some View {
        let workshop = model.workshop
        let projects = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(eyebrow: "Wallpaper Engine", title: "Workshop", subtitle: subtitle) {
                    GlassEffectContainer(spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.xs) {
                            Button {
                                model.isSteamPanelPresented = true
                            } label: {
                                Label("Download from Steam", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.glassProminent)
                            Button {
                                chooseFolder()
                            } label: {
                                Label("Add Folder…", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.glass)
                            Button {
                                workshop.scan()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.glass)
                            .disabled(workshop.isScanning)
                        }
                    }
                }
                if model.settings.sceneAssets == nil && workshop.projects.contains(where: { $0.kind == .scene }) {
                    AssetsNotice()
                }
                controls(projects)
                if workshop.isScanning && workshop.projects.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 60)
                } else if projects.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 256, maximum: 380), spacing: Theme.Space.lg, alignment: .top)],
                        alignment: .leading,
                        spacing: Theme.Space.xl
                    ) {
                        ForEach(projects) { project in
                            WorkshopCard(project: project)
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
        .task { if workshop.lastScan == nil { workshop.scan() } }
    }

    private var subtitle: String {
        let workshop = model.workshop
        let names = workshop.sources.map(\.title)
        if names.isEmpty { return String(localized: "No Wallpaper Engine folders found on this Mac yet.") }
        return String(localized: "\(workshop.projects.count) projects in \(names.formatted(.list(type: .and)))")
    }

    private func controls(_ projects: [DiscoveredProject]) -> some View {
        let addable = projects.filter { $0.isSupported && !isAdded($0) }
        return HStack(spacing: Theme.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xs) {
                    ForEach(WorkshopFilter.allCases) { item in
                        FilterChip(title: item.title, count: base(for: item).count, isSelected: filter == item) {
                            filter = item
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            if !addable.isEmpty {
                Button {
                    model.importWorkshop(addable)
                } label: {
                    Label("Add \(addable.count) to Library", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .fixedSize()
                .disabled(!model.library.importJobs.isEmpty)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "shippingbox")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Nothing here yet").font(Theme.display(22))
            Text("Lumen looks in Steam's Wallpaper Engine Workshop folder and other apps' libraries. You can also add a folder of projects, for example one copied from a Windows PC.")
                .font(Theme.TypeScale.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                .fill(Theme.Surface.base)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 7]))
                .foregroundStyle(Theme.Surface.strokeHover)
        )
    }

    private func base(for filter: WorkshopFilter) -> [DiscoveredProject] {
        let projects = model.workshop.projects
        switch filter {
        case .all: return projects
        case .scenes: return projects.filter { $0.kind == .scene }
        case .web: return projects.filter { $0.kind == .web }
        case .videos: return projects.filter { $0.kind == .video }
        case .notAdded: return projects.filter { $0.isSupported && !isAdded($0) }
        }
    }

    private var filtered: [DiscoveredProject] {
        var result = base(for: filter)
        let query = model.router.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) } }
        }
        return result
    }

    private func isAdded(_ project: DiscoveredProject) -> Bool {
        project.workshopID.map { model.library.workshopIDs.contains($0) } ?? false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a folder of Wallpaper Engine projects (each with a project.json).")
        panel.prompt = String(localized: "Add Folder")
        if panel.runModal() == .OK, let url = panel.url {
            model.workshop.addFolder(url)
        }
    }
}

private struct WorkshopCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let project: DiscoveredProject
    @State private var image: NSImage?
    @State private var hovering = false

    private var existing: Wallpaper? { project.workshopID.flatMap { model.library.wallpaper(workshopID: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
            // Place preview inside `.overlay` on a fixed 16:9 surface so square 512×512 Workshop previews never stretch the grid.
            Theme.Surface.mediaFill
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        Image(systemName: kindSymbol)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.quaternary)
                    }
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.50),
                            .init(color: .black.opacity(hovering ? 0.62 : 0.42), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    HStack(spacing: Theme.Space.xxs) {
                        ArtBadge(text: kindLabel, symbol: kindSymbol)
                        if let rating = project.contentRating, rating != "Everyone" { ArtBadge(text: rating) }
                    }
                    .padding(Theme.Space.sm - 2)
                }
                .overlay(alignment: .bottomTrailing) { action.padding(Theme.Space.sm - 2) }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .strokeBorder(hovering ? Theme.Surface.strokeHover : Theme.Surface.stroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(hovering ? 0.45 : 0.26), radius: hovering ? 20 : 12, y: hovering ? 10 : 6)
                .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: project.title)
                    .font(Theme.TypeScale.cardTitle)
                    .lineLimit(1)
                Text(verbatim: tagsLine)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: hovering)
        .task(id: project.preview) { image = await WorkshopThumbnails.image(for: project.preview) }
    }

    private var tagsLine: String {
        let joined = project.tags.prefix(3).joined(separator: " · ")
        return joined.isEmpty ? kindLabel : joined
    }

    @ViewBuilder
    private var action: some View {
        if let existing {
            Button {
                model.router.open(.wallpaper(existing.id))
            } label: {
                Label("In Library", systemImage: "checkmark")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.glass)
        } else if project.isSupported {
            Button {
                model.importWorkshop([project])
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.glassProminent)
            .disabled(model.library.importJobs.contains { $0.name == project.folder.lastPathComponent })
        } else {
            ArtBadge(text: String(localized: "Windows only"))
        }
    }

    private var kindLabel: String {
        switch project.kind {
        case .scene: String(localized: "Scene")
        case .web: "Web"
        case .video: String(localized: "Video")
        case .application: String(localized: "App")
        case .preset: String(localized: "Preset")
        case .unknown: "?"
        }
    }

    private var kindSymbol: String {
        switch project.kind {
        case .scene: "square.3.layers.3d"
        case .web: "globe"
        case .video: "film"
        default: "questionmark"
        }
    }
}

/// Small first-frame thumbnails of project previews, decoded off the main thread.
enum WorkshopThumbnails {
    @MainActor private static let cache = NSCache<NSURL, NSImage>()

    @MainActor
    static func image(for url: URL?) async -> NSImage? {
        guard let url else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 480,
                  ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}

/// Shown when scenes can't be drawn because Wallpaper Engine's shared assets are missing.
struct AssetsNotice: View {
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.paused)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Theme.paused.opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text("Scenes need Wallpaper Engine's shared assets")
                    .font(Theme.TypeScale.cardTitle)
                Text("Scenes use shaders and effects that ship with Wallpaper Engine, not with each Workshop item. Point Lumen at an assets folder in Settings › Wallpaper Engine.")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.glass)
        }
        .padding(Theme.Space.md)
        .lumenSurface(radius: Theme.Radius.lg, stroke: Theme.paused.opacity(0.32))
    }
}
