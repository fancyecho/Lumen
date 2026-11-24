import SwiftUI

/// Lumen's design tokens and shared building blocks. The rules behind them live in docs/DESIGN.md.
enum Theme {
    // MARK: Accent & Status

    /// Signature violet, deliberately muted (a dusty lavender, not a neon purple). Reserved for
    /// switches, sliders and focus — buttons and chips are neutral (see `LumenButtonStyle`).
    static let accent = Color(red: 0.557, green: 0.522, blue: 0.839)
    /// Pale lavender for eyebrows and small marks on dark backdrops.
    static let accentInk = Color(red: 0.79, green: 0.76, blue: 0.94)
    static let playing = Color(red: 0.42, green: 0.82, blue: 0.62)
    static let paused = Color(red: 0.94, green: 0.76, blue: 0.42)
    static let saving = Color(red: 0.50, green: 0.82, blue: 0.58)
    static let favorite = Color(red: 0.94, green: 0.47, blue: 0.60)
    static let danger = Color(red: 0.93, green: 0.42, blue: 0.42)

    // MARK: Text

    /// Text colours for the always-dark main window. Fixed alphas (rather than `.secondary`) keep the
    /// hierarchy identical on every backdrop tint, and the secondary step is brighter than the system's
    /// so captions stay readable over coloured atmosphere.
    enum Ink {
        static let primary = Color.white.opacity(0.95)
        static let secondary = Color.white.opacity(0.68)
        static let tertiary = Color.white.opacity(0.46)
        static let quaternary = Color.white.opacity(0.28)
        /// Text on the light primary button.
        static let onLight = Color(white: 0.08)
    }

    // MARK: Neutral Surfaces

    enum Surface {
        static let canvas = Color(red: 0.035, green: 0.036, blue: 0.045)
        static let base = Color.white.opacity(0.055)
        static let elevated = Color.white.opacity(0.085)
        static let hover = Color.white.opacity(0.12)
        static let pressed = Color.white.opacity(0.18)
        static let mediaFill = Color.white.opacity(0.05)
        static let stroke = Color.white.opacity(0.08)
        static let strokeHover = Color.white.opacity(0.22)
        static let divider = Color.white.opacity(0.08)
        static let scrim = Color.black.opacity(0.55)
        static let scrimStroke = Color.white.opacity(0.14)
        /// Darker inset for cards that sit on blurred artwork (menu bar quick settings), where a white fill would wash out.
        static let recessed = Color.black.opacity(0.26)
        /// Hairline just inside artwork edges, so dark images keep a crisp silhouette on a dark backdrop.
        static let artworkEdge = Color.white.opacity(0.09)
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
        /// Horizontal page margin.
        static let page: CGFloat = 40
        /// Vertical rhythm between the major sections of a page.
        static let section: CGFloat = 48
    }

    // MARK: Concentric Corner Radii

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 12
        /// Gallery artwork cards.
        static let lg: CGFloat = 14
        /// Panels and feature cards.
        static let xl: CGFloat = 20
        /// Hero frames and empty-state drop zones.
        static let xxl: CGFloat = 24
    }

    // MARK: Layout Constraints

    enum Layout {
        static let galleryMaxWidth: CGFloat = 1560
        static let detailMaxWidth: CGFloat = 1180
        static let minWindowWidth: CGFloat = 1020
        static let minWindowHeight: CGFloat = 680
        static let detailHeroMaxHeight: CGFloat = 560
        static let inspectorWidth: CGFloat = 320
        static let shelfCardWidth: CGFloat = 300

        /// Side inset that keeps content inside `maxWidth` while letting rows (shelves) run to the window edge.
        static func inset(for width: CGFloat, maxWidth: CGFloat = galleryMaxWidth) -> CGFloat {
            max(Theme.Space.page, (width - maxWidth) / 2 + Theme.Space.page)
        }
    }

    // MARK: Typography Scale

    enum TypeScale {
        static let heroTitle = Theme.display(40)
        static let pageTitle = Theme.display(32, weight: .semibold)
        /// Wallpaper names at display size. Standard width on purpose: most titles mix in CJK, which has
        /// no expanded cut, and a wide Latin face beside normal-width Han characters looks mismatched.
        static let artworkTitle = Font.system(size: 30, weight: .bold)
        static let compactArtworkTitle = Font.system(size: 22, weight: .bold)
        static let panelTitle = Theme.display(20, weight: .semibold)
        static let sectionTitle = Theme.display(17, weight: .semibold)
        static let eyebrow = Font.system(size: 10.5, weight: .semibold).width(.expanded)
        static let columnHeader = Font.system(size: 10.5, weight: .semibold)
        static let cardTitle = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13.5, weight: .regular)
        static let bodyMedium = Font.system(size: 13, weight: .medium)
        static let caption = Font.system(size: 12, weight: .regular)
        static let label = Font.system(size: 11.5, weight: .medium)
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

// MARK: Shared Surface Modifiers

extension View {
    /// Standard Lumen content surface (solid translucent neutral fill + 1pt hairline border, never glass).
    func lumenSurface(radius: CGFloat = Theme.Radius.xl, stroke: Color = Theme.Surface.stroke) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.Surface.base))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: 1))
    }

    /// Rounded artwork frame shared by every gallery card: edge hairline, grounded shadow, gentle hover lift.
    func artworkFrame(radius: CGFloat = Theme.Radius.lg, isHovering: Bool = false, highlight: Color? = nil, lifts: Bool = true) -> some View {
        modifier(ArtworkFrame(radius: radius, isHovering: isHovering, highlight: highlight, lifts: lifts))
    }
}

private struct ArtworkFrame: ViewModifier {
    let radius: CGFloat
    let isHovering: Bool
    let highlight: Color?
    let lifts: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    highlight ?? (isHovering ? Theme.Surface.strokeHover : Theme.Surface.artworkEdge),
                    lineWidth: highlight == nil ? 1 : 1.5
                )
            )
            .shadow(color: .black.opacity(isHovering ? 0.5 : 0.3), radius: isHovering ? 24 : 12, y: isHovering ? 14 : 6)
            .scaleEffect(isHovering && lifts && !reduceMotion ? 1.02 : 1)
            .animation(reduceMotion ? nil : Theme.Motion.snappy, value: isHovering)
    }
}

// MARK: Headers

/// Small, wide, tracked uppercase kicker above a title.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.accentInk
    /// Standard width for dense places (table headers) where the wide face would truncate.
    var isCompact = false

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(isCompact ? Theme.TypeScale.columnHeader : Theme.TypeScale.eyebrow)
            .tracking(isCompact ? 0.8 : 1.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Eyebrow + wide title + subtitle, with an optional trailing accessory.
struct PageHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.xl) {
            VStack(alignment: .leading, spacing: Theme.Space.xs + 2) {
                Eyebrow(text: eyebrow)
                Text(verbatim: title)
                    .font(Theme.TypeScale.pageTitle)
                    .tracking(-0.3)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.Ink.secondary)
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
            VStack(alignment: .leading, spacing: Theme.Space.xxs + 1) {
                Text(verbatim: title)
                    .font(Theme.TypeScale.sectionTitle)
                    .foregroundStyle(Theme.Ink.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.TypeScale.caption)
                        .foregroundStyle(Theme.Ink.tertiary)
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

/// Quiet "See all ›" style link used beside section titles.
struct SectionLink: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
            }
            .font(Theme.TypeScale.bodyMedium)
            .foregroundStyle(hovering ? Theme.Ink.primary : Theme.Ink.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.quick, value: hovering)
    }
}

// MARK: Panels

/// Rounded-square icon well used at the head of panels and tiles.
/// Neutral (white) by default; pass a status colour only when the well reports a state.
struct IconWell: View {
    let symbol: String
    var tint: Color = .white
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(tint.opacity(0.86))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(tint == .white ? 0.08 : 0.15)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }
}

/// The one container for settings-like content inside pages: icon, title, optional subtitle and accessory.
struct LumenPanel<Accessory: View, Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    var subtitle: String?
    var tint: Color = .white
    var stroke: Color = Theme.Surface.stroke
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(alignment: .center, spacing: Theme.Space.sm) {
                IconWell(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.TypeScale.cardTitle)
                        .foregroundStyle(Theme.Ink.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(Theme.Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                accessory
            }
            content
        }
        .padding(Theme.Space.lg)
        .lumenSurface(radius: Theme.Radius.xl, stroke: stroke)
    }
}

extension LumenPanel where Accessory == EmptyView {
    init(symbol: String, title: LocalizedStringKey, subtitle: String? = nil, tint: Color = .white, @ViewBuilder content: () -> Content) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, tint: tint, accessory: { EmptyView() }, content: content)
    }
}

/// Label/value line for spec lists (About panel).
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            Text(label)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.Ink.tertiary)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.sm)
            Text(verbatim: value)
                .font(Theme.TypeScale.bodyMedium)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
    }
}

struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Surface.divider)
            .frame(height: 1)
    }
}

// MARK: Empty States

/// Dashed drop-zone panel for empty pages: symbol, wide title, explanation, optional action.
struct EmptyStatePanel<Action: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            IconWell(symbol: symbol, size: 56)
            Text(title)
                .font(Theme.TypeScale.panelTitle)
                .foregroundStyle(Theme.Ink.primary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(Theme.TypeScale.body)
                .foregroundStyle(Theme.Ink.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
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
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
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
    enum Style {
        /// Filled capsule for the primary filter row.
        case standard
        /// Text-only until selected, for secondary rows that shouldn't compete with the first.
        case quiet
    }

    let title: String
    var symbol: String?
    var count: Int?
    let isSelected: Bool
    var style: Style = .standard
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
                        .opacity(isSelected ? 0.8 : 0.55)
                }
            }
            .padding(.horizontal, style == .quiet ? 11 : 13)
            .frame(height: 28)
            .foregroundStyle(foreground)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: isSelected)
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Selection is shown by luminance, not hue: a light capsule with dark text reads instantly and
    /// never fights the artwork's colours.
    private var foreground: Color {
        if isSelected { return style == .standard ? Theme.Ink.onLight : Theme.Ink.primary }
        return hovering ? Theme.Ink.primary : Theme.Ink.secondary
    }

    private var fill: Color {
        switch style {
        case .standard:
            isSelected ? Color.white.opacity(0.9) : (hovering ? Theme.Surface.hover : Theme.Surface.base)
        case .quiet:
            isSelected ? Theme.Surface.pressed : (hovering ? Theme.Surface.base : .clear)
        }
    }

    private var border: Color {
        guard style == .standard, !isSelected else { return .clear }
        return Theme.Surface.stroke
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

/// "Playing" / "Paused · reason" capsule used on display artwork and the menu bar panel.
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
        .font(Theme.TypeScale.label.weight(.semibold))
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
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        configuration.isPressed
                            ? Theme.Surface.pressed
                            : (hovering && isEnabled ? Theme.Surface.hover : Color.clear)
                    )
                )
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
        }
    }
}

// MARK: Buttons

/// Lumen's button chrome. System `.glass` buttons take the environment tint, which turned every
/// secondary action into a saturated violet pill; drawing our own keeps colour deliberate:
/// one light primary per area, neutral Liquid Glass for everything else.
enum ChromeKind {
    /// Off-white capsule with near-black text — the one action that matters most here.
    case primary
    /// Neutral Liquid Glass with white text.
    case secondary
}

struct LumenButtonStyle: ButtonStyle {
    var kind: ChromeKind = .secondary
    var isIconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeLabel(kind: kind, isIconOnly: isIconOnly, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

extension ButtonStyle where Self == LumenButtonStyle {
    static var lumenPrimary: LumenButtonStyle { LumenButtonStyle(kind: .primary) }
    static var lumenSecondary: LumenButtonStyle { LumenButtonStyle(kind: .secondary) }
    /// Circular neutral glass button for a single symbol.
    static var lumenIcon: LumenButtonStyle { LumenButtonStyle(kind: .secondary, isIconOnly: true) }
}

/// The visual of a Lumen button, also used directly as the label of `Menu`s (with `.buttonStyle(.plain)`)
/// so menus and buttons in one row match exactly. Height follows `controlSize`: small 24, regular 28, large 34.
struct ChromeLabel<Label: View>: View {
    var kind: ChromeKind = .secondary
    var isIconOnly = false
    var isPressed = false
    @ViewBuilder var label: Label
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var height: CGFloat {
        switch controlSize {
        case .mini, .small: 24
        case .large, .extraLarge: 34
        default: 28
        }
    }

    private var shape: AnyShape { isIconOnly ? AnyShape(Circle()) : AnyShape(Capsule()) }

    var body: some View {
        label
            .labelStyle(ChromeLabelStyle())
            .font(.system(size: height >= 34 ? 13 : 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(kind == .primary ? Theme.Ink.onLight : Theme.Ink.primary)
            .padding(.horizontal, isIconOnly ? 0 : (height >= 34 ? 16 : (height <= 24 ? 10 : 13)))
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .frame(width: isIconOnly ? height : nil)
            .background { background }
            .contentShape(shape)
            .accessibilityElement(children: .combine)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : Theme.Motion.quick, value: hovering)
            .animation(reduceMotion ? nil : Theme.Motion.quick, value: isPressed)
    }

    @ViewBuilder
    private var background: some View {
        let lit = hovering && isEnabled
        switch kind {
        case .primary:
            shape
                .fill(Color.white.opacity(lit ? 1 : 0.9))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        case .secondary:
            Color.clear
                .glassEffect(.regular, in: shape)
                .overlay(shape.fill(Color.white.opacity(lit ? 0.09 : 0)))
        }
    }
}

/// A glass capsule of options with an off-white selected segment — 28 pt tall, so it lines up with
/// regular `ChromeLabel` buttons and menus in the same row.
struct GlassSegmentedControl<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: LocalizedStringKey
        var symbol: String?
    }

    @Binding var selection: Value
    let options: [Option]
    var showsTitles = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                segment(option)
            }
        }
        .padding(2)
        .background { Color.clear.glassEffect(.regular, in: Capsule()) }
        .animation(Theme.Motion.snappy, value: selection)
    }

    private func segment(_ option: Option) -> some View {
        let selected = selection == option.value
        return Button {
            selection = option.value
        } label: {
            HStack(spacing: 6) {
                if let symbol = option.symbol {
                    Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold))
                }
                if showsTitles { Text(option.title).lineLimit(1) }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected ? Theme.Ink.onLight : Theme.Ink.secondary)
            .padding(.horizontal, showsTitles ? 12 : 0)
            .frame(minWidth: 30, minHeight: 24, maxHeight: 24)
            .background(Capsule().fill(selected ? Color.white.opacity(0.9) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text(option.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ChromeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: Flow Layout

/// Left-aligned wrapping flow layout for chips that must never clip at narrow widths.
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
