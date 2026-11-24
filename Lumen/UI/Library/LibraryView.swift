import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, videos, scenes, web, generative, favorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .videos: String(localized: "Videos")
        case .scenes: String(localized: "Scenes")
        case .web: String(localized: "Web")
        case .generative: String(localized: "Rendered Live")
        case .favorites: String(localized: "Favorites")
        }
    }
    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .videos: "film"
        case .scenes: "square.3.layers.3d"
        case .web: "globe"
        case .generative: "sparkles"
        case .favorites: "heart"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, name, duration, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: String(localized: "Recently Added")
        case .name: String(localized: "Name")
        case .duration: String(localized: "Duration")
        case .size: String(localized: "File Size")
        }
    }
}

enum LibraryLayout: String {
    case grid, list
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var category: String?
    @State private var sort: LibrarySort = .recent
    /// A per-window viewing preference, not an app setting, so it lives beside the view.
    @AppStorage("libraryLayout") private var layout: LibraryLayout = .grid

    var body: some View {
        let wallpapers = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                controls
                if !model.library.importJobs.isEmpty { importProgress }
                if wallpapers.isEmpty {
                    EmptyLibraryView(isSearching: !model.router.searchText.isEmpty, filter: filter)
                } else if layout == .list {
                    WallpaperTable(wallpapers: wallpapers, sort: $sort)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: Theme.Space.xl, alignment: .top)],
                        alignment: .leading,
                        spacing: Theme.Space.xxl
                    ) {
                        ForEach(wallpapers) { wallpaper in
                            WallpaperCard(wallpaper: wallpaper)
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

    private var header: some View {
        let library = model.library
        let search = model.router.searchText
        return PageHeader(
            eyebrow: "Library",
            title: search.isEmpty ? "Your wallpapers" : String(localized: "Results for “\(search)”"),
            subtitle: String(localized: "\(library.items.count) imported · \(library.builtins.count) rendered live · \(Format.bytes(library.totalDiskUsage)) on disk")
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        ForEach(LibraryFilter.allCases) { item in
                            FilterChip(title: item.title, symbol: item.symbol, count: count(for: item), isSelected: filter == item) {
                                filter = item
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    ChromeLabel { Label(sort.title, systemImage: "arrow.up.arrow.down") }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort By")

                LayoutSwitch(layout: $layout)
            }
            let categories = availableCategories
            if categories.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xxs) {
                        FilterChip(title: String(localized: "Any category"), isSelected: category == nil, style: .quiet) { category = nil }
                        ForEach(categories, id: \.self) { name in
                            FilterChip(title: WallpaperCategories.displayName(name), isSelected: category == name, style: .quiet) {
                                category = category == name ? nil : name
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private var importProgress: some View {
        HStack(spacing: Theme.Space.sm - 2) {
            ProgressView().controlSize(.small)
            Text("Importing \(model.library.importJobs.map(\.name).joined(separator: ", "))…")
                .font(Theme.TypeScale.bodyMedium)
                .foregroundStyle(Theme.Ink.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm - 2)
        .background(Capsule().fill(Theme.Surface.base))
        .overlay(Capsule().strokeBorder(Theme.Surface.stroke))
    }

    private var availableCategories: [String] {
        let used = Set(model.library.all.map(\.category))
        return WallpaperCategories.all.filter(used.contains) + used.subtracting(WallpaperCategories.all).sorted()
    }

    private func base(for filter: LibraryFilter) -> [Wallpaper] {
        let library = model.library
        switch filter {
        case .all: return library.all
        case .videos: return library.videos
        case .scenes: return library.scenes
        case .web: return library.webPages
        case .generative: return library.customShaders + library.builtins
        case .favorites: return library.all.filter(\.isFavorite)
        }
    }

    private func count(for filter: LibraryFilter) -> Int { base(for: filter).count }

    private var filtered: [Wallpaper] {
        var result = base(for: filter)
        if let category { result = result.filter { $0.category == category } }
        let query = model.router.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.category.localizedCaseInsensitiveContains(query)
                    || ($0.video?.codec.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        switch sort {
        case .recent: result.sort { $0.addedAt > $1.addedAt }
        case .name: result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .duration: result.sort { ($0.video?.duration ?? 0) > ($1.video?.duration ?? 0) }
        case .size: result.sort { (WallpaperDescriptor.byteCount(for: $0) ?? 0) > (WallpaperDescriptor.byteCount(for: $1) ?? 0) }
        }
        return result
    }
}

/// Grid/list switch drawn like the other glass controls in the row, so heights and edges line up.
private struct LayoutSwitch: View {
    @Binding var layout: LibraryLayout

    var body: some View {
        GlassSegmentedControl(
            selection: $layout,
            options: [
                .init(value: .grid, title: "Grid", symbol: "square.grid.2x2"),
                .init(value: .list, title: "List", symbol: "list.bullet"),
            ],
            showsTitles: false
        )
        .help("Show as grid or list")
    }
}

// MARK: List view

/// Column widths shared by the list header and its rows so they always line up.
private enum TableColumn {
    static let index: CGFloat = 26
    static let artwork: CGFloat = 84
    static let kind: CGFloat = 104
    static let category: CGFloat = 92
    static let resolution: CGFloat = 100
    static let length: CGFloat = 60
    static let size: CGFloat = 76
    static let favorite: CGFloat = 28
    static let spacing: CGFloat = 16
    static let rowPadding: CGFloat = 10
}

/// Compact, sortable list of wallpapers — the "spreadsheet" view of the library.
struct WallpaperTable: View {
    let wallpapers: [Wallpaper]
    @Binding var sort: LibrarySort

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            header
            HairlineDivider()
            LazyVStack(spacing: 2) {
                ForEach(Array(wallpapers.enumerated()), id: \.element.id) { index, wallpaper in
                    WallpaperRow(index: index + 1, wallpaper: wallpaper)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: TableColumn.spacing) {
            columnLabel("#").frame(width: TableColumn.index, alignment: .trailing)
            Color.clear.frame(width: TableColumn.artwork, height: 1)
            sortableLabel(String(localized: "Title"), sorts: .name).frame(maxWidth: .infinity, alignment: .leading)
            columnLabel(String(localized: "Type")).frame(width: TableColumn.kind, alignment: .leading)
            columnLabel(String(localized: "Category")).frame(width: TableColumn.category, alignment: .leading)
            columnLabel(String(localized: "Resolution")).frame(width: TableColumn.resolution, alignment: .leading)
            sortableLabel(String(localized: "Length"), sorts: .duration).frame(width: TableColumn.length, alignment: .leading)
            sortableLabel(String(localized: "Size"), sorts: .size).frame(width: TableColumn.size, alignment: .leading)
            Color.clear.frame(width: TableColumn.favorite, height: 1)
        }
        .padding(.horizontal, TableColumn.rowPadding)
    }

    private func columnLabel(_ text: String) -> some View {
        Eyebrow(text: text, color: Theme.Ink.tertiary, isCompact: true)
    }

    /// Clicking a sortable header sorts by it; clicking it again goes back to newest first.
    private func sortableLabel(_ text: String, sorts option: LibrarySort) -> some View {
        Button {
            sort = sort == option ? .recent : option
        } label: {
            HStack(spacing: 4) {
                Eyebrow(text: text, color: sort == option ? Theme.Ink.primary : Theme.Ink.tertiary, isCompact: true)
                if sort == option {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.Ink.primary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort By")
    }
}

private struct WallpaperRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    let wallpaper: Wallpaper
    @State private var hovering = false

    private var isOnDesktop: Bool { !model.engine.displays(showing: wallpaper.id).isEmpty }

    var body: some View {
        HStack(spacing: TableColumn.spacing) {
            Text(verbatim: "\(index)")
                .font(Theme.TypeScale.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.tertiary)
                .frame(width: TableColumn.index, alignment: .trailing)

            ThumbnailView(wallpaper: wallpaper)
                .frame(width: TableColumn.artwork, height: TableColumn.artwork * 10 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs + 2, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.xs + 2, style: .continuous)
                        .strokeBorder(Theme.Surface.artworkEdge)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isOnDesktop { StatusDot(color: Theme.playing) }
                    Text(wallpaper.title)
                        .font(Theme.TypeScale.cardTitle)
                        .foregroundStyle(Theme.Ink.primary)
                        .lineLimit(1)
                }
                if let source = WallpaperDescriptor.source(for: wallpaper) {
                    Text(verbatim: source)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: WallpaperDescriptor.kindSymbol(wallpaper.kind))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Ink.tertiary)
                    .frame(width: 14)
                cell(WallpaperDescriptor.kindLabel(wallpaper))
            }
            .frame(width: TableColumn.kind, alignment: .leading)
            cell(WallpaperCategories.displayName(wallpaper.category)).frame(width: TableColumn.category, alignment: .leading)
            cell(WallpaperDescriptor.resolution(for: wallpaper) ?? "—").frame(width: TableColumn.resolution, alignment: .leading)
            cell(WallpaperDescriptor.length(for: wallpaper) ?? "—").frame(width: TableColumn.length, alignment: .leading)
            cell(WallpaperDescriptor.byteCount(for: wallpaper).map(Format.bytes) ?? "—").frame(width: TableColumn.size, alignment: .leading)

            Button {
                model.library.toggleFavorite(wallpaper.id)
            } label: {
                Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(wallpaper.isFavorite ? Theme.favorite : (hovering ? Theme.Ink.secondary : Theme.Ink.quaternary))
                    .frame(width: TableColumn.favorite, height: TableColumn.favorite)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(wallpaper.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
        }
        .padding(.horizontal, TableColumn.rowPadding)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(hovering ? Theme.Surface.base : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
        .contextMenu { WallpaperMenuItems(wallpaper: wallpaper) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func cell(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Theme.TypeScale.caption)
            .monospacedDigit()
            .foregroundStyle(Theme.Ink.secondary)
            .lineLimit(1)
    }

    private func open() {
        model.router.open(wallpaper.kind == .shader ? .studio(wallpaper.id) : .wallpaper(wallpaper.id))
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    let isSearching: Bool
    let filter: LibraryFilter

    var body: some View {
        EmptyStatePanel(
            symbol: isSearching ? "magnifyingglass" : "square.and.arrow.down.on.square",
            title: title,
            message: message
        ) {
            if !isSearching && filter != .favorites {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Choose Videos…", systemImage: "plus")
                }
                .buttonStyle(.lumenPrimary)
                .controlSize(.large)
            }
        }
    }

    private var title: String {
        if isSearching { return String(localized: "No matches") }
        return filter == .favorites ? String(localized: "No favorites yet") : String(localized: "Drop videos here")
    }

    private var message: String {
        if isSearching { return String(localized: "Try a different name or category.") }
        if filter == .favorites { return String(localized: "Hover a wallpaper and tap the heart to keep it here.") }
        return String(localized: "MP4 and MOV files play on the media engine, so HEVC loops cost almost no power. Lumen keeps its own copy, so you can delete the original.")
    }
}
