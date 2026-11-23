import AVFoundation
import SwiftUI

/// Position and zoom for a wallpaper: a display-shaped live preview you can drag and pinch,
/// plus precise sliders. Changes apply to the desktop immediately.
struct FramingControls: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    @State private var previewSize: CGSize = .zero
    @State private var dragStart: WallpaperFraming?
    @State private var zoomStart: Double?

    private var isAdjusting: Bool { dragStart != nil || zoomStart != nil }

    var body: some View {
        let framing = wallpaper.resolvedFraming
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.accentSoft))
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Position & Zoom").font(Theme.TypeScale.cardTitle)
                    Text("Drag the preview or pinch to zoom. Changes show on your desktop right away.")
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.sm)
                FramingResetButton(wallpaper: wallpaper)
            }

            HStack(alignment: .center, spacing: Theme.Space.xl) {
                displayMock(framing)
                    .frame(width: 300)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    FramingSliders(wallpaper: wallpaper)
                    if let hint = roomHint(for: framing) {
                        Label(hint, systemImage: "info.circle")
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Space.xxs)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Theme.Space.lg)
        .lumenSurface(radius: Theme.Radius.xl)
    }

    // MARK: Display mock

    private func displayMock(_ framing: WallpaperFraming) -> some View {
        VStack(spacing: 0) {
            FramedWallpaperPreview(wallpaper: wallpaper, framing: framing, scaling: model.settings.videoScaling)
                .aspectRatio(displayAspect, contentMode: .fit)
                .overlay {
                    if isAdjusting {
                        ThirdsGrid()
                            .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                            .transition(.opacity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { previewSize = $0 }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Color.black.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.Surface.scrimStroke))
                .contentShape(Rectangle())
                .gesture(panGesture)
                .simultaneousGesture(zoomGesture)
                .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
                .animation(Theme.Motion.quick, value: isAdjusting)
                .help("Drag to move the wallpaper, pinch to zoom")

            // Stand: reads as "this is your display" at a glance.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.07)], startPoint: .top, endPoint: .bottom))
                .frame(width: 44, height: 14)
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: 112, height: 4)
        }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? wallpaper.resolvedFraming
                if dragStart == nil { dragStart = start }
                var framing = start
                let (dx, dy) = framingDelta(for: value.translation, from: start)
                framing.horizontal = start.horizontal - dx
                framing.vertical = start.vertical - dy
                model.setFraming(framing.clamped, for: wallpaper.id)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? wallpaper.resolvedFraming.zoom
                if zoomStart == nil { zoomStart = start }
                var framing = wallpaper.resolvedFraming
                framing.zoom = start * value.magnification
                model.setFraming(framing.clamped, for: wallpaper.id)
            }
            .onEnded { _ in zoomStart = nil }
    }

    /// Converts a drag in preview points into framing units so the content follows the pointer.
    private func framingDelta(for translation: CGSize, from start: WallpaperFraming) -> (Double, Double) {
        guard previewSize.width > 0, previewSize.height > 0 else { return (0, 0) }
        switch wallpaper.kind {
        case .shader:
            // Shader offsets move the scene by half a screen per unit, divided by zoom.
            let zoom = max(start.zoom, 1)
            return (2 * translation.width / previewSize.width / zoom,
                    2 * translation.height / previewSize.height / zoom)
        case .web:
            return (0, 0)
        case .video, .scene:
            let content: CGSize
            if let video = wallpaper.video {
                content = CGSize(width: video.width, height: video.height)
            } else if let width = wallpaper.package?.width, let height = wallpaper.package?.height {
                content = CGSize(width: width, height: height)
            } else {
                return (0, 0)
            }
            let bounds = CGRect(origin: .zero, size: previewSize)
            let placed = start.rect(for: content, in: bounds, scaling: model.settings.videoScaling)
            let overflowX = placed.width - bounds.width
            let overflowY = placed.height - bounds.height
            return (overflowX > 1 ? 2 * translation.width / overflowX : 0,
                    overflowY > 1 ? 2 * translation.height / overflowY : 0)
        }
    }

    private var displayAspect: CGFloat {
        guard let frame = NSScreen.screens.first?.frame, frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }

    /// Explains why a direction seems stuck: there's no cropped area to reveal there.
    private func roomHint(for framing: WallpaperFraming) -> String? {
        guard wallpaper.kind == .video, let video = wallpaper.video, video.height > 0,
              model.settings.videoScaling == .fill, framing.zoom < 1.01
        else { return nil }
        let content = Double(video.width) / Double(video.height)
        let display = Double(displayAspect)
        if abs(content - display) < 0.02 {
            return String(localized: "The video already matches your display's shape. Zoom in to make room to move it.")
        }
        return content > display
            ? String(localized: "Only the horizontal position has room to move at 1× zoom.")
            : String(localized: "Only the vertical position has room to move at 1× zoom.")
    }
}

/// The three framing sliders as compact rows, usable on their own (e.g. in Studio).
struct FramingSliders: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FramingSliderRow(title: "Horizontal", value: binding(\.horizontal), range: -1...1) { value in
                offsetLabel(value, negative: String(localized: "Left"), positive: String(localized: "Right"))
            }
            FramingSliderRow(title: "Vertical", value: binding(\.vertical), range: -1...1) { value in
                offsetLabel(value, negative: String(localized: "Top"), positive: String(localized: "Bottom"))
            }
            FramingSliderRow(title: "Zoom", value: binding(\.zoom), range: WallpaperFraming.zoomRange) { value in
                Theme.rateLabel((value * 20).rounded() / 20)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<WallpaperFraming, Double>) -> Binding<Double> {
        Binding(
            get: { wallpaper.resolvedFraming[keyPath: keyPath] },
            set: { newValue in
                var framing = wallpaper.resolvedFraming
                framing[keyPath: keyPath] = newValue
                model.setFraming(framing, for: wallpaper.id)
            }
        )
    }

    private func offsetLabel(_ value: Double, negative: String, positive: String) -> String {
        let percent = Int((abs(value) * 100).rounded())
        if percent == 0 { return String(localized: "Centered") }
        return "\(value < 0 ? negative : positive) \(percent)%"
    }
}

struct FramingResetButton: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    var body: some View {
        Button {
            withAnimation(.smooth) { model.setFraming(.centered, for: wallpaper.id) }
        } label: {
            Label("Center", systemImage: "scope")
        }
        .buttonStyle(.glass)
        .disabled(wallpaper.resolvedFraming.isCentered)
        .help("Reset position and zoom")
    }
}

private struct FramingSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let readout: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
                .controlSize(.small)
            Text(readout(value))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
        }
    }
}

/// Rule-of-thirds guides shown while dragging.
private struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
        }
        return path
    }
}

/// Live preview that places the wallpaper exactly as the desktop does.
struct FramedWallpaperPreview: NSViewRepresentable {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper
    let framing: WallpaperFraming
    let scaling: VideoScaling

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.build(wallpaper, url: model.library.playbackURL(for: wallpaper), framing: framing, scaling: scaling, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.update(framing: framing, scaling: scaling)
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private var playerView: PlayerLayerView?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var shader: ShaderRenderer?
        private var scene: WallpaperRenderer?

        func build(_ wallpaper: Wallpaper, url: URL?, framing: WallpaperFraming, scaling: VideoScaling, in container: NSView) {
            let content: NSView
            switch wallpaper.kind {
            case .video:
                guard let url, let video = wallpaper.video else { return }
                let player = AVQueuePlayer()
                player.isMuted = true
                player.preventsDisplaySleepDuringVideoPlayback = false
                looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
                let view = PlayerLayerView(playerLayer: AVPlayerLayer(player: player))
                view.contentSize = CGSize(width: video.width, height: video.height)
                view.scaling = scaling
                view.framing = framing
                player.play()
                self.player = player
                playerView = view
                content = view
            case .shader:
                guard let config = wallpaper.shader,
                      let renderer = try? ShaderRenderer(config: config, settings: .preview, framing: framing)
                else { return }
                renderer.setActive(true)
                shader = renderer
                content = renderer.view
            case .scene:
                guard let renderer = AppModel.shared.engine.makePreviewRenderer(for: wallpaper, framing: framing) else { return }
                renderer.setActive(true)
                scene = renderer
                content = renderer.view
            case .web:
                return
            }
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)
        }

        func update(framing: WallpaperFraming, scaling: VideoScaling) {
            playerView?.scaling = scaling
            playerView?.framing = framing
            shader?.setFraming(framing)
            scene?.setFraming(framing)
        }

        func tearDown() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            shader?.tearDown()
            shader = nil
            scene?.tearDown()
            scene = nil
        }
    }
}
