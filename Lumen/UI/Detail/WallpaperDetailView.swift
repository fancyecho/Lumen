import SwiftUI

struct WallpaperDetailView: View {
    @Environment(AppModel.self) private var model
    let wallpaperID: UUID

    @State private var draftTitle = ""
    @State private var viewport = CGSize(width: 1280, height: 840)
    @FocusState private var titleFocused: Bool

    /// The preview spans the content column so its edges line up with the title and panels below.
    /// Its height follows the window (a wide, cinematic crop on short windows; never taller than 16:9),
    /// which keeps the title and "Set as Wallpaper" above the fold. Sized explicitly because inside a
    /// vertical ScrollView an aspect-ratio modifier alone lets live renderers stretch unpredictably.
    /// The Position & Zoom panel below always shows the exact on-screen composition.
    private var heroSize: CGSize {
        let width = max(320, min(viewport.width, Theme.Layout.detailMaxWidth) - Theme.Space.page * 2)
        let height = min(width * 9 / 16, Theme.Layout.detailHeroMaxHeight, max(300, viewport.height * 0.52))
        return CGSize(width: width, height: height)
    }

    var body: some View {
        if let wallpaper = model.library.wallpaper(id: wallpaperID) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl + Theme.Space.xxs) {
                    hero(wallpaper)
                    header(wallpaper)
                    notices(wallpaper)
                    columns(wallpaper)
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, Theme.Space.md)
                .padding(.bottom, Theme.Space.xxl + Theme.Space.md)
                .frame(maxWidth: Theme.Layout.detailMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
            .onAppear { draftTitle = wallpaper.title }
            .onChange(of: titleFocused) { _, focused in
                if !focused { commitTitle(for: wallpaper) }
            }
        } else {
            ContentUnavailableView("Wallpaper not found", systemImage: "questionmark.square.dashed")
        }
    }

    // MARK: Hero

    private func hero(_ wallpaper: Wallpaper) -> some View {
        let size = heroSize
        return LiveWallpaperPreview(wallpaper: wallpaper, shaderSettings: ShaderRenderSettings(frameRate: 60, pixelBudget: 1_600_000), rendersLive: true)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                    .strokeBorder(Theme.Surface.scrimStroke, lineWidth: 1)
            )
            .background {
                AmbientGlow(wallpaper: wallpaper)
                    .scaleEffect(1.06)
                    .blur(radius: 36)
                    .opacity(0.34)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: Header

    private func header(_ wallpaper: Wallpaper) -> some View {
        let showing = model.engine.displays(showing: wallpaper.id)
        return VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Eyebrow(text: "\(WallpaperDescriptor.kindLabel(wallpaper)) · \(WallpaperCategories.displayName(wallpaper.category))")
                HStack(alignment: .center, spacing: Theme.Space.xs) {
                    // A hidden copy of the title sizes the field to its text, so the pencil sits right after it.
                    Text(verbatim: draftTitle.isEmpty ? "M" : draftTitle)
                        .font(Theme.TypeScale.artworkTitle)
                        .lineLimit(1)
                        .padding(.trailing, 6)
                        .hidden()
                        .overlay(alignment: .leading) {
                            TextField("Title", text: $draftTitle)
                                .textFieldStyle(.plain)
                                .font(Theme.TypeScale.artworkTitle)
                                .foregroundStyle(Theme.Ink.primary)
                                .lineLimit(1)
                                .focused($titleFocused)
                                .onSubmit { commitTitle(for: wallpaper) }
                                .disabled(wallpaper.isBuiltin)
                                .help(wallpaper.isBuiltin ? Text("Built-in wallpapers keep their name") : Text("Rename"))
                        }
                        .layoutPriority(1)
                    if !wallpaper.isBuiltin, !titleFocused {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Ink.tertiary)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                }
                Text(WallpaperDescriptor.specLine(for: wallpaper))
                    .font(Theme.TypeScale.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: Theme.Space.sm) {
                HStack(spacing: Theme.Space.xs) {
                    SetWallpaperButton { target in model.setWallpaper(wallpaper, on: target) }

                    Button {
                        model.library.toggleFavorite(wallpaper.id)
                    } label: {
                        Image(systemName: wallpaper.isFavorite ? "heart.fill" : "heart")
                            .foregroundStyle(wallpaper.isFavorite ? Theme.favorite : Theme.Ink.primary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.lumenIcon)
                    .help(wallpaper.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))
                    .accessibilityLabel(wallpaper.isFavorite ? Text("Remove from Favorites") : Text("Add to Favorites"))

                    categoryMenu(wallpaper)

                    Menu {
                        WallpaperMenuItems(wallpaper: wallpaper)
                    } label: {
                        ChromeLabel(isIconOnly: true) { Image(systemName: "ellipsis") }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
                .controlSize(.large)

                Spacer(minLength: Theme.Space.sm)

                HStack(spacing: 7) {
                    if showing.isEmpty {
                        Image(systemName: "circle.dashed")
                        Text("Not on any display")
                    } else {
                        StatusDot(color: Theme.playing, pulsing: true)
                        Text("On \(showing.map(\.name).formatted(.list(type: .and)))")
                    }
                }
                .font(Theme.TypeScale.bodyMedium)
                .foregroundStyle(showing.isEmpty ? Theme.Ink.secondary : Theme.playing)
                .padding(.horizontal, Theme.Space.sm + 2)
                .padding(.vertical, 7)
                .background(Capsule().fill(Theme.Surface.base))
                .overlay(Capsule().strokeBorder(showing.isEmpty ? Theme.Surface.stroke : Theme.playing.opacity(0.35)))
                .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func notices(_ wallpaper: Wallpaper) -> some View {
        let notices = model.engine.displays(showing: wallpaper.id).compactMap { display in
            display.sceneNotice.map { (display.name, $0.message) }
        }
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                ForEach(notices, id: \.0) { name, message in
                    Label(String(localized: "\(name) — \(message)"), systemImage: "exclamationmark.circle")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.Ink.secondary)
                }
            }
        }
    }

    // MARK: Columns

    /// Adjustments on the left, facts on the right. Web pages have no framing, so when nothing
    /// adjustable exists the facts take the full width instead of leaving a hole.
    @ViewBuilder
    private func columns(_ wallpaper: Wallpaper) -> some View {
        let editable = wallpaper.package.flatMap { $0.properties.contains(where: \.isEditable) ? $0 : nil }
        let showsFraming = wallpaper.kind != .web
        let hasAdjustments = showsFraming || editable != nil
        HStack(alignment: .top, spacing: Theme.Space.xl) {
            if hasAdjustments {
                VStack(spacing: Theme.Space.lg) {
                    if showsFraming { FramingControls(wallpaper: wallpaper) }
                    if let editable { PropertiesPanel(wallpaper: wallpaper, package: editable) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            VStack(spacing: Theme.Space.lg) {
                AboutPanel(wallpaper: wallpaper)
                if let video = wallpaper.video {
                    OptimizationCard(wallpaper: wallpaper, video: video)
                }
            }
            .frame(width: hasAdjustments ? Theme.Layout.inspectorWidth : nil)
            .frame(maxWidth: hasAdjustments ? nil : 560, alignment: .leading)
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
            ChromeLabel {
                HStack(spacing: 6) {
                    Image(systemName: "tag").imageScale(.small).accessibilityHidden(true)
                    Text(WallpaperCategories.displayName(wallpaper.category))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Ink.tertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(wallpaper.isBuiltin)
        .help("Category")
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

/// Every fact Lumen knows about a wallpaper, as a calm label/value list.
struct AboutPanel: View {
    let wallpaper: Wallpaper

    var body: some View {
        LumenPanel(symbol: "info.circle", title: "About") {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { HairlineDivider() }
                        InfoRow(label: row.label, value: row.value)
                    }
                }
                if let tags = wallpaper.package?.tags, !tags.isEmpty {
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
            }
        }
    }

    private var rows: [(label: String, value: String)] {
        var rows: [(String, String)] = [(String(localized: "Type"), WallpaperDescriptor.kindLabel(wallpaper))]
        if let resolution = WallpaperDescriptor.resolution(for: wallpaper) {
            rows.append((String(localized: "Resolution"), resolution))
        }
        if let video = wallpaper.video {
            rows.append((String(localized: "Codec"), video.isHDR ? "\(video.codec) · HDR" : video.codec))
            rows.append((String(localized: "Frame Rate"), Format.frameRate(video.frameRate)))
            rows.append((String(localized: "Length"), Format.duration(video.duration)))
        }
        if let bytes = WallpaperDescriptor.byteCount(for: wallpaper) {
            rows.append((String(localized: "Size"), Format.bytes(bytes)))
        }
        rows.append((String(localized: "Category"), WallpaperCategories.displayName(wallpaper.category)))
        if let source = WallpaperDescriptor.source(for: wallpaper) {
            rows.append((String(localized: "Source"), source))
        }
        if let workshopID = wallpaper.package?.workshopID {
            rows.append((String(localized: "Workshop ID"), workshopID))
        }
        if !wallpaper.isBuiltin {
            rows.append((String(localized: "Added"), wallpaper.addedAt.formatted(date: .abbreviated, time: .omitted)))
        }
        return rows
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

        // Sits in the narrow inspector column, so the action goes under the explanation.
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                IconWell(symbol: icon(plan: plan), tint: isEfficient ? Theme.saving : .white)
                Text(title(plan: plan))
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
            }
            Text(message(plan: plan))
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let progress {
                HStack(spacing: Theme.Space.sm) {
                    ProgressView(value: progress)
                    Text(verbatim: "\(Int(progress * 100))%")
                        .font(Theme.TypeScale.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Ink.secondary)
                }
            } else if let plan {
                Button {
                    model.optimize(wallpaper)
                } label: {
                    Label("Optimize · \(plan.label)", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.lumenSecondary)
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
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
