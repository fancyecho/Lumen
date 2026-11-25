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

enum WorkshopMode: String {
    /// The live Steam Workshop, browsed and downloaded in-app.
    case steam
    /// Wallpaper Engine projects already on this Mac (Steam's download folder, other apps, chosen folders).
    case local
}

/// The Workshop tab: the live Steam Workshop, or the projects already on this Mac.
struct WorkshopView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("workshopSource") private var source: WorkshopMode = .steam
    @AppStorage("workshopInspector") private var showsInspector = true
    @State private var filter: WorkshopFilter = .all

    private var inspectorVisible: Bool { source == .steam && showsInspector }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        header
                            .id(Self.topAnchor)
                        if source == .steam {
                            SteamWorkshopSection()
                        } else {
                            localContent
                        }
                    }
                    .padding(.leading, Theme.Space.page)
                    .padding(.trailing, inspectorVisible ? Theme.Space.xl : Theme.Space.page)
                    .padding(.top, Self.contentTop)
                    // Scrolled to the end, the pager's bottom edge meets the preview panel's.
                    .padding(.bottom, Self.contentTop)
                    .frame(maxWidth: Theme.Layout.galleryMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                // With the preview panel open the scroller would sit in the gutter between grid and
                // panel; the pager is the way through the results, so it goes.
                .scrollIndicators(inspectorVisible ? .never : .automatic)
                // A new page starts at the top, like turning a page.
                .onChange(of: model.workshopBrowser.page) {
                    // After the grid swaps to placeholders, so an animation can't be cut short mid-way.
                    Task { @MainActor in proxy.scrollTo(Self.topAnchor, anchor: .top) }
                }
            }
            if inspectorVisible {
                // Same inset on three sides, and the top shares the page header's top edge
                // (`contentTop`), so the panel sits square in the corner of the window.
                WorkshopInspector()
                    .frame(width: 340)
                    .padding(.top, Self.contentTop)
                    .padding([.trailing, .bottom], Self.contentTop)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.smooth, value: inspectorVisible)
        .task(id: source) {
            if source == .local, model.workshop.lastScan == nil { model.workshop.scan() }
        }
    }

    private static let topAnchor = "workshop-top"
    /// Gap between the toolbar and the first line of the page; the preview panel uses it on every side.
    private static let contentTop = Theme.Space.lg

    private var header: some View {
        PageHeader(eyebrow: "Wallpaper Engine", title: "Workshop", subtitle: subtitle) {
            HStack(spacing: Theme.Space.sm) {
                GlassSegmentedControl(
                    selection: $source,
                    options: [
                        .init(value: .steam, title: "Steam Workshop", symbol: "globe"),
                        .init(value: .local, title: "On This Mac", symbol: "laptopcomputer"),
                    ]
                )
                if source == .steam {
                    SteamAccountControl()
                } else {
                    localActions
                }
            }
        }
    }

    private var localActions: some View {
        let workshop = model.workshop
        return HStack(spacing: Theme.Space.xs) {
            Button {
                chooseFolder()
            } label: {
                Label("Add Folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.lumenSecondary)
            Button {
                workshop.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.lumenIcon)
            .disabled(workshop.isScanning)
            .help("Refresh")
            .accessibilityLabel(Text("Refresh"))
        }
    }

    @ViewBuilder
    private var localContent: some View {
        let workshop = model.workshop
        let projects = filtered
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
                columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: Theme.Space.xl, alignment: .top)],
                alignment: .leading,
                spacing: Theme.Space.xxl
            ) {
                ForEach(projects) { project in
                    WorkshopCard(project: project)
                }
            }
        }
    }

    private var subtitle: String {
        if source == .steam {
            return String(localized: "Browse Wallpaper Engine's Steam Workshop and download straight into your library.")
        }
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
                .buttonStyle(.lumenSecondary)
                .fixedSize()
                .disabled(!model.library.importJobs.isEmpty)
            }
        }
    }

    private var emptyState: some View {
        EmptyStatePanel(
            symbol: "shippingbox",
            title: String(localized: "Nothing here yet"),
            message: String(localized: "Lumen looks in Steam's Wallpaper Engine Workshop folder and other apps' libraries. You can also add a folder of projects, for example one copied from a Windows PC.")
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
        VStack(alignment: .leading, spacing: Theme.Space.sm - 1) {
            // Preview sits in `.overlay` on a fixed 16:9 surface so square 512×512 Workshop previews never stretch the grid.
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
                            .foregroundStyle(Theme.Ink.quaternary)
                    }
                }
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(hovering ? 0.6 : 0.38), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    if let rating = project.contentRating, rating != "Everyone" {
                        ArtBadge(text: rating).padding(Theme.Space.sm - 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if existing != nil {
                        ArtBadge(text: String(localized: "In Library"), symbol: "checkmark")
                            .padding(Theme.Space.sm - 2)
                    } else if !project.isSupported {
                        ArtBadge(text: String(localized: "Windows only"))
                            .padding(Theme.Space.sm - 2)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Actions appear on hover, like library cards, so the grid stays a calm wall of artwork.
                    if hovering {
                        action
                            .padding(Theme.Space.sm - 2)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
                    }
                }
                .artworkFrame(isHovering: hovering)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: project.title)
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                Text(verbatim: tagsLine)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: hovering)
        .task(id: project.preview) { image = await WorkshopThumbnails.image(for: project.preview) }
    }

    private var tagsLine: String {
        ([kindLabel] + project.tags.prefix(2)).joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        if let existing {
            Button {
                model.router.open(.wallpaper(existing.id))
            } label: {
                Label("Open", systemImage: "arrow.up.right")
            }
            .buttonStyle(.lumenSecondary)
        } else if project.isSupported {
            Button {
                model.importWorkshop([project])
            } label: {
                Label("Add to Library", systemImage: "plus")
            }
            .buttonStyle(.lumenPrimary)
            .disabled(model.library.importJobs.contains { $0.name == project.folder.lastPathComponent })
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
            IconWell(symbol: "exclamationmark.triangle.fill", tint: Theme.paused, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Scenes need Wallpaper Engine's shared assets")
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
                Text("Scenes use shaders and effects that ship with Wallpaper Engine, not with each Workshop item. Point Lumen at an assets folder in Settings › Wallpaper Engine.")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.lumenSecondary)
        }
        .padding(Theme.Space.md)
        .lumenSurface(radius: Theme.Radius.lg, stroke: Theme.paused.opacity(0.32))
    }
}
