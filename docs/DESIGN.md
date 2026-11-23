# Lumen · Design System

> Reference specification for Lumen's macOS 26 interface (T12). All color, typography, spacing, radius, surface, and motion tokens live in [`Lumen/UI/Components/Theme.swift`](../Lumen/UI/Components/Theme.swift). Views must reference `Theme` tokens rather than scattering raw opacities, corner radii, or spacing numbers.

## 1. Visual Direction & Brand Identity

Lumen draws inspiration from Wallper's calm, gallery-first macOS aesthetic—deep neutral surfaces where wallpaper artwork is the hero—while preserving Lumen's distinct visual signature:

- **Wide expanded display typography** (`Font.Width.expanded`) for editorial page headers, hero headlines, and section titles.
- **Restrained signature violet accent** (`Theme.accent`) reserved strictly for primary CTAs, selected filters, eyebrow labels, and active controls.
- **Native macOS 26 Liquid Glass** (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)` / `.glassProminent`) for floating controls and overlays, never stacked glass-on-glass.
- **Signature surfaces**: Home's *"On your displays"* + *"Smart pause"* live status hub, floating bottom *Now Playing* capsule, and live GPU *Studio*.

## 2. Color Palette

Lumen's main window is dark-first (`.preferredColorScheme(.dark)`). Sheets and panels that present inside the main window inherit the same dark palette and `.tint(Theme.accent)`.

### Neutral Canvas & Surfaces (`Theme.Surface`)

| Token | Value | Role |
|---|---|---|
| `Theme.Surface.canvas` | `rgb(0.045, 0.048, 0.060)` (`#0B0C0F`) | Deep neutral obsidian window base (zero purple cast) |
| `Theme.Surface.base` | `white @ 4.5%` | Standard card/panel fill (`PolicyTile`, `PropertiesPanel`, `FramingControls`, `OptimizationCard`, `SteamPanel` account box) |
| `Theme.Surface.elevated` | `white @ 7.5%` | Chips, icon wells, secondary rows, nested containers |
| `Theme.Surface.hover` | `white @ 11.5%` | Interactive hover fill inside non-glass surfaces |
| `Theme.Surface.pressed` | `white @ 17%` | Active press feedback inside glass bars (`BarIconButtonStyle`) |
| `Theme.Surface.mediaFill` | `white @ 4%` | Neutral placeholder beneath loading 16:9 / 16:10 artwork |
| `Theme.Surface.stroke` | `white @ 8.5%` | Resting 1pt hairline border on cards and chips |
| `Theme.Surface.strokeHover` | `white @ 24%` | Hovered card / interactive container border |
| `Theme.Surface.divider` | `white @ 10%` | Hairline separators between inspector rows and bar groups |
| `Theme.Surface.scrim` | `black @ 60%` | High-contrast backdrop for badges drawn over bright artwork |

### Ambient Backdrop Discipline

`AmbientBackdrop` echoes the active (or inspected) wallpaper using a pre-blurred static bitmap (zero per-frame cost), **heavily restrained** so bright wallpapers never wash out toolbar or body text:

- Wallpaper echo layer capped at `0.34` opacity over `Theme.Surface.canvas`.
- Vertical dark scrim: `black @ 52%` (top, keeps toolbar legible) → `black @ 76%` (mid) → `black @ 93%` (bottom, keeps scroll content & `NowPlayingBar` crisp).

### Accent & Semantic Status (`Theme`)

| Token | Value | Usage |
|---|---|---|
| `Theme.accent` | `rgb(0.52, 0.44, 1.0)` (`#8570FF`) | Primary CTA tint, active `FilterChip`, eyebrow labels, focused outlines. Never used as large page backgrounds. |
| `Theme.accentSoft` | `accent @ 15%` | Small circular icon wells only (`34–44pt`) |
| `Theme.playing` | `rgb(0.30, 0.86, 0.56)` | Live playback indicator dot, active desktop badge, completed downloads |
| `Theme.paused` | `rgb(0.98, 0.74, 0.28)` | Non-energy pause state, warning banners (`AssetsNotice`) |
| `Theme.saving` | `rgb(0.45, 0.86, 0.48)` | Smart pause energy-saving trigger, HEVC optimization complete |
| `Theme.favorite` | `rgb(0.98, 0.36, 0.54)` | Favorite heart icon |
| `Theme.danger` | `rgb(0.96, 0.36, 0.38)` | Inline errors and destructive states |

## 3. Typography Scale (`Theme.TypeScale`)

| Token | Spec | Usage |
|---|---|---|
| `heroTitle` | Expanded Bold `46pt` | Home hero headline (`"Your desktop,\nin motion."`) |
| `pageTitle` | Expanded Bold `34pt` | Top-level page titles (`Library`, `Workshop`, `Studio`, `Playlists`) |
| `detailTitle` | Expanded Bold `30pt` | Wallpaper detail editable title (multiline-safe / clean ellipsis) |
| `sectionTitle` | Expanded Semibold `18pt` | Section headers (`"On your displays"`, `"Recently added"`, `"Smart pause"`) |
| `displayCardTitle` | Expanded Semibold `16pt` | Wallpaper title overlaid on `DisplayCard` scrim |
| `eyebrow` | Expanded Semibold `11pt`, tracking `1.8` | Uppercase section/page kicker in `Theme.accent` |
| `cardTitle` | System Semibold `14pt` | Card titles, inspector section headers, panel titles |
| `body` | System Regular `13.5pt` | Descriptions, inspector labels, sheet copy |
| `bodyMedium` | System Medium `13pt` | Chips, buttons, status lines |
| `caption` | System Regular `12pt` | Subtitles, metadata, secondary hints |
| `micro` | System Bold `10.5pt` | Artwork badges (`4K`, `HDR`, `Scene`, `On desktop`) |

Numeric readouts (resolutions, durations, counts, playback rate, slider values, file sizes) always apply `.monospacedDigit()`.

## 4. Spacing Grid (`Theme.Space`)

All padding, stack spacing, and grid gutters follow a **4/8pt modular scale**:

| Token | Points | Typical Use |
|---|---|---|
| `xxs` | `4` | Tight icon-text pair, stacked caption spacing |
| `xs` | `8` | Chip row gap, badge gap, toolbar button spacing |
| `sm` | `12` | Compact card inner spacing, row gaps, badge inset |
| `md` | `16` | Standard card padding, section header-to-content gap |
| `lg` | `20` | Large panel padding (`FramingControls`, `PropertiesPanel`, `OptimizationCard`), grid horizontal gutter |
| `xl` | `24` | Page header-to-body gap, grid vertical row spacing |
| `xxl` | `32` | Major vertical section spacing, bottom scroll inset |
| `page` | `36` | Horizontal page margin (balances generous gallery framing with `1020px` min-width comfort) |

Maximum content column width: `1480pt` for gallery pages (`Home`, `Library`, `Workshop`), `1120pt` for focused detail pages (`WallpaperDetailView`).

## 5. Corner Radii & Concentric Rules (`Theme.Radius`)

Nested rounded shapes follow the concentric formula `innerRadius = max(4, outerRadius - padding)`:

| Token | Points | Role |
|---|---|---|
| `xs` | `6` | Mini thumbnails, display mock screen (`12pt` bezel − `6pt` padding = `6pt`) |
| `sm` | `10` | Inner rows (`DownloadRow`), compact previews, `NowPlayingBar` mini-frame |
| `md` | `12` | Display mock bezel, compact containers |
| `lg` | `16` | Grid artwork cards (`WallpaperCard`, `WorkshopCard`), `PolicyTile`, notices |
| `xl` | `20` | Primary feature cards (`DisplayCard`, `FramingControls`, `PropertiesPanel`, `OptimizationCard`) |
| `xxl` | `24` | Detail hero preview frame, empty-state drop zones |

## 6. Cards & Artwork Proportions

- **Gallery cards (`WallpaperCard`, `WorkshopCard`)**: Strict `16:9` aspect ratio. Artwork **must** be placed inside `.overlay { Image... }.clipped()` on a `16:9` layout container so square (`512×512`) Workshop previews never distort the grid into 1:1 squares.
- **Display card (`DisplayCard`)**: `16:10` aspect ratio reflecting Mac displays, capped at `minWidth: 380, maxWidth: 580` in single-display layout so *Smart pause* sits balanced beside it. Always includes a bottom gradient scrim (`clear → black @ 72%`) under the overlaid wallpaper title.
- **Detail hero (`WallpaperDetailView`)**: `16:9` frame with `maxHeight: 440` so the title, metadata chips, primary action bar, and the start of controls remain visible above the fold at `1280×840` without colliding with `NowPlayingBar`.
- **Card hover treatment**: Subtle border brightening (`stroke → strokeHover`), deeper grounded shadow, bottom vignette scrim behind hover quick actions, and gentle `1.015×` lift (disabled when `accessibilityReduceMotion` is enabled).

## 7. Liquid Glass Rules

- **Use Liquid Glass for floating controls & toolbars**:
  - System window toolbar (native segmented switcher, `DisplaysMenu`, `Settings`, `.glassProminent` *"Add Wallpaper"*).
  - Floating bottom `NowPlayingBar` (`glassEffect(.regular, in: .capsule)`).
  - Floating `ToastOverlay` (`glassEffect(.regular, in: .capsule)`).
  - Action buttons floating over artwork (`WallpaperCard` quick actions, `WorkshopCard` Add/In Library) and primary page action bars—grouped inside `GlassEffectContainer(spacing: 8)`.
- **Do NOT use Liquid Glass for**:
  - Content cards, inspector panels, `PolicyTile`, `FilterChip`, `MetaChip`, or `ArtBadge` (use solid `Theme.Surface` fills + hairline strokes).
  - Controls already inside a glass container (`NowPlayingBar` transport controls use `BarIconButtonStyle` with solid translucent hover circles—never glass on glass).
- **Readability over bright artwork**: Any badge (`ArtBadge`, `DisplayStatusPill`) over artwork uses `Theme.Surface.scrim` (`black @ 60%`) + `white @ 14%` hairline stroke and pure white text.

## 8. Motion & Energy Budget

- **Restrained & interruptible**: Micro-interactions use `.snappy(duration: 0.22)` / `.easeOut(duration: 0.14)`. Page switches use `.smooth(duration: 0.24)`.
- **Reduce Motion**: Check `@Environment(\.accessibilityReduceMotion)` on page transitions, hover scale lifts, backdrop fades, and `StatusDot` pulsing. When enabled, disable scale/offset/pulse animations and fall back to instant or gentle opacity changes.
- **Zero idle background cost**:
  - No timers or continuous `repeatForever` animations when the window is closed or `accessibilityReduceMotion` is enabled (`StatusDot` stops pulsing when not visible).
  - `AmbientBackdrop` and `AmbientGlow` render static, pre-blurred bitmaps cached by `ThumbnailCache`.
  - Grid thumbnails decode asynchronously off the main thread (`ThumbnailCache` / `WorkshopThumbnails`) inside `LazyVGrid` / `LazyHStack`.

## 9. Localization & Responsive Layout

- **Copy split**: Editorial/display English titles and eyebrows stay English with `Text(verbatim:)` (e.g., `"Your desktop,\nin motion."`, `"On your displays"`, `"Smart pause"`, `"LIBRARY"`, `"WALLPAPER ENGINE"`). Operational labels, buttons, menus, status pills, and subtitles use localized keys (English source in code; zh-Hans filled in T11).
- **Minimum window (`1020×680`) & zh-Hans resilience**:
  - Filter chip strips (`LibraryView`, `WorkshopView`) and category rows scroll horizontally (`ScrollView(.horizontal, showsIndicators: false)`) with trailing actions pinned so chips never overflow or wrap awkwardly.
  - Detail metadata chips wrap cleanly (`ViewThatFits` / flow layout) rather than clipping in a rigid `HStack`.
  - Editable detail titles use a dedicated title row with explicit layout priority so long Chinese/English titles never smash into the category button.
  - Scroll containers leave enough bottom padding (`Theme.Space.xxl`) so the bottom-most row clears `NowPlayingBar`.
