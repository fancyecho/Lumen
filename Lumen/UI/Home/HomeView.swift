import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 1280

    var body: some View {
        let inset = Theme.Layout.inset(for: width)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                HomeStage()
                    .padding(.horizontal, inset)

                if !recent.isEmpty {
                    Shelf(title: "Recently added", wallpapers: recent, inset: inset) {
                        SectionLink(title: "See All") { model.router.show(.library) }
                    }
                }
                if !favorites.isEmpty {
                    Shelf(title: "Favorites", wallpapers: favorites, inset: inset) { EmptyView() }
                }
                Shelf(
                    title: "Rendered live",
                    subtitle: String(localized: "Drawn on the GPU within a fixed pixel budget. Tune colours and motion in Studio."),
                    wallpapers: model.library.builtins,
                    inset: inset
                ) {
                    SectionLink(title: "Open Studio") { model.router.show(.studio) }
                }

                SmartPausePanel()
                    .padding(.horizontal, inset)
            }
            .padding(.top, Theme.Space.md)
            .padding(.bottom, Theme.Space.xxl + Theme.Space.xs)
        }
        .scrollIndicators(.automatic)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var recent: [Wallpaper] { Array(model.library.items.prefix(10)) }
    private var favorites: [Wallpaper] { Array(model.library.all.filter(\.isFavorite).prefix(10)) }
}

// MARK: Stage

/// The top of Home: what's on the desktop, framed like a print with its caption beside it.
private struct HomeStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusedDisplayID: String?
    @State private var hovering = false
    @State private var previewing = false
    @State private var hoverTask: Task<Void, Never>?

    private var displays: [WallpaperEngine.Display] { model.engine.displays }

    private var display: WallpaperEngine.Display? {
        displays.first { $0.id == focusedDisplayID }
            ?? displays.first { $0.wallpaperID != nil && $0.isPrimary }
            ?? displays.first { $0.wallpaperID != nil }
            ?? displays.first
    }

    private var wallpaper: Wallpaper? {
        display?.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.xxl + Theme.Space.xs) {
            artwork
                .frame(minWidth: 460, maxWidth: 860)
                .layoutPriority(1)
            caption
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 420, alignment: .leading)
            Spacer(minLength: 0)
        }
        .onDisappear {
            hoverTask?.cancel()
            previewing = false
        }
    }

    // MARK: Artwork

    private var artwork: some View {
        ZStack {
            if let wallpaper {
                ThumbnailView(wallpaper: wallpaper)
                if previewing {
                    LiveWallpaperPreview(wallpaper: wallpaper)
                        .transition(.opacity)
                }
            } else {
                emptyArtwork
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if let display {
                DisplayStatusPill(display: display).padding(Theme.Space.md)
            }
        }
        .artworkFrame(radius: Theme.Radius.xxl, isHovering: hovering, lifts: false)
        .contentShape(Rectangle())
        .onHover(perform: setHovering)
        .onTapGesture(perform: openCurrent)
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: previewing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(wallpaper.map { Text($0.title) } ?? Text("Showing the system wallpaper"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { openCurrent() }
    }

    private var emptyArtwork: some View {
        ZStack {
            if let featured = model.library.builtins.first {
                ThumbnailView(wallpaper: featured).opacity(0.5)
            } else {
                Theme.Surface.mediaFill
            }
            VStack(spacing: Theme.Space.sm) {
                IconWell(symbol: "sparkles.rectangle.stack", size: 52)
                Text("Showing the system wallpaper")
                    .font(Theme.TypeScale.bodyMedium)
                    .foregroundStyle(Theme.Ink.primary)
            }
        }
    }

    // MARK: Caption

    private var caption: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Eyebrow(text: greeting)
            if let wallpaper {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(wallpaper.title)
                        .font(Theme.TypeScale.artworkTitle)
                        .tracking(-0.4)
                        .foregroundStyle(Theme.Ink.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(WallpaperDescriptor.subtitle(for: wallpaper))
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.Ink.secondary)
                        .lineLimit(1)
                }
                statusLine
                actions
            } else {
                Text(verbatim: "Your desktop,\nin motion.")
                    .font(Theme.TypeScale.heroTitle)
                    .tracking(-0.5)
                    .foregroundStyle(Theme.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.library.items.isEmpty
                     ? String(localized: "Drop a video anywhere in this window to start")
                     : String(localized: "Pick one from the library, or let Lumen choose for you."))
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                emptyActions
            }
            if displays.count > 1 { displaySwitcher }
            HairlineDivider().padding(.vertical, Theme.Space.xxs)
            stats
        }
    }

    private var greeting: String {
        let weekday = Date.now.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide))
        return "\(Format.greeting()) · \(weekday)"
    }

    @ViewBuilder
    private var statusLine: some View {
        if let display {
            HStack(spacing: 7) {
                if let reason = display.pauseReason {
                    Image(systemName: reason.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(reason.savesEnergy ? Theme.saving : Theme.paused)
                    Text(reason.title)
                } else {
                    StatusDot(color: Theme.playing, pulsing: true)
                    Text("Playing on \(display.name)")
                }
            }
            .font(Theme.TypeScale.bodyMedium)
            .foregroundStyle(Theme.Ink.secondary)
            .lineLimit(1)
        }
    }

    private var actions: some View {
        let engine = model.engine
        return HStack(spacing: Theme.Space.xs) {
            Button(action: openCurrent) {
                Label("Customize", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.lumenPrimary)

            Button { model.surpriseMe(on: display) } label: {
                Label("Surprise Me", systemImage: "shuffle")
            }
            .buttonStyle(.lumenSecondary)
            .disabled(model.library.all.count < 2)

            Button { engine.toggleUserPause() } label: {
                Image(systemName: engine.userPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.lumenIcon)
            .help(engine.userPaused ? Text("Resume all displays") : Text("Pause all displays"))
            .accessibilityLabel(engine.userPaused ? Text("Resume all displays") : Text("Pause all displays"))

            Menu {
                Button("Choose Another…") { model.router.show(.library) }
                if let display {
                    Button("Use System Wallpaper") { model.clearWallpaper(on: .display(display.id)) }
                }
            } label: {
                ChromeLabel(isIconOnly: true) { Image(systemName: "ellipsis") }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .fixedSize()
        .controlSize(.large)
    }

    private var emptyActions: some View {
        HStack(spacing: Theme.Space.xs) {
            Button { model.router.show(.library) } label: {
                Label("Choose Wallpaper", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.lumenPrimary)
            Button { model.surpriseMe(on: display) } label: {
                Label("Surprise Me", systemImage: "shuffle")
            }
            .buttonStyle(.lumenSecondary)
            .disabled(model.library.all.isEmpty)
        }
        .fixedSize()
        .controlSize(.large)
    }

    private var displaySwitcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.xxs) {
                ForEach(displays) { item in
                    FilterChip(
                        title: item.name,
                        symbol: item.isBuiltin ? "laptopcomputer" : "display",
                        isSelected: item.id == display?.id,
                        style: .quiet
                    ) {
                        withAnimation(reduceMotion ? nil : Theme.Motion.snappy) { focusedDisplayID = item.id }
                    }
                }
            }
        }
    }

    private var stats: some View {
        let engine = model.engine
        let playing = engine.displays.filter(\.isPlaying).count
        return HStack(alignment: .top, spacing: Theme.Space.xl) {
            StageStat(value: "\(model.library.all.count)", label: "Library")
            StageStat(value: "\(playing)/\(engine.displays.count)", label: "Live now")
            StageStat(value: Format.bytes(model.library.totalDiskUsage), label: "On disk")
        }
    }

    // MARK: Actions

    private func openCurrent() {
        if let wallpaper {
            model.router.open(wallpaper.kind == .shader ? .studio(wallpaper.id) : .wallpaper(wallpaper.id))
        } else {
            model.router.show(.library)
        }
    }

    private func setHovering(_ isHovering: Bool) {
        hovering = isHovering
        hoverTask?.cancel()
        guard isHovering, wallpaper != nil else {
            previewing = false
            return
        }
        // Same short delay as gallery cards: no decoder spins up for a pointer just passing over.
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            previewing = true
        }
    }
}

/// Big number over a small wide label — a quiet summary under the stage caption.
private struct StageStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: value)
                .font(Theme.display(17, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.primary)
                .lineLimit(1)
            Eyebrow(text: label, color: Theme.Ink.tertiary)
        }
    }
}

// MARK: Shelf

/// A titled horizontal row of cards that scrolls out to the window edge while starting on the page margin.
private struct Shelf<Accessory: View>: View {
    let title: String
    var subtitle: String?
    let wallpapers: [Wallpaper]
    let inset: CGFloat
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle(title: title, subtitle: subtitle) { accessory }
                .padding(.horizontal, inset)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                    ForEach(wallpapers) { wallpaper in
                        WallpaperCard(wallpaper: wallpaper)
                            .frame(width: Theme.Layout.shelfCardWidth)
                    }
                }
                .padding(.vertical, Theme.Space.md)
            }
            .contentMargins(.horizontal, inset, for: .scrollContent)
            .scrollIndicators(.never)
            .scrollClipDisabled()
            .padding(.vertical, -Theme.Space.md)
        }
    }
}

// MARK: Smart Pause

/// Live view of the automatic pause rules and what they're doing right now.
struct SmartPausePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let system = model.system
        let coveredCount = model.engine.displays.filter { $0.pauseReason == .covered }.count
        let liveCoverage = model.engine.displays.first(where: \.isPrimary)?.coverage
            ?? model.engine.displays.compactMap(\.coverage).first

        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle(
                "Smart pause",
                subtitle: String(localized: "Lumen stops decoding whenever nobody can see the wallpaper — and when your Mac needs the energy more.")
            )
            // Exactly four equal columns: an adaptive grid left a fifth, empty slot on wide windows.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.md), count: 4),
                spacing: Theme.Space.md
            ) {
                PolicyTile(
                    symbol: "macwindow", title: String(localized: "When covered by windows"),
                    status: coveredStatus(count: coveredCount, coverage: liveCoverage, threshold: settings.coverageThreshold),
                    isTriggered: coveredCount > 0, isOn: $settings.pauseWhenCovered
                )
                PolicyTile(
                    symbol: "battery.50percent", title: String(localized: "When on battery"),
                    status: system.onBattery ? String(localized: "Running on battery") : String(localized: "On power adapter"),
                    isTriggered: system.onBattery && settings.pauseOnBattery, isOn: $settings.pauseOnBattery
                )
                PolicyTile(
                    symbol: "leaf.fill", title: String(localized: "In Low Power Mode"),
                    status: system.lowPowerMode ? String(localized: "On") : String(localized: "Off"),
                    isTriggered: system.lowPowerMode && settings.pauseOnLowPower, isOn: $settings.pauseOnLowPower
                )
                PolicyTile(
                    symbol: "thermometer.medium", title: String(localized: "When the Mac runs hot"),
                    status: system.thermalDescription,
                    isTriggered: system.thermalPressureHigh && settings.pauseOnThermalPressure, isOn: $settings.pauseOnThermalPressure
                )
            }
        }
    }
}

extension SmartPausePanel {
    fileprivate func coveredStatus(count: Int, coverage: Double?, threshold: Double) -> String {
        if count > 0 { return String(localized: "Paused on \(count) displays") }
        guard let coverage else { return String(localized: "Watching") }
        let covered = Int((coverage * 100).rounded())
        let limit = Int((threshold * 100).rounded())
        return String(localized: "\(covered)% covered · pauses at \(limit)%")
    }
}

/// One automatic pause rule: icon and switch on top, rule and live status below.
/// Fixed height and single-line text, so a row of tiles always lines up whatever the language.
struct PolicyTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: String
    let title: String
    let status: String
    let isTriggered: Bool
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                IconWell(symbol: symbol, tint: isTriggered ? Theme.saving : .white, size: 32)
                Spacer(minLength: Theme.Space.xs)
                Toggle(title, isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            Spacer(minLength: Theme.Space.sm)
            Text(title)
                .font(Theme.TypeScale.bodyMedium.weight(.semibold))
                .foregroundStyle(Theme.Ink.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            HStack(spacing: 5) {
                if isTriggered { StatusDot(color: Theme.saving) }
                Text(status)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.TypeScale.caption)
            .foregroundStyle(isTriggered ? Theme.saving : Theme.Ink.secondary)
            .padding(.top, 3)
            .help(status)
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
        .lumenSurface(
            radius: Theme.Radius.lg,
            stroke: isTriggered ? Theme.saving.opacity(0.35) : Theme.Surface.stroke
        )
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: isTriggered)
        .accessibilityElement(children: .combine)
    }
}
