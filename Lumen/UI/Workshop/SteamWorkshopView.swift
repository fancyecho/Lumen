import SwiftUI

/// The live Steam Workshop for Wallpaper Engine, in Lumen's own layout: search, filters, a page of
/// artwork at a time, and downloads that land straight in the library.
struct SteamWorkshopSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("workshopInspector") private var showsInspector = true
    @State private var sheetItem: WorkshopListing?

    var body: some View {
        let browser = model.workshopBrowser
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            controls(browser)
            content(browser)
        }
        .onChange(of: model.router.searchText, initial: true) { _, text in
            browser.query.text = text
        }
        .task { browser.start() }
        .sheet(item: $sheetItem) { item in
            WorkshopItemSheet(item: item)
        }
    }

    // MARK: Controls

    private func controls(_ browser: WorkshopBrowser) -> some View {
        @Bindable var browser = browser
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            searchField
                .padding(.bottom, Theme.Space.xxs)
            HStack(spacing: Theme.Space.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.xs) {
                        FilterChip(title: String(localized: "All"), symbol: "square.grid.2x2", isSelected: browser.query.kind == nil) {
                            browser.query.kind = nil
                        }
                        ForEach(WorkshopCatalog.Kind.allCases) { kind in
                            FilterChip(title: WorkshopText.kind(kind.rawValue), symbol: WorkshopText.kindSymbol(kind.rawValue), isSelected: browser.query.kind == kind) {
                                browser.query.kind = kind
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
                sortMenu(browser)
                WorkshopFiltersMenu(query: $browser.query)
                Button { browser.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.lumenIcon)
                .disabled(browser.isLoading)
                .help("Refresh")
                .accessibilityLabel(Text("Refresh"))
                Button {
                    withAnimation(Theme.Motion.smooth) { showsInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(LumenButtonStyle(kind: showsInspector ? .primary : .secondary, isIconOnly: true))
                .help(showsInspector ? Text("Hide Preview") : Text("Show Preview"))
                .accessibilityLabel(showsInspector ? Text("Hide Preview") : Text("Show Preview"))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.xxs) {
                    FilterChip(title: String(localized: "Any genre"), isSelected: browser.query.genre == nil, style: .quiet) {
                        browser.query.genre = nil
                    }
                    ForEach(WorkshopCatalog.genres, id: \.self) { genre in
                        FilterChip(title: WorkshopText.genre(genre), isSelected: browser.query.genre == genre, style: .quiet) {
                            browser.query.genre = browser.query.genre == genre ? nil : genre
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var searchField: some View {
        @Bindable var router = model.router
        return HStack(spacing: Theme.Space.sm - 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Ink.tertiary)
            TextField("Search the Steam Workshop", text: $router.searchText)
                .textFieldStyle(.plain)
                .font(Theme.TypeScale.body)
                .foregroundStyle(Theme.Ink.primary)
            if !router.searchText.isEmpty {
                Button {
                    router.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .frame(height: 40)
        .frame(maxWidth: 560)
        .background(Capsule().fill(Theme.Surface.base))
        .overlay(Capsule().strokeBorder(Theme.Surface.stroke))
    }

    private func sortMenu(_ browser: WorkshopBrowser) -> some View {
        let searching = !browser.query.text.trimmingCharacters(in: .whitespaces).isEmpty
        return Menu {
            Section("Trending") {
                ForEach(WorkshopCatalog.Period.allCases) { period in
                    Button {
                        browser.query.sort = .trending
                        browser.query.period = period
                    } label: {
                        let title = WorkshopText.period(period)
                        if browser.query.sort == .trending && browser.query.period == period {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
            Divider()
            ForEach([WorkshopCatalog.Sort.topRated, .mostSubscribed, .newest, .updated]) { sort in
                Button {
                    browser.query.sort = sort
                } label: {
                    let title = WorkshopText.sort(sort)
                    if browser.query.sort == sort { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            ChromeLabel {
                Label(searching ? String(localized: "Best Match") : WorkshopText.sortSummary(browser.query), systemImage: "arrow.up.arrow.down")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(searching)
        .help(searching ? Text("Search results are sorted by relevance") : Text("Sort By"))
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ browser: WorkshopBrowser) -> some View {
        if browser.items.isEmpty {
            if let error = browser.error {
                EmptyStatePanel(symbol: "wifi.exclamationmark", title: String(localized: "Couldn't reach the Workshop"), message: error) {
                    Button { browser.refresh() } label: { Label("Try Again", systemImage: "arrow.clockwise") }
                        .buttonStyle(.lumenPrimary)
                        .controlSize(.large)
                }
            } else if browser.isLoading {
                placeholderGrid
            } else {
                EmptyStatePanel(
                    symbol: "magnifyingglass",
                    title: String(localized: "No matches"),
                    message: String(localized: "Try other words or fewer filters.")
                )
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                resultsBar(browser)
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Theme.Space.xxl) {
                    ForEach(browser.items) { item in
                        SteamWorkshopCard(item: item, isSelected: showsInspector && browser.selection?.id == item.id) {
                            open(item, browser: browser)
                        }
                    }
                }
                WorkshopPager(browser: browser)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Theme.Space.md)
            }
        }
    }

    private func open(_ item: WorkshopListing, browser: WorkshopBrowser) {
        if showsInspector {
            browser.selection = item
        } else {
            sheetItem = item
        }
    }

    private func resultsBar(_ browser: WorkshopBrowser) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if let count = browser.resultCount {
                Text("\(count) results")
                    .font(Theme.TypeScale.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            Spacer(minLength: 0)
            WorkshopPager(browser: browser, isCompact: true)
        }
    }

    private static let columns = [GridItem(.adaptive(minimum: 250, maximum: 400), spacing: Theme.Space.xl, alignment: .top)]

    private var placeholderGrid: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: Theme.Space.xxl) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Space.sm - 1) {
                    Theme.Surface.mediaFill
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .artworkFrame(lifts: false)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.Surface.elevated).frame(width: 160, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.Surface.base).frame(width: 100, height: 10)
                }
            }
        }
        .accessibilityLabel(Text("Loading"))
    }
}

// MARK: Pager

/// Numbered pages with previous/next and a jump field. The compact form is just ‹ 3 / 120 ›.
private struct WorkshopPager: View {
    let browser: WorkshopBrowser
    var isCompact = false
    @State private var jump = ""

    private enum Slot: Hashable {
        case page(Int)
        case gap(Int)
    }

    var body: some View {
        HStack(spacing: Theme.Space.xxs + 2) {
            Button(action: browser.previous) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.lumenIcon)
            .disabled(!browser.canGoBack || browser.isLoading)
            .help("Previous Page")
            .accessibilityLabel(Text("Previous Page"))

            if isCompact {
                Text(pageLabel)
                    .font(Theme.TypeScale.label.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
                    .frame(minWidth: 64)
            } else {
                ForEach(slots, id: \.self) { slot in
                    switch slot {
                    case .page(let number): pageButton(number)
                    case .gap: Text(verbatim: "…").font(Theme.TypeScale.label).foregroundStyle(Theme.Ink.tertiary).frame(width: 20)
                    }
                }
            }

            Button(action: browser.next) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.lumenIcon)
            .disabled(!browser.canGoForward || browser.isLoading)
            .help("Next Page")
            .accessibilityLabel(Text("Next Page"))

            if !isCompact, (browser.pageCount ?? 0) > 7 {
                jumpField.padding(.leading, Theme.Space.xs)
            }
        }
        .controlSize(.regular)
    }

    private var pageLabel: String {
        if let count = browser.pageCount { return String(localized: "\(browser.page) / \(count)") }
        return String(localized: "Page \(browser.page)")
    }

    /// 1 … 4 5 [6] 7 8 … 120 — the first, the last and two either side of the current page.
    private var slots: [Slot] {
        let current = browser.page
        guard let count = browser.pageCount, count > 1 else {
            return Array(1...max(current + (browser.hasNext ? 1 : 0), 1)).suffix(5).map(Slot.page)
        }
        let low = max(2, current - 2), high = min(count - 1, current + 2)
        var result: [Slot] = [.page(1)]
        if low <= high {
            if low > 2 { result.append(.gap(0)) }
            result += (low...high).map(Slot.page)
            if high < count - 1 { result.append(.gap(1)) }
        }
        result.append(.page(count))
        return result
    }

    private func pageButton(_ number: Int) -> some View {
        let selected = number == browser.page
        return Button {
            browser.load(page: number)
        } label: {
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.Ink.onLight : Theme.Ink.secondary)
                .padding(.horizontal, 9)
                .frame(minWidth: 28, minHeight: 28)
                .background(Capsule().fill(selected ? Color.white.opacity(0.9) : Theme.Surface.base))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(browser.isLoading)
        .accessibilityLabel(Text("Page \(number)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var jumpField: some View {
        HStack(spacing: 6) {
            Text("Go to")
                .font(Theme.TypeScale.label)
                .foregroundStyle(Theme.Ink.tertiary)
            TextField("", text: $jump)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 44, height: 28)
                .background(Capsule().fill(Theme.Surface.base))
                .overlay(Capsule().strokeBorder(Theme.Surface.stroke))
                .onSubmit {
                    if let number = Int(jump.trimmingCharacters(in: .whitespaces)) { browser.load(page: number) }
                    jump = ""
                }
                .accessibilityLabel(Text("Go to page"))
        }
    }
}

// MARK: Filters

/// Resolution, features and content rating — the filters that don't fit as chips.
private struct WorkshopFiltersMenu: View {
    @Binding var query: WorkshopCatalog.Query

    var body: some View {
        Menu {
            Picker("Resolution", selection: $query.resolution) {
                Text("Any Resolution").tag(String?.none)
                ForEach(WorkshopCatalog.resolutionGroups, id: \.group) { group in
                    Section(WorkshopText.resolutionGroup(group.group)) {
                        ForEach(group.tags, id: \.self) { tag in
                            Text(WorkshopText.resolution(tag)).tag(String?.some(tag))
                        }
                    }
                }
            }
            .pickerStyle(.menu)

            Section("Features") {
                ForEach(WorkshopCatalog.features, id: \.self) { feature in
                    Toggle(WorkshopText.feature(feature), isOn: Binding(
                        get: { query.features.contains(feature) },
                        set: { isOn in
                            if isOn { query.features.insert(feature) } else { query.features.remove(feature) }
                        }
                    ))
                }
            }

            Section("Content Rating") {
                Picker("Content Rating", selection: $query.rating) {
                    Text("Everyone").tag(WorkshopCatalog.Rating.everyone)
                    Text("Everyone and Questionable").tag(WorkshopCatalog.Rating.questionable)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if query.extraFilterCount > 0 {
                Divider()
                Button("Reset Filters") {
                    query.resolution = nil
                    query.features = []
                    query.rating = .everyone
                }
            }
        } label: {
            ChromeLabel {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").imageScale(.small).accessibilityHidden(true)
                    Text("Filters")
                    if query.extraFilterCount > 0 {
                        Text(verbatim: "\(query.extraFilterCount)")
                            .font(.system(size: 10.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.Ink.onLight)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Circle().fill(Color.white.opacity(0.9)))
                    }
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Resolution, features and content rating")
    }
}

// MARK: Card

private struct SteamWorkshopCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: WorkshopListing
    var isSelected = false
    let open: () -> Void
    @State private var still: NSImage?
    @State private var hovering = false
    @State private var animating = false
    @State private var hoverTask: Task<Void, Never>?

    var body: some View {
        let state = WorkshopItemState(item.id, model: model)
        VStack(alignment: .leading, spacing: Theme.Space.sm - 1) {
            Theme.Surface.mediaFill
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let still {
                        Image(nsImage: still)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if animating, let url = item.previewURL {
                        RemoteAnimatedImage(url: url).transition(.opacity)
                    }
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.45), .init(color: .black.opacity(0.6), location: 1)], startPoint: .top, endPoint: .bottom)
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .clipped()
                .overlay(alignment: .topTrailing) {
                    WorkshopStateBadge(state: state).padding(Theme.Space.sm - 2)
                }
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        WorkshopActionButton(item: item, state: state)
                            .padding(Theme.Space.sm - 2)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomTrailing)))
                    }
                }
                .artworkFrame(isHovering: hovering, highlight: isSelected ? Theme.accentInk : nil)

            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: item.title)
                        .font(Theme.TypeScale.cardTitle)
                        .foregroundStyle(Theme.Ink.primary)
                        .lineLimit(1)
                    Text(verbatim: WorkshopText.subtitle(item))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Image(systemName: "heart").font(.system(size: 10, weight: .semibold))
                    Text(verbatim: item.favorites.formatted(.number.notation(.compactName)))
                }
                .font(Theme.TypeScale.label)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.tertiary)
                .help(Text("\(item.favorites) favorites"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover(perform: setHovering)
        .onDisappear {
            hoverTask?.cancel()
            animating = false
        }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: hovering)
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: animating)
        .task(id: item.previewURL) {
            guard let url = item.previewURL else { return }
            let image = await WorkshopPreviews.still(for: url)
            if reduceMotion { still = image } else { withAnimation(Theme.Motion.smooth) { still = image } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open() }
    }

    private func setHovering(_ isHovering: Bool) {
        hovering = isHovering
        hoverTask?.cancel()
        guard isHovering, !reduceMotion else {
            animating = false
            return
        }
        // Same short delay as library cards: animated previews only for a pointer that stays.
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            animating = true
        }
    }
}

// MARK: Preview sidebar

/// The collapsible preview beside the grid: what a click selects, without leaving the page.
struct WorkshopInspector: View {
    @Environment(AppModel.self) private var model
    @AppStorage("workshopInspector") private var showsInspector = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "Preview", color: Theme.Ink.tertiary)
                Spacer()
                Button {
                    withAnimation(Theme.Motion.smooth) { showsInspector = false }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.lumenIcon)
                .controlSize(.small)
                .help("Hide Preview")
                .accessibilityLabel(Text("Hide Preview"))
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.sm)

            if let item = model.workshopBrowser.selection {
                ScrollView {
                    WorkshopDetails(item: item, style: .sidebar)
                        .padding(.horizontal, Theme.Space.lg)
                        .padding(.bottom, Theme.Space.lg)
                }
                .scrollIndicators(.never)
                .id(item.id)
            } else {
                VStack(spacing: Theme.Space.sm) {
                    IconWell(symbol: "hand.point.up.left", size: 48)
                    Text("Select a wallpaper to preview it here.")
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.Ink.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous))
    }
}

/// Preview, title, facts, actions, tags and description — shared by the sidebar and the sheet.
private struct WorkshopDetails: View {
    enum Style { case sidebar, sheet }

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let item: WorkshopListing
    let style: Style
    var onOpen: () -> Void = {}
    @State private var still: NSImage?

    var body: some View {
        let state = WorkshopItemState(item.id, model: model)
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if style == .sidebar { preview }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Eyebrow(text: [item.kind.map(WorkshopText.kind), item.genres.first.map(WorkshopText.genre)].compactMap { $0 }.joined(separator: " · "))
                Text(verbatim: item.title)
                    .font(style == .sidebar ? .system(size: 18, weight: .bold) : Theme.TypeScale.compactArtworkTitle)
                    .tracking(-0.3)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let stars = item.stars, stars > 0 {
                    StarRating(stars: stars, votes: item.votes)
                }
            }

            facts

            HStack(spacing: Theme.Space.xs) {
                WorkshopActionButton(item: item, state: state, isWide: style == .sidebar, onOpen: onOpen)
                if style == .sidebar {
                    Button(action: viewOnSteam) { Image(systemName: "arrow.up.right") }
                        .buttonStyle(.lumenIcon)
                        .help("View on Steam")
                        .accessibilityLabel(Text("View on Steam"))
                } else {
                    Button(action: viewOnSteam) { Label("View on Steam", systemImage: "arrow.up.right") }
                        .buttonStyle(.lumenSecondary)
                }
            }
            .controlSize(.large)

            let tags = item.genres.map(WorkshopText.genre) + item.features.map(WorkshopText.feature)
            if !tags.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(verbatim: tag)
                            .font(Theme.TypeScale.label)
                            .foregroundStyle(Theme.Ink.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Theme.Surface.elevated))
                    }
                }
            }

            if !item.summary.isEmpty {
                Text(verbatim: item.summary)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(style == .sheet ? 5 : nil)
                    .textSelection(.enabled)
            }
        }
        .task(id: item.previewURL) {
            guard style == .sidebar, let url = item.previewURL else { return }
            still = await WorkshopPreviews.still(for: url, maxPixel: 480)
        }
    }

    private func viewOnSteam() {
        if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(item.id)") { openURL(url) }
    }

    /// Small GIF previews are shown whole over a blurred fill of themselves, never blown up edge to edge.
    private var preview: some View {
        ZStack {
            Theme.Surface.mediaFill
            if let still {
                Image(nsImage: still)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 24)
                    .opacity(0.6)
            }
            if let url = item.previewURL {
                RemoteAnimatedImage(url: url, fills: false)
            }
        }
        .aspectRatio(16.0 / 11.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.Surface.artworkEdge))
    }

    private var facts: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Space.lg, verticalSpacing: Theme.Space.sm) {
            GridRow {
                fact(item.subscriptions.formatted(.number.notation(.compactName)), String(localized: "Subscribers"))
                fact(item.favorites.formatted(.number.notation(.compactName)), String(localized: "Favorited"))
            }
            GridRow {
                fact(item.fileSize > 0 ? Format.bytes(item.fileSize) : "—", String(localized: "Size"))
                fact(item.resolution.map(WorkshopText.resolution) ?? "—", String(localized: "Resolution"))
            }
            if let updated = item.updated {
                GridRow {
                    fact(updated.formatted(date: .abbreviated, time: .omitted), String(localized: "Updated"))
                        .gridCellColumns(2)
                }
            }
        }
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.primary)
                .lineLimit(1)
            Text(label)
                .font(Theme.TypeScale.label)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }
}

private struct StarRating: View {
    let stars: Int
    let votes: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < stars ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(index < stars ? Theme.Ink.primary : Theme.Ink.quaternary)
            }
            if let votes, votes > 0 {
                Text(verbatim: votes.formatted(.number.notation(.compactName)))
                    .font(Theme.TypeScale.label)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.tertiary)
                    .padding(.leading, 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(stars) of 5 stars"))
    }
}

// MARK: Detail sheet

/// Everything about one Workshop item, when the preview sidebar is hidden.
struct WorkshopItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: WorkshopListing
    @State private var still: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                WorkshopDetails(item: item, style: .sheet, onOpen: { dismiss() })
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.lumenSecondary)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(Theme.Space.xl)
        }
        .frame(width: 620)
        .background(Theme.Surface.canvas)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task(id: item.previewURL) {
            guard let url = item.previewURL else { return }
            still = await WorkshopPreviews.still(for: url, maxPixel: 480)
        }
    }

    private var hero: some View {
        ZStack {
            Theme.Surface.mediaFill
            if let still {
                Image(nsImage: still)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .opacity(0.55)
                    .clipped()
            }
            if let url = item.previewURL {
                RemoteAnimatedImage(url: url, fills: false)
                    .padding(.vertical, Theme.Space.lg)
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
            }
        }
        .frame(height: 300)
        .clipped()
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, Theme.Surface.canvas], startPoint: .top, endPoint: .bottom)
                .frame(height: 60)
                .allowsHitTesting(false)
        }
    }
}

// MARK: Shared pieces

/// Where a Workshop item stands for this person.
enum WorkshopItemState: Equatable {
    case available
    case queued
    case downloading(Double?)
    case importing
    case inLibrary(UUID)
    case failed(String)

    @MainActor
    init(_ id: String, model: AppModel) {
        if let existing = model.library.wallpaper(workshopID: id) {
            self = .inLibrary(existing.id)
            return
        }
        switch model.steam.downloads.first(where: { $0.id == id })?.state {
        case .queued, .preparing: self = .queued
        case .downloading(let progress): self = .downloading(progress)
        case .importing: self = .importing
        case .done(let id?): self = .inLibrary(id)
        case .failed(let message): self = .failed(message)
        case .done(nil), nil: self = .available
        }
    }
}

private struct WorkshopStateBadge: View {
    let state: WorkshopItemState

    var body: some View {
        switch state {
        case .inLibrary:
            ArtBadge(text: String(localized: "In Library"), symbol: "checkmark")
        case .queued:
            ArtBadge(text: String(localized: "Queued"), symbol: "clock")
        case .downloading(let progress):
            ArtBadge(text: progress.map { "\(Int($0 * 100))%" } ?? String(localized: "Downloading"), symbol: "arrow.down")
        case .importing:
            ArtBadge(text: String(localized: "Adding…"), symbol: "tray.and.arrow.down")
        case .failed:
            ArtBadge(text: String(localized: "Failed"), symbol: "exclamationmark.triangle")
        case .available:
            EmptyView()
        }
    }
}

/// Download / progress / open, depending on the item's state.
private struct WorkshopActionButton: View {
    @Environment(AppModel.self) private var model
    let item: WorkshopListing
    let state: WorkshopItemState
    /// Stretches to the available width (sidebar).
    var isWide = false
    var onOpen: () -> Void = {}

    var body: some View {
        switch state {
        case .inLibrary(let id):
            Button {
                onOpen()
                model.router.open(.wallpaper(id))
            } label: {
                Label("Open", systemImage: "arrow.right").frame(maxWidth: isWide ? .infinity : nil)
            }
            .buttonStyle(.lumenSecondary)
        case .queued, .downloading, .importing:
            ChromeLabel {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(progressText)
                }
                .frame(maxWidth: isWide ? .infinity : nil)
            }
        case .available, .failed:
            Button(action: download) {
                Label(state == .available ? "Download" : "Try Again", systemImage: "arrow.down")
                    .frame(maxWidth: isWide ? .infinity : nil)
            }
            .buttonStyle(.lumenPrimary)
            .help(item.fileSize > 0 ? Text(Format.bytes(item.fileSize)) : Text("Download"))
        }
    }

    private var progressText: String {
        switch state {
        case .downloading(let progress?): "\(Int(progress * 100))%"
        case .downloading(nil): String(localized: "Downloading")
        case .importing: String(localized: "Adding…")
        default: String(localized: "Queued")
        }
    }

    private func download() {
        guard model.steam.isSignedIn else {
            model.isSteamPanelPresented = true
            model.showToast(String(localized: "Sign in to Steam to download Workshop items"), symbol: "person.crop.circle")
            return
        }
        model.steam.download(item.id)
    }
}

/// Signed-in account or a sign-in button, for the Workshop header.
struct SteamAccountControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let steam = model.steam
        if steam.isSignedIn, let account = steam.account {
            Button { model.isSteamPanelPresented = true } label: {
                Label(account, systemImage: "person.crop.circle")
            }
            .buttonStyle(.lumenSecondary)
            .help("Steam account and downloads")
        } else {
            Button { model.isSteamPanelPresented = true } label: {
                Label("Sign In to Steam", systemImage: "person.crop.circle")
            }
            .buttonStyle(.lumenPrimary)
            .help("Browsing works without an account; downloading uses your own Steam sign-in.")
        }
    }
}

// MARK: Downloads in the toolbar

/// Toolbar button with a progress ring for Workshop downloads; opens the download list.
struct DownloadsToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var showsList = false

    var body: some View {
        let downloads = model.steam.downloads
        let active = downloads.filter { !$0.isFinished }
        let failed = downloads.contains { if case .failed = $0.state { true } else { false } }
        Button {
            showsList.toggle()
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    if active.isEmpty {
                        Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(failed ? Theme.paused : Theme.playing)
                    } else if let progress = Self.progress(of: active) {
                        Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: max(0.03, progress))
                            .stroke(Theme.Ink.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .frame(width: 15, height: 15)
                Text(verbatim: active.isEmpty ? "\(downloads.count)" : "\(active.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
        }
        .help(active.isEmpty ? Text("Downloads") : Text("Downloading \(active.count)"))
        .accessibilityLabel(active.isEmpty ? Text("Downloads") : Text("Downloading \(active.count)"))
        .popover(isPresented: $showsList, arrowEdge: .bottom) {
            DownloadsPopover { showsList = false }
                .environment(model)
        }
    }

    /// Average progress of the running downloads; queued ones count as zero.
    private static func progress(of downloads: [SteamWorkshop.Download]) -> Double? {
        let values = downloads.map { download -> Double? in
            switch download.state {
            case .downloading(let progress): progress
            case .importing: 1
            case .queued, .preparing: 0
            default: nil
            }
        }
        guard values.contains(where: { ($0 ?? 0) > 0 }) else { return nil }
        return values.map { $0 ?? 0 }.reduce(0, +) / Double(max(values.count, 1))
    }
}

private struct DownloadsPopover: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        let steam = model.steam
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text("Downloads")
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
                Spacer()
                if steam.downloads.contains(where: \.isFinished) {
                    Button("Clear Finished") { steam.clearFinished() }
                        .buttonStyle(.lumenSecondary)
                        .controlSize(.small)
                }
            }
            if steam.downloads.isEmpty {
                Text("Nothing downloading.")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
                    .padding(.vertical, Theme.Space.sm)
            } else if steam.downloads.count > 5 {
                ScrollView { rows(steam) }
                    .frame(height: 300)
            } else {
                rows(steam)
            }
            HairlineDivider()
            Button {
                close()
                model.isSteamPanelPresented = true
            } label: {
                Label("Steam account and downloads", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.lumenSecondary)
        }
        .padding(Theme.Space.md)
        .frame(width: 340)
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
    }

    private func rows(_ steam: SteamWorkshop) -> some View {
        VStack(spacing: Theme.Space.xxs) {
            ForEach(steam.downloads) { download in
                DownloadListRow(download: download) { id in
                    close()
                    model.router.open(.wallpaper(id))
                }
            }
        }
    }
}

private struct DownloadListRow: View {
    let download: SteamWorkshop.Download
    let open: (UUID) -> Void
    @State private var still: NSImage?

    var body: some View {
        HStack(spacing: Theme.Space.sm - 2) {
            Theme.Surface.mediaFill
                .overlay {
                    if let still {
                        Image(nsImage: still).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 52, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous).strokeBorder(Theme.Surface.artworkEdge))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: download.title)
                    .font(Theme.TypeScale.bodyMedium)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(1)
                status
            }
            Spacer(minLength: Theme.Space.xs)
            if case .done(let id?) = download.state {
                Button("Show") { open(id) }
                    .buttonStyle(.lumenSecondary)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .task(id: download.previewURL) {
            guard let url = download.previewURL else { return }
            still = await WorkshopPreviews.still(for: url, maxPixel: 160)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch download.state {
        case .queued, .preparing:
            caption(String(localized: "Queued"))
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress).controlSize(.small).tint(Theme.Ink.primary)
            } else {
                caption(String(localized: "Downloading"))
            }
        case .importing:
            caption(String(localized: "Adding…"))
        case .done:
            caption(String(localized: "In Library"))
        case .failed(let message):
            Text(message)
                .font(Theme.TypeScale.label)
                .foregroundStyle(Theme.paused)
                .lineLimit(2)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.TypeScale.label)
            .foregroundStyle(Theme.Ink.secondary)
    }
}

// MARK: Labels

/// Localised labels for Workshop tags and sorts. Tags arrive in English from Steam.
enum WorkshopText {
    static func kind(_ tag: String) -> String {
        switch tag {
        case "Scene": String(localized: "Scene")
        case "Video": String(localized: "Video")
        case "Web": String(localized: "Web")
        case "Preset": String(localized: "Preset")
        default: tag
        }
    }

    static func kindSymbol(_ tag: String) -> String {
        switch tag {
        case "Scene": "square.3.layers.3d"
        case "Video": "film"
        case "Web": "globe"
        default: "questionmark"
        }
    }

    static func genre(_ tag: String) -> String {
        switch tag {
        case "Abstract": String(localized: "Abstract")
        case "Animal": String(localized: "Animals")
        case "Anime": String(localized: "Anime")
        case "Cartoon": String(localized: "Cartoon")
        case "CGI": "CGI"
        case "Cyberpunk": String(localized: "Cyberpunk")
        case "Fantasy": String(localized: "Fantasy")
        case "Game": String(localized: "Games")
        case "Girls": String(localized: "Girls")
        case "Guys": String(localized: "Guys")
        case "Landscape": String(localized: "Landscape")
        case "Medieval": String(localized: "Medieval")
        case "Memes": String(localized: "Memes")
        case "MMD": "MMD"
        case "Music": String(localized: "Music")
        case "Nature": String(localized: "Nature")
        case "Pixel art": String(localized: "Pixel Art")
        case "Relaxing": String(localized: "Relaxing")
        case "Retro": String(localized: "Retro")
        case "Sci-Fi": String(localized: "Sci-Fi")
        case "Sports": String(localized: "Sports")
        case "Technology": String(localized: "Technology")
        case "Television": String(localized: "TV & Film")
        case "Vehicle": String(localized: "Vehicles")
        case "Unspecified": String(localized: "Unspecified")
        default: tag
        }
    }

    static func feature(_ tag: String) -> String {
        switch tag {
        case "Approved": String(localized: "Approved")
        case "Audio responsive": String(localized: "Audio Responsive")
        case "Customizable": String(localized: "Customizable")
        case "Media Integration": String(localized: "Media Integration")
        case "Video Texture": String(localized: "Video Texture")
        case "Puppet Warp": String(localized: "Puppet Warp")
        case "User Shortcut": String(localized: "User Shortcut")
        default: tag
        }
    }

    static func resolutionGroup(_ group: String) -> String {
        switch group {
        case "Standard": String(localized: "Standard")
        case "Ultrawide": String(localized: "Ultrawide")
        case "Dual": String(localized: "Dual Monitor")
        case "Triple": String(localized: "Triple Monitor")
        case "Portrait": String(localized: "Portrait")
        default: String(localized: "Other")
        }
    }

    /// "Ultrawide 3440 x 1440" → "3440×1440"; the special cases get words.
    static func resolution(_ tag: String) -> String {
        switch tag {
        case "Dynamic resolution": return String(localized: "Dynamic")
        case "Other resolution": return String(localized: "Other")
        case "3840 x 2160": return "3840×2160 (4K)"
        default:
            let parts = tag.split(separator: " ").filter { $0.first?.isNumber == true || $0 == "x" }
            return parts.joined(separator: " ").replacingOccurrences(of: " x ", with: "×")
        }
    }

    static func period(_ period: WorkshopCatalog.Period) -> String {
        switch period {
        case .day: String(localized: "Today")
        case .week: String(localized: "This Week")
        case .month: String(localized: "This Month")
        case .quarter: String(localized: "Last 3 Months")
        case .halfYear: String(localized: "Last 6 Months")
        case .year: String(localized: "This Year")
        case .allTime: String(localized: "All Time")
        }
    }

    static func sort(_ sort: WorkshopCatalog.Sort) -> String {
        switch sort {
        case .trending: String(localized: "Trending")
        case .topRated: String(localized: "Top Rated")
        case .mostSubscribed: String(localized: "Most Subscribed")
        case .newest: String(localized: "Newest")
        case .updated: String(localized: "Recently Updated")
        }
    }

    static func sortSummary(_ query: WorkshopCatalog.Query) -> String {
        query.sort == .trending ? "\(sort(.trending)) · \(period(query.period))" : sort(query.sort)
    }

    /// "Scene · Anime · 63 MB" — the second line under a card title.
    static func subtitle(_ item: WorkshopListing) -> String {
        var parts: [String] = []
        if let kind = item.kind { parts.append(self.kind(kind)) }
        if let genre = item.genres.first { parts.append(self.genre(genre)) }
        if item.fileSize > 0 { parts.append(Format.bytes(item.fileSize)) }
        return parts.joined(separator: " · ")
    }
}
