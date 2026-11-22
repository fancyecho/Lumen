import AVFoundation
import SwiftUI

/// Horizontal / vertical position and zoom for a wallpaper, with a live, display-shaped preview.
/// Changes apply to the desktop immediately.
struct FramingControls: View {
    @Environment(AppModel.self) private var model
    let wallpaper: Wallpaper

    var body: some View {
        let framing = wallpaper.resolvedFraming
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Position").font(.system(size: 15, weight: .semibold))
                    Text("Choose which part shows when the wallpaper is cropped to your display.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Center") { update(.centered) }
                    .buttonStyle(.glass)
                    .disabled(framing.isCentered)
            }

            HStack(alignment: .center, spacing: 24) {
                FramedWallpaperPreview(wallpaper: wallpaper, framing: framing, scaling: model.settings.videoScaling)
                    .aspectRatio(displayAspect, contentMode: .fit)
                    .frame(width: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 14) {
                    FramingSlider(
                        title: String(localized: "Horizontal"), value: binding(\.horizontal), range: -1...1,
                        low: String(localized: "Left"), high: String(localized: "Right"), readout: offsetLabel
                    )
                    FramingSlider(
                        title: String(localized: "Vertical"), value: binding(\.vertical), range: -1...1,
                        low: String(localized: "Top"), high: String(localized: "Bottom"), readout: offsetLabel
                    )
                    FramingSlider(
                        title: String(localized: "Zoom"), value: binding(\.zoom), range: WallpaperFraming.zoomRange,
                        low: "1×", high: "3×", readout: { Theme.rateLabel(($0 * 20).rounded() / 20) }
                    )
                }
            }

            if let hint = roomHint(for: framing) {
                Label(hint, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.surfaceStroke))
    }

    private var displayAspect: CGFloat {
        guard let frame = NSScreen.screens.first?.frame, frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }

    private func binding(_ keyPath: WritableKeyPath<WallpaperFraming, Double>) -> Binding<Double> {
        Binding(
            get: { wallpaper.resolvedFraming[keyPath: keyPath] },
            set: { newValue in
                var framing = wallpaper.resolvedFraming
                framing[keyPath: keyPath] = newValue
                update(framing)
            }
        )
    }

    private func update(_ framing: WallpaperFraming) {
        model.setFraming(framing, for: wallpaper.id)
    }

    private func offsetLabel(_ value: Double) -> String {
        abs(value) < 0.005 ? String(localized: "Centered") : "\(Int((value * 100).rounded()))"
    }

    /// Explains why a slider seems to do nothing: there's no cropped area in that direction.
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

private struct FramingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    let readout: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(readout(value))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) {
                Text(title)
            } minimumValueLabel: {
                Text(low).font(.system(size: 11)).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(minWidth: 240)
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
            }
            content.frame = container.bounds
            content.autoresizingMask = [.width, .height]
            container.addSubview(content)
        }

        func update(framing: WallpaperFraming, scaling: VideoScaling) {
            playerView?.scaling = scaling
            playerView?.framing = framing
            shader?.setFraming(framing)
        }

        func tearDown() {
            player?.pause()
            looper?.disableLooping()
            looper = nil
            player = nil
            shader?.tearDown()
            shader = nil
        }
    }
}
