import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                hero
                displaysSection
                if !recent.isEmpty { recentShelf }
                generativeShelf
                if model.engine.displays.count != 1 { SmartPausePanel() }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl + Theme.Space.xs)
            .frame(maxWidth: Theme.Layout.galleryMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }

    private var recent: [Wallpaper] { Array(model.library.items.prefix(8)) }

    private var hero: some View {
        let engine = model.engine
        let playing = engine.displays.filter(\.isPlaying).count
        let libraryCount = model.library.items.count
        return VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
            Text(verbatim: "\(Format.greeting()) · \(Date.now.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide)))".uppercased())
                .font(Theme.TypeScale.eyebrow)
                .tracking(1.8)
                .foregroundStyle(Theme.accent)
            Text(verbatim: "Your desktop,\nin motion.")
                .font(Theme.TypeScale.heroTitle)
                .lineSpacing(-4)
            Text(heroSubtitle(playing: playing, libraryCount: libraryCount))
                .font(Theme.TypeScale.body)
                .foregroundStyle(.secondary)
        }
    }

    private func heroSubtitle(playing: Int, libraryCount: Int) -> String {
        let displays = model.engine.displays.count
        let library = libraryCount == 0
            ? String(localized: "Drop a video anywhere in this window to start")
            : String(localized: "\(libraryCount) videos in your library")
        let status: String
        if displays > 1 {
            status = String(localized: "\(playing) of \(displays) displays playing")
        } else if playing == 1 {
            status = String(localized: "Playing now")
        } else if let only = model.engine.displays.first, only.wallpaperID != nil, let reason = only.pauseReason {
            status = reason.title
        } else {
            status = String(localized: "No live wallpaper yet")
        }
        return "\(library) · \(status)"
    }

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle("On your displays", subtitle: String(localized: "Each display can play its own wallpaper."))
            if let only = model.engine.displays.first, model.engine.displays.count == 1 {
                // One display: pair the display card cleanly beside Smart pause.
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    DisplayCard(display: only)
                        .frame(minWidth: 380, maxWidth: 540)
                    SmartPausePanel(isCompact: true)
                        .frame(minWidth: 320, maxWidth: .infinity)
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 340, maximum: 580), spacing: Theme.Space.lg, alignment: .top)],
                    alignment: .leading,
                    spacing: Theme.Space.lg
                ) {
                    ForEach(model.engine.displays) { display in
                        DisplayCard(display: display)
                    }
                }
            }
        }
    }

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle(title: "Recently added") {
                Button("See all") { model.router.show(.library) }
                    .buttonStyle(.link)
                    .font(Theme.TypeScale.bodyMedium)
            }
            shelf(recent)
        }
    }

    private var generativeShelf: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle(title: "Generative", subtitle: String(localized: "Rendered live on the GPU. Tune colours and motion in Studio.")) {
                Button("Open Studio") { model.router.show(.studio) }
                    .buttonStyle(.link)
                    .font(Theme.TypeScale.bodyMedium)
            }
            shelf(model.library.builtins)
        }
    }

    private func shelf(_ wallpapers: [Wallpaper]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Theme.Space.lg) {
                ForEach(wallpapers) { wallpaper in
                    WallpaperCard(wallpaper: wallpaper)
                        .frame(width: 280)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, Theme.Space.xxs)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
        .padding(.vertical, -14)
    }
}

struct DisplayCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let display: WallpaperEngine.Display
    @State private var hovering = false

    private var wallpaper: Wallpaper? {
        display.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
    }

    private func openDisplayed() {
        if let wallpaper {
            model.router.open(wallpaper.kind == .shader ? .studio(wallpaper.id) : .wallpaper(wallpaper.id))
        } else {
            model.router.show(.library)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ZStack {
                if let wallpaper {
                    ThumbnailView(wallpaper: wallpaper)
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.45),
                            .init(color: .black.opacity(0.72), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)
                } else {
                    emptyArtwork
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(alignment: .topLeading) { DisplayStatusPill(display: display).padding(Theme.Space.sm) }
            .overlay(alignment: .bottomLeading) {
                if let wallpaper {
                    Text(wallpaper.title)
                        .font(Theme.TypeScale.displayCardTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                        .padding(Theme.Space.md)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                    .strokeBorder(hovering ? Theme.Surface.strokeHover : Theme.Surface.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.48 : 0.34), radius: hovering ? 24 : 16, y: hovering ? 12 : 8)
            .onHover { hovering = $0 }
            .onTapGesture(perform: openDisplayed)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openDisplayed() }

            HStack(spacing: Theme.Space.sm) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name).font(Theme.TypeScale.cardTitle)
                    Text(verbatim: Format.resolution(Int(display.pixelSize.width), Int(display.pixelSize.height)))
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: Theme.Space.xs)
                GlassEffectContainer(spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        if wallpaper != nil {
                            Button("Change") { model.router.show(.library) }
                                .buttonStyle(.glass)
                            Button {
                                model.clearWallpaper(on: .display(display.id))
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Go back to the system wallpaper on this display")
                        } else {
                            Button("Choose Wallpaper") { model.router.show(.library) }
                                .buttonStyle(.glass)
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
    }

    private var emptyArtwork: some View {
        ZStack {
            Theme.Surface.mediaFill
            VStack(spacing: Theme.Space.sm - 2) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Showing the system wallpaper")
                    .font(Theme.TypeScale.bodyMedium)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .foregroundStyle(Theme.Surface.strokeHover)
        )
    }
}

/// Live view of the automatic pause rules and what they're doing right now.
struct SmartPausePanel: View {
    @Environment(AppModel.self) private var model
    /// Sits beside a display card: smaller title, tiles stack in one or two columns.
    var isCompact = false

    var body: some View {
        @Bindable var settings = model.settings
        let system = model.system
        let coveredCount = model.engine.displays.filter { $0.pauseReason == .covered }.count
        let liveCoverage = model.engine.displays.first(where: \.isPrimary)?.coverage
            ?? model.engine.displays.compactMap(\.coverage).first

        VStack(alignment: .leading, spacing: isCompact ? Theme.Space.sm : Theme.Space.md) {
            if isCompact {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(verbatim: "Smart pause").font(Theme.TypeScale.displayCardTitle)
                    Text("Lumen stops decoding whenever nobody can see the wallpaper — and when your Mac needs the energy more.")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SectionTitle("Smart pause", subtitle: String(localized: "Lumen stops decoding whenever nobody can see the wallpaper — and when your Mac needs the energy more."))
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: isCompact ? 240 : 240), spacing: Theme.Space.sm)],
                spacing: Theme.Space.sm
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

struct PolicyTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: String
    let title: String
    let status: String
    let isTriggered: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.sm) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isTriggered ? Theme.saving : Theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill((isTriggered ? Theme.saving : Theme.accent).opacity(0.15)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.TypeScale.bodyMedium.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if isTriggered { StatusDot(color: Theme.saving) }
                    Text(status).lineLimit(1)
                }
                .font(Theme.TypeScale.caption)
                .foregroundStyle(isTriggered ? Theme.saving.opacity(0.95) : Color.secondary)
            }
            Spacer(minLength: Theme.Space.xs)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(Theme.Space.sm + 2)
        .lumenSurface(
            radius: Theme.Radius.lg,
            stroke: isTriggered ? Theme.saving.opacity(0.45) : Theme.Surface.stroke
        )
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: isTriggered)
    }
}
