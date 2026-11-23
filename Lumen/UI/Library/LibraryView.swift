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

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: LibraryFilter = .all
    @State private var category: String?
    @State private var sort: LibrarySort = .recent

    var body: some View {
        let wallpapers = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                controls
                if !model.library.importJobs.isEmpty { importProgress }
                if wallpapers.isEmpty {
                    EmptyLibraryView(isSearching: !model.router.searchText.isEmpty, filter: filter)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 270, maximum: 440), spacing: 24, alignment: .top)],
                        alignment: .leading,
                        spacing: 30
                    ) {
                        ForEach(wallpapers) { wallpaper in
                            WallpaperCard(wallpaper: wallpaper)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: 1480, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { item in
                    FilterChip(title: item.title, symbol: item.symbol, count: count(for: item), isSelected: filter == item) {
                        filter = item
                    }
                }
                Spacer()
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
            }
            let categories = availableCategories
            if categories.count > 1 {
                HStack(spacing: 8) {
                    FilterChip(title: String(localized: "Any category"), isSelected: category == nil) { category = nil }
                    ForEach(categories, id: \.self) { name in
                        FilterChip(title: WallpaperCategories.displayName(name), isSelected: category == name) {
                            category = category == name ? nil : name
                        }
                    }
                }
            }
        }
    }

    private var importProgress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Importing \(model.library.importJobs.map(\.name).joined(separator: ", "))…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(Theme.surface))
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
        case .size: result.sort { ($0.video?.fileSize ?? 0) > ($1.video?.fileSize ?? 0) }
        }
        return result
    }
}

struct EmptyLibraryView: View {
    @Environment(AppModel.self) private var model
    let isSearching: Bool
    let filter: LibraryFilter

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: isSearching ? "magnifyingglass" : "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(Theme.display(22))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if !isSearching && filter != .favorites {
                Button {
                    model.isImporterPresented = true
                } label: {
                    Label("Choose Videos…", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 7]))
                .foregroundStyle(Color.white.opacity(0.16))
        )
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
