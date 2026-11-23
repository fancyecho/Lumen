import SwiftUI

struct WallpaperDetailView: View {
    @Environment(AppModel.self) private var model
    let wallpaperID: UUID

    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let wallpaper = model.library.wallpaper(id: wallpaperID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    hero(wallpaper)
                    info(wallpaper)
                    if wallpaper.kind != .web {
                        FramingControls(wallpaper: wallpaper)
                    }
                    if let package = wallpaper.package, package.properties.contains(where: \.isEditable) {
                        PropertiesPanel(wallpaper: wallpaper, package: package)
                    }
                    if let video = wallpaper.video {
                        OptimizationCard(wallpaper: wallpaper, video: video)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 22)
                .padding(.bottom, 32)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .onAppear { draftTitle = wallpaper.title }
            .onChange(of: titleFocused) { _, focused in
                if !focused { commitTitle(for: wallpaper) }
            }
        } else {
            ContentUnavailableView("Wallpaper not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func hero(_ wallpaper: Wallpaper) -> some View {
        ZStack {
            AmbientGlow(wallpaper: wallpaper)
                .scaleEffect(1.12)
                .blur(radius: 30)
                .opacity(0.75)
            LiveWallpaperPreview(wallpaper: wallpaper, shaderSettings: ShaderRenderSettings(frameRate: 60, pixelBudget: 1_600_000), rendersLive: true)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12))
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 18)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private func info(_ wallpaper: Wallpaper) -> some View {
        let showing = model.engine.displays(showing: wallpaper.id)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.display(36))
                    .focused($titleFocused)
                    .onSubmit { commitTitle(for: wallpaper) }
                    .disabled(wallpaper.isBuiltin)
                categoryMenu(wallpaper)
            }

            if let video = wallpaper.video {
                HStack(spacing: 8) {
                    MetaChip(symbol: "rectangle.dashed", text: Format.resolution(video.width, video.height))
                    MetaChip(symbol: "film", text: video.codec)
                    MetaChip(symbol: "speedometer", text: Format.frameRate(video.frameRate))
                    MetaChip(symbol: "clock", text: Format.duration(video.duration))
                    MetaChip(symbol: "internaldrive", text: Format.bytes(video.fileSize))
                    if video.isHDR { MetaChip(symbol: "sun.max.fill", text: "HDR", tint: .yellow) }
                    if video.hasAudio { MetaChip(symbol: "speaker.wave.2.fill", text: String(localized: "Audio")) }
                }
            }

            ForEach(showing) { display in
                if let notice = display.sceneNotice {
                    Label(String(localized: "\(display.name) — \(notice.message)"), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                SetWallpaperButton { target in model.setWallpaper(wallpaper, on: target) }
                    .controlSize(.large)

                Button {
                    model.library.toggleFavorite(wallpaper.id)
                } label: {
                    Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(wallpaper.isFavorite ? Color.pink : Color.primary)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .help(wallpaper.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))

                Menu {
                    WallpaperMenuItems(wallpaper: wallpaper)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .menuIndicator(.hidden)
                .controlSize(.large)
                .fixedSize()

                Spacer()

                HStack(spacing: 6) {
                    if showing.isEmpty {
                        Image(systemName: "circle.dashed")
                        Text("Not on any display")
                    } else {
                        StatusDot(color: Theme.playing, pulsing: true)
                        Text("On \(showing.map(\.name).formatted(.list(type: .and)))")
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func categoryMenu(_ wallpaper: Wallpaper) -> some View {
        Menu {
            ForEach(WallpaperCategories.all, id: \.self) { name in
                Button {
                    var updated = wallpaper
                    updated.category = name
                    model.library.update(updated)
                } label: {
                    let title = WallpaperCategories.displayName(name)
                    if name == wallpaper.category { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            Label(WallpaperCategories.displayName(wallpaper.category), systemImage: "tag")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
        .disabled(wallpaper.isBuiltin)
    }

    private func commitTitle(for wallpaper: Wallpaper) {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != wallpaper.title, !wallpaper.isBuiltin else {
            draftTitle = wallpaper.title
            return
        }
        var updated = wallpaper
        updated.title = trimmed
        model.library.update(updated)
    }
}

/// Explains and runs the HEVC re-encode that makes a video cheaper to play.
struct OptimizationCard: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    let video: VideoAsset

    var body: some View {
        let maxWidth = NSScreen.screens.map { Int($0.pixelSize.width) }.max() ?? 3840
        let plan = VideoOptimizer.plan(for: video, maxDisplayWidth: maxWidth)
        let progress = model.library.optimizing[wallpaper.id]

        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon(plan: plan))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(video.optimized != nil || plan == nil ? Theme.saving : Theme.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.07)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title(plan: plan)).font(.system(size: 15, weight: .semibold))
                Text(message(plan: plan))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)

            if let progress {
                VStack(alignment: .trailing, spacing: 6) {
                    ProgressView(value: progress).frame(width: 160)
                    Text("\(Int(progress * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else if let plan {
                Button {
                    model.optimize(wallpaper)
                } label: {
                    Label("Optimize · \(plan.label)", systemImage: "bolt.fill")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.surfaceStroke))
    }

    private func icon(plan: VideoOptimizer.Plan?) -> String {
        if video.optimized != nil { return "bolt.fill" }
        return plan == nil ? "checkmark.seal.fill" : "bolt.badge.clock"
    }

    private func title(plan: VideoOptimizer.Plan?) -> String {
        if video.optimized != nil { return String(localized: "Optimized for this Mac") }
        return plan == nil ? String(localized: "Already efficient") : String(localized: "Make it lighter to play")
    }

    private func message(plan: VideoOptimizer.Plan?) -> String {
        if let optimized = video.optimized {
            return String(localized: "Playing an HEVC copy at \(Format.resolution(optimized.width, optimized.height)) · \(Format.bytes(optimized.fileSize)) (original \(Format.bytes(video.fileSize))).")
        }
        if plan == nil {
            return String(localized: "\(video.codec) at this size decodes on the media engine with minimal power.")
        }
        return String(localized: "Re-encode this \(video.codec) \(Format.resolution(video.width, video.height)) video to HEVC at your display's size. The media engine decodes HEVC with less power, and the file is usually much smaller. The original is kept.")
    }
}
