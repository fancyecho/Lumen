import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 46) {
                hero
                displaysSection
                if !recent.isEmpty { recentShelf }
                generativeShelf
                if model.engine.displays.count != 1 { SmartPausePanel() }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: 1480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }

    private var recent: [Wallpaper] { Array(model.library.items.prefix(8)) }

    private var hero: some View {
        let engine = model.engine
        let playing = engine.displays.filter(\.isPlaying).count
        let libraryCount = model.library.items.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "\(Format.greeting()) · \(Date.now.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US")).weekday(.wide)))".uppercased())
                .font(Theme.eyebrow)
                .tracking(1.8)
                .foregroundStyle(Theme.accent)
            Text(verbatim: "Your desktop,\nin motion.")
                .font(Theme.display(52))
                .lineSpacing(-4)
            Text(heroSubtitle(playing: playing, libraryCount: libraryCount))
                .font(.system(size: 15))
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
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle("On your displays", subtitle: String(localized: "Each display can play its own wallpaper."))
            if let only = model.engine.displays.first, model.engine.displays.count == 1 {
                // One display: give the card room and use the space beside it for Smart pause.
                HStack(alignment: .top, spacing: 34) {
                    DisplayCard(display: only)
                        .frame(minWidth: 420, maxWidth: 600)
                    SmartPausePanel(isCompact: true)
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360, maximum: 620), spacing: 22, alignment: .top)], alignment: .leading, spacing: 22) {
                    ForEach(model.engine.displays) { display in
                        DisplayCard(display: display)
                    }
                }
            }
        }
    }

    private var recentShelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Recently added") {
                Button("See all") { model.router.show(.library) }
                    .buttonStyle(.link)
            }
            shelf(recent)
        }
    }

    private var generativeShelf: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Generative", subtitle: String(localized: "Rendered live on the GPU. Tune colours and motion in Studio.")) {
                Button("Open Studio") { model.router.show(.studio) }
                    .buttonStyle(.link)
            }
            shelf(model.library.builtins)
        }
    }

    private func shelf(_ wallpapers: [Wallpaper]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 20) {
                ForEach(wallpapers) { wallpaper in
                    WallpaperCard(wallpaper: wallpaper)
                        .frame(width: 290)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
        .padding(.vertical, -14)
    }
}

struct DisplayCard: View {
    @Environment(AppModel.self) private var model
    let display: WallpaperEngine.Display
    @State private var hovering = false

    var body: some View {
        let wallpaper = display.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                if let wallpaper {
                    ThumbnailView(wallpaper: wallpaper)
                } else {
                    emptyArtwork
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(alignment: .topLeading) { DisplayStatusPill(display: display).padding(12) }
            .overlay(alignment: .bottomLeading) {
                if let wallpaper {
                    Text(wallpaper.title)
                        .font(Theme.display(17, weight: .semibold))
                        .shadow(color: .black.opacity(0.6), radius: 8)
                        .padding(14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovering ? 0.25 : 0.09))
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .onHover { hovering = $0 }
            .onTapGesture {
                if let wallpaper {
                    model.router.open(wallpaper.kind == .video ? .wallpaper(wallpaper.id) : .studio(wallpaper.id))
                } else {
                    model.router.show(.library)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: display.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name).font(.system(size: 14, weight: .semibold))
                    Text(Format.resolution(Int(display.pixelSize.width), Int(display.pixelSize.height)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
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
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private var emptyArtwork: some View {
        ZStack {
            Color.white.opacity(0.035)
            VStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Showing the system wallpaper")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
                .foregroundStyle(Color.white.opacity(0.18))
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

        VStack(alignment: .leading, spacing: isCompact ? 12 : 16) {
            if isCompact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Smart pause").font(Theme.display(17, weight: .semibold))
                    Text("Lumen stops decoding whenever nobody can see the wallpaper — and when your Mac needs the energy more.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SectionTitle("Smart pause", subtitle: String(localized: "Lumen stops decoding whenever nobody can see the wallpaper — and when your Mac needs the energy more."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isCompact ? 260 : 240), spacing: 12)], spacing: 12) {
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
    let symbol: String
    let title: String
    let status: String
    let isTriggered: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isTriggered ? Theme.saving : Theme.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill((isTriggered ? Theme.saving : Theme.accent).opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                HStack(spacing: 5) {
                    if isTriggered { StatusDot(color: Theme.saving) }
                    Text(status)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isTriggered ? Theme.saving.opacity(0.45) : Theme.surfaceStroke)
        )
        .animation(.easeOut(duration: 0.2), value: isTriggered)
    }
}
