import SwiftUI

enum Theme {
    static let accent = Color(red: 0.49, green: 0.42, blue: 1.0)
    static let playing = Color(red: 0.36, green: 0.88, blue: 0.58)
    static let paused = Color(red: 1.0, green: 0.76, blue: 0.32)
    static let saving = Color(red: 0.55, green: 0.86, blue: 0.45)

    static let pagePadding: CGFloat = 40
    static let cardRadius: CGFloat = 16
    static let surface = Color.white.opacity(0.055)
    static let surfaceStroke = Color.white.opacity(0.09)

    /// Wide display face for titles — the signature of the app's typography.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }

    static let eyebrow = Font.system(size: 11.5, weight: .semibold).width(.expanded)
    static let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func rateLabel(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

/// Eyebrow + wide title + subtitle, with an optional trailing accessory.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(eyebrow.uppercased())
                    .font(Theme.eyebrow)
                    .tracking(1.8)
                    .foregroundStyle(Theme.accent)
                Text(title)
                    .font(Theme.display(42))
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.display(20, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Capsule filter control for the content layer (solid fills, no glass).
struct FilterChip: View {
    let title: String
    var symbol: String?
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(hovering ? 0.12 : 0.065)))
            )
            .overlay(Capsule().strokeBorder(Color.white.opacity(isSelected ? 0 : 0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct MetaChip: View {
    let symbol: String
    let text: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? Color.secondary)
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.065)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
    }
}

/// Small label drawn over artwork.
struct ArtBadge: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.5)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(
                Circle()
                    .fill(color.opacity(0.45))
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.8)
            )
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// "Playing" / "Paused · reason" capsule used on display cards and the menu bar panel.
struct DisplayStatusPill: View {
    let display: WallpaperEngine.Display

    var body: some View {
        HStack(spacing: 6) {
            if display.wallpaperID == nil {
                Image(systemName: "circle.dashed").font(.system(size: 10, weight: .bold))
                Text("System wallpaper")
            } else if let reason = display.pauseReason {
                Image(systemName: reason.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(reason.savesEnergy ? Theme.saving : Theme.paused)
                Text(reason.title)
            } else {
                StatusDot(color: Theme.playing)
                Text("Playing")
            }
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.5)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }
}

/// Hover-highlighted icon button for use inside glass surfaces (no glass on glass).
struct BarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        BarIconButton(configuration: configuration, size: size)
    }

    private struct BarIconButton: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.1 : 0))))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
