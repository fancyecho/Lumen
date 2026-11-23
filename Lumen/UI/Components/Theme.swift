import SwiftUI

enum Theme {
    // MARK: Semantic Colors

    static let accent = Color(red: 0.52, green: 0.44, blue: 1.0)
    static let accentSoft = accent.opacity(0.15)
    static let playing = Color(red: 0.30, green: 0.86, blue: 0.56)
    static let paused = Color(red: 0.98, green: 0.74, blue: 0.28)
    static let saving = Color(red: 0.45, green: 0.86, blue: 0.48)
    static let favorite = Color(red: 0.98, green: 0.36, blue: 0.54)
    static let danger = Color(red: 0.96, green: 0.36, blue: 0.38)

    // MARK: Neutral Surfaces

    enum Surface {
        static let canvas = Color(red: 0.045, green: 0.048, blue: 0.060)
        static let base = Color.white.opacity(0.045)
        static let elevated = Color.white.opacity(0.075)
        static let hover = Color.white.opacity(0.115)
        static let pressed = Color.white.opacity(0.17)
        static let mediaFill = Color.white.opacity(0.04)
        static let stroke = Color.white.opacity(0.085)
        static let strokeHover = Color.white.opacity(0.24)
        static let divider = Color.white.opacity(0.10)
        static let scrim = Color.black.opacity(0.60)
        static let scrimStroke = Color.white.opacity(0.14)
        /// Darker inset for cards that sit on blurred artwork (menu bar quick settings), where a white fill would wash out.
        static let recessed = Color.black.opacity(0.28)
    }

    // MARK: 4/8pt Spacing Grid

    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let page: CGFloat = 36
    }

    // MARK: Concentric Corner Radii

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    // MARK: Layout Constraints

    enum Layout {
        static let galleryMaxWidth: CGFloat = 1480
        static let detailMaxWidth: CGFloat = 1120
        static let minWindowWidth: CGFloat = 1020
        static let minWindowHeight: CGFloat = 680
        static let detailHeroMaxHeight: CGFloat = 440
    }

    // MARK: Typography Scale

    enum TypeScale {
        static let heroTitle = Theme.display(46)
        static let pageTitle = Theme.display(34)
        static let detailTitle = Theme.display(30)
        static let panelTitle = Theme.display(22)
        static let sectionTitle = Theme.display(18, weight: .semibold)
        static let displayCardTitle = Theme.display(16, weight: .semibold)
        static let eyebrow = Font.system(size: 11, weight: .semibold).width(.expanded)
        static let cardTitle = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13.5, weight: .regular)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let caption = Font.system(size: 12, weight: .regular)
        static let micro = Font.system(size: 10.5, weight: .bold)
    }

    // MARK: Motion

    enum Motion {
        static let quick = Animation.easeOut(duration: 0.14)
        static let snappy = Animation.snappy(duration: 0.22)
        static let smooth = Animation.smooth(duration: 0.24)
        static let backdrop = Animation.easeInOut(duration: 0.65)
    }

    /// Wide display face for titles — the signature of the app's typography.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }

    static let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func rateLabel(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

// MARK: Shared Surface Modifier

extension View {
    /// Standard Lumen content surface (solid translucent neutral fill + 1pt hairline border, never glass).
    func lumenSurface(radius: CGFloat = Theme.Radius.xl, stroke: Color = Theme.Surface.stroke) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.Surface.base))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }
}

// MARK: Headers

/// Eyebrow + wide title + subtitle, with an optional trailing accessory.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: eyebrow.uppercased())
                    .font(Theme.TypeScale.eyebrow)
                    .tracking(1.8)
                    .foregroundStyle(Theme.accent)
                Text(verbatim: title)
                    .font(Theme.TypeScale.pageTitle)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Theme.Space.md)
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
        HStack(alignment: .lastTextBaseline, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(verbatim: title)
                    .font(Theme.TypeScale.sectionTitle)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: Empty States

/// Dashed drop-zone panel for empty pages: accent symbol, wide title, explanation, optional action.
struct EmptyStatePanel<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(Theme.display(22))
            Text(message)
                .font(Theme.TypeScale.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            action.padding(.top, Theme.Space.xxs)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .padding(.horizontal, Theme.Space.xl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                .fill(Theme.Surface.base)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 7]))
                .foregroundStyle(Theme.Surface.strokeHover)
        )
    }
}

extension EmptyStatePanel where Action == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

// MARK: Chips & Badges

/// Capsule filter control for the content layer (solid fills, no glass).
struct FilterChip: View {
    let title: String
    var symbol: String?
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(Theme.TypeScale.bodyMedium)
                    .lineLimit(1)
                if let count {
                    Text(verbatim: "\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .opacity(isSelected ? 0.85 : 0.65)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(hovering ? Theme.Surface.hover : Theme.Surface.elevated)
                )
            )
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.Surface.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: isSelected)
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
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
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.Surface.elevated))
        .overlay(Capsule().strokeBorder(Theme.Surface.stroke))
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Small high-contrast label drawn over artwork.
struct ArtBadge: View {
    let text: String
    var symbol: String?
    var dotColor: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let dotColor {
                StatusDot(color: dotColor)
            } else if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(Theme.TypeScale.micro)
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.Surface.scrim))
        .overlay(Capsule().strokeBorder(Theme.Surface.scrimStroke))
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .background(
                Circle()
                    .fill(color.opacity(0.45))
                    .scaleEffect(pulse ? 2.1 : 1)
                    .opacity(pulse ? 0 : (pulsing && !reduceMotion ? 0.75 : 0))
            )
            .onAppear {
                guard pulsing, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
            .onDisappear { pulse = false }
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
        .background(Capsule().fill(Theme.Surface.scrim))
        .overlay(Capsule().strokeBorder(Theme.Surface.scrimStroke))
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        configuration.isPressed
                            ? Theme.Surface.pressed
                            : (hovering ? Theme.Surface.hover : Color.clear)
                    )
                )
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
        }
    }
}

// MARK: Flow Layout

/// Left-aligned wrapping flow layout for metadata chips that must never clip at narrow widths.
struct FlowLayout: Layout {
    var spacing: CGFloat = Theme.Space.xs
    var lineSpacing: CGFloat = Theme.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }
        return CGSize(width: min(totalWidth, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
