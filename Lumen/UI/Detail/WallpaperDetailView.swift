import SwiftUI

struct WallpaperDetailView: View {
    @Environment(AppModel.self) private var model
    let wallpaperID: UUID

    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        if let wallpaper = model.library.wallpaper(id: wallpaperID) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
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
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl + Theme.Space.md)
                .frame(maxWidth: Theme.Layout.detailMaxWidth, alignment: .leading)
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
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxHeight: Theme.Layout.detailHeroMaxHeight)
                .scaleEffect(1.04)
                .blur(radius: 28)
                .opacity(0.28)
                .allowsHitTesting(false)
            LiveWallpaperPreview(wallpaper: wallpaper, shaderSettings: ShaderRenderSettings(frameRate: 60, pixelBudget: 1_600_000), rendersLive: true)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxHeight: Theme.Layout.detailHeroMaxHeight)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                        .strokeBorder(Theme.Surface.scrimStroke, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.50), radius: 28, y: 14)
        }
        .frame(maxWidth: .infinity)
    }

    private func info(_ wallpaper: Wallpaper) -> some View {
        let showing = model.engine.displays(showing: wallpaper.id)
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                HStack(spacing: Theme.Space.xs) {
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(Theme.TypeScale.detailTitle)
                        .lineLimit(1)
                        .focused($titleFocused)
                        .onSubmit { commitTitle(for: wallpaper) }
                        .disabled(wallpaper.isBuiltin)
                    if !wallpaper.isBuiltin, !titleFocused {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                categoryMenu(wallpaper)
            }

            if let video = wallpaper.video {
                FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
                    MetaChip(symbol: "rectangle.dashed", text: Format.resolution(video.width, video.height))
                    MetaChip(symbol: "film", text: video.codec)
                    MetaChip(symbol: "speedometer", text: Format.frameRate(video.frameRate))
                    MetaChip(symbol: "clock", text: Format.duration(video.duration))
                    MetaChip(symbol: "internaldrive", text: Format.bytes(video.fileSize))
                    if video.isHDR { MetaChip(symbol: "sun.max.fill", text: "HDR", tint: Theme.paused) }
                    if video.hasAudio { MetaChip(symbol: "speaker.wave.2.fill", text: String(localized: "Audio")) }
                }
            } else if let package = wallpaper.package {
                FlowLayout(spacing: Theme.Space.xs, lineSpacing: Theme.Space.xs) {
                    MetaChip(
                        symbol: wallpaper.kind == .scene ? "square.3.layers.3d" : "globe",
                        text: wallpaper.kind == .scene ? String(localized: "Scene") : "Web"
                    )
                    if let width = package.width, let height = package.height, width > 0, height > 0 {
                        MetaChip(symbol: "rectangle.dashed", text: Format.resolution(width, height))
                    }
                    let editableCount = package.properties.filter(\.isEditable).count
                    if editableCount > 0 {
                        MetaChip(symbol: "slider.horizontal.3", text: "\(editableCount)")
                    }
                }
            }

            HStack(spacing: Theme.Space.sm) {
                GlassEffectContainer(spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        SetWallpaperButton { target in model.setWallpaper(wallpaper, on: target) }
                            .controlSize(.large)

                        Button {
                            model.library.toggleFavorite(wallpaper.id)
                        } label: {
                            Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                                .foregroundStyle(wallpaper.isFavorite ? Theme.favorite : Color.primary)
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
                    }
                }

                Spacer(minLength: Theme.Space.sm)

                HStack(spacing: 6) {
                    if showing.isEmpty {
                        Image(systemName: "circle.dashed")
                        Text("Not on any display")
                    } else {
                        StatusDot(color: Theme.playing, pulsing: true)
                        Text("On \(showing.map(\.name).formatted(.list(type: .and)))")
                    }
                }
                .font(Theme.TypeScale.bodyMedium)
                .foregroundStyle(showing.isEmpty ? Color.secondary : Theme.playing)
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.Surface.base))
                .overlay(Capsule().strokeBorder(showing.isEmpty ? Theme.Surface.stroke : Theme.playing.opacity(0.35)))
                .lineLimit(1)
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
                .font(Theme.TypeScale.bodyMedium)
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
        let isEfficient = video.optimized != nil || plan == nil

        HStack(alignment: .center, spacing: Theme.Space.md) {
            Image(systemName: icon(plan: plan))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isEfficient ? Theme.saving : Theme.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill((isEfficient ? Theme.saving : Theme.accent).opacity(0.15)))

            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title(plan: plan)).font(Theme.TypeScale.cardTitle)
                Text(message(plan: plan))
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)

            if let progress {
                VStack(alignment: .trailing, spacing: 6) {
                    ProgressView(value: progress).frame(width: 160)
                    Text(verbatim: "\(Int(progress * 100))%")
                        .font(Theme.TypeScale.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
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
        .padding(Theme.Space.lg)
        .lumenSurface(radius: Theme.Radius.xl)
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
