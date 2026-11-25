# Lumen · Design System

> Reference for Lumen's macOS 26 interface (T12, reworked in T30). Every colour, type size, spacing step, radius and shared component lives in [`Lumen/UI/Components/Theme.swift`](../Lumen/UI/Components/Theme.swift). Views use `Theme` tokens and the shared components below instead of raw opacities, radii or one-off layouts.

## 1. Direction: a gallery after dark

The wallpaper is the artwork; the app is the room it hangs in.

- **The room takes the artwork's colour.** The window backdrop is a blurred, brightness-normalised echo of the wallpaper on the desktop (or the one being inspected), so every page carries its tint without any part of it competing with text.
- **Chrome dissolves.** Navigation, transport and floating actions are Liquid Glass; content sits on quiet solid surfaces with hairline edges.
- **Type is quiet and wide.** Lumen's signature is the expanded display face for page and section titles and small tracked eyebrows. Wallpaper names use the standard width (see §4).
- **Colour comes from the artwork, not the chrome.** Buttons and chips are neutral: one off-white primary per area, neutral Liquid Glass for the rest, selection shown by luminance. The accent is a muted lavender, kept to switches, sliders, focus and small eyebrows. No saturated colour anywhere in the chrome.

What we take from Wallper: artwork-first layouts, generous spacing, few elements per screen, a list view for the library. What stays Lumen's: wide display type, violet, the stage/caption layout on Home, Smart pause, Studio.

## 2. Atmosphere backdrop

`AmbientBackdrop` draws `ThumbnailCache.atmosphere(for:)`:

1. Downscale the thumbnail to 240 px, Gaussian blur (σ 16), saturation ×1.4.
2. Measure average linear luminance with `CIAreaAverage` (one 1×1 render).
3. Apply an exposure gain that pulls the average to **0.022 linear (≈16 % grey)**, clamped to ×0.08…×2.2: bright art is pulled down, dark art lifted slightly.
4. Clamp every channel to **0.10 linear (≈35 % encoded)** so no hot spot can wash out text.

The view adds a soft radial vignette and two bands (black 34 % at the top under the toolbar, 38 % at the bottom under the Now Playing bar). Result: white body text stays above 7:1 on any wallpaper, including pastel ones (checked against the Bloom preset).

Cost: computed once per wallpaper and cached; static bitmap, no per-frame work.

## 3. Colour

### Accent and status (`Theme`)

| Token | Value | Use |
|---|---|---|
| `accent` | `#8E85D6` dusty lavender (also the `AccentColor` asset) | Switches, sliders, focus rings. Never a button or chip fill |
| `accentInk` | `#C9C2F0` | Eyebrows and small marks on dark; selected Workshop card outline (picked playlist tiles use an off-white outline and disc instead) |
| `playing` | `rgb(0.42, 0.82, 0.62)` | Live dot, "On desktop" |
| `paused` | `rgb(0.94, 0.76, 0.42)` | Non-energy pause, warnings |
| `saving` | `rgb(0.50, 0.82, 0.58)` | Smart pause triggered, already-efficient video |
| `favorite` | `rgb(0.94, 0.47, 0.60)` | Hearts |
| `danger` | `rgb(0.93, 0.42, 0.42)` | Errors |

Status colours are softened versions of the system hues so nothing glows against the dark atmosphere.

### Text (`Theme.Ink`)

Fixed white alphas instead of `.secondary`, so hierarchy is identical over every tint and the secondary step stays readable on colour.

| Token | Alpha | Use |
|---|---|---|
| `primary` | 95 % | Titles, values, body |
| `secondary` | 68 % | Subtitles, captions, inactive chips |
| `tertiary` | 46 % | Labels in spec lists, column headers, hints |
| `quaternary` | 28 % | Placeholders, resting icons |
| `onLight` | `#141414` | Text on the off-white primary button and selected chips |

### Surfaces (`Theme.Surface`)

| Token | Value | Use |
|---|---|---|
| `canvas` | `#090A0B` | Under the atmosphere |
| `base` | white 5.5 % | Panels, tiles, row hover |
| `elevated` | white 8.5 % | Tags, nested wells |
| `hover` / `pressed` | white 12 % / 18 % | Interaction fills inside non-glass controls |
| `stroke` / `strokeHover` | white 8 % / 22 % | Panel hairline / hovered card |
| `divider` | white 8 % | `HairlineDivider` |
| `artworkEdge` | white 9 % | Inner edge on artwork so dark images keep a silhouette |
| `scrim` / `scrimStroke` | black 55 % / white 14 % | Badges over artwork |
| `recessed` | black 26 % | Cards on blurred art (menu bar quick settings) |

## 4. Typography (`Theme.TypeScale`)

**Two families on purpose.** The expanded display face (`Theme.display`) is for app structure — page titles, section titles, eyebrows, stats. **Wallpaper names use the standard width** (`artworkTitle`, `compactArtworkTitle`, `cardTitle`): most titles mix in Chinese or Japanese, which has no expanded cut, and wide Latin next to normal-width Han looks broken.

| Token | Spec | Use |
|---|---|---|
| `heroTitle` | Expanded Bold 40 | Home stage when nothing is playing |
| `pageTitle` | Expanded Semibold 32, tracking −0.3 | Library, Workshop, Studio, Playlists |
| `artworkTitle` | SF Bold 30, tracking −0.4 | Wallpaper name on the Home stage, detail page, Studio editor |
| `compactArtworkTitle` | SF Bold 22 | Menu bar panel |
| `panelTitle` | Expanded Semibold 20 | Empty states, sheet titles, drop overlay |
| `sectionTitle` | Expanded Semibold 17 | Section headers |
| `eyebrow` | Expanded Semibold 10.5, tracking 1.6, uppercase | Kicker above titles (`Eyebrow`) |
| `columnHeader` | SF Semibold 10.5, tracking 0.8, uppercase | List headers (`Eyebrow(isCompact: true)`) |
| `cardTitle` | SF Semibold 14 | Card and panel titles |
| `body` | SF 13.5 | Descriptions |
| `bodyMedium` | SF Medium 13 | Chips, buttons, status lines |
| `caption` | SF 12 | Subtitles, metadata |
| `label` | SF Medium 11.5 | Pills, tags, small captions |
| `micro` | SF Bold 10.5 | Badges on artwork |

Numbers (resolutions, durations, sizes, counts, rates) always use `.monospacedDigit()`.

## 5. Space and layout

4/8 pt grid: `xxs 4 · xs 8 · sm 12 · md 16 · lg 20 · xl 24 · xxl 32`, plus `page 40` (side margin) and `section 48` (between major sections).

| Constraint | Value |
|---|---|
| Gallery pages max width | 1560 |
| Detail page max width | 1180 |
| Inspector column (detail, Studio) | 320 |
| Shelf card width | 300 |
| Minimum window | 1020 × 680 |

`Theme.Layout.inset(for:)` returns the side inset that keeps content inside the max width; Home's shelves use it as `contentMargins` so rows start on the page margin and scroll out to the window edge.

Grids: adaptive 280–440 pt columns, 24 pt gutters, 32 pt row spacing.

## 6. Radii

`xs 6 · sm 10 · md 12 · lg 14 (gallery cards) · xl 20 (panels) · xxl 24 (hero frames, stage, empty states)`. Nested shapes are concentric: inner = outer − padding. The Now Playing thumbnail is a capsule so its curve follows the bar.

## 7. Buttons

System `.glass` / `.glassProminent` buttons take the environment `.tint`, which turned every secondary action into a saturated violet pill. Content buttons therefore use Lumen's own styles (`LumenButtonStyle`, `ChromeLabel` in `Theme.swift`); only toolbar items keep the system glass.

| Style | Look | Use |
|---|---|---|
| `.lumenPrimary` | Off-white capsule (white 90 %, 100 % on hover), near-black text, soft shadow | The single most important action of an area: Set as Wallpaper, Customize, Download from Steam, New Playlist |
| `.lumenSecondary` | Neutral Liquid Glass capsule, white text, light wash on hover | Everything else |
| `.lumenIcon` | Neutral glass circle | Favourite, pause, refresh, more |
| `ChromeLabel { … }` | The same visual for `Menu` labels (with `.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)`) | Sort, category, interval, "more" menus — so menus and buttons in one row match |

Heights follow `controlSize`: small 24, regular 28, large 34. A row of controls uses one size; page action rows use `.large`. With several displays, Set as Wallpaper is the primary button plus a small glass display-picker menu beside it.

## 8. Components

| Component | What it is |
|---|---|
| `Eyebrow` | Tracked uppercase kicker; `isCompact` for table headers |
| `PageHeader` | Eyebrow + page title + subtitle + trailing accessory |
| `SectionTitle`, `SectionLink` | Section header; quiet "See all ›" link |
| `LumenPanel` | The one container for settings-like content: `IconWell`, title, optional subtitle and accessory, content. Used by Position & Zoom, Customize, About |
| `InfoRow`, `HairlineDivider` | Label/value spec rows and separators (About panel) |
| `FilterChip` | 28 pt tall. `.standard`: translucent capsule, selected = off-white with dark text. `.quiet`: text-only until selected (white 18 %), for secondary rows (categories, displays) |
| `IconWell` | Neutral by default (white glyph on white 8 %); tinted only to report a state (Smart pause triggered → green) |
| `artworkFrame()` | Clip + edge hairline + grounded shadow + 1.02× hover lift for every artwork card; optional highlight (on desktop, selected Workshop card, picked playlist tile) |
| `ArtBadge`, `DisplayStatusPill`, `StatusDot` | High-contrast labels over artwork |
| `EmptyStatePanel` | Icon well, title, message, optional action in a dashed drop zone |
| `WallpaperDescriptor` | One place that words a wallpaper: kind, subtitle ("Scene · Anime"), spec line, resolution, length, size, source |

## 9. Page patterns

- **Home — the stage.** The focused display's wallpaper framed like a print (16:10, radius 24, live preview on hover after 350 ms) with a caption column bottom-aligned beside it: greeting eyebrow, title, subtitle, status, actions (Customize · Surprise Me · pause · more), display switcher when several displays are connected, then three stats. Below: Recently added, Favorites, Rendered live shelves, and Smart pause: exactly four equal tiles (icon + switch on top, rule and live status below, fixed 112 pt height, single-line text) so the row always lines up.
- **Library.** Header, type chips (`.standard`), sort menu, grid/list switch (`@AppStorage("libraryLayout")`, a glass capsule with an off-white selected segment), category chips (`.quiet`); every control in the row is 28 pt. The list shows #, artwork, title + source, type, category, resolution, length, size, favourite; Title, Length and Size headers sort (click again for newest first).
- **Detail.** Live preview spanning the content column so its edges align with everything below; height follows the window (cinematic crop on short windows, never taller than 16:9) so actions stay above the fold; the artwork's glow behind it; eyebrow (kind · category), editable title with the pencil right after the text, spec line, glass action group and display status. Below: adjustments (Position & Zoom, Customize) on the left, About and Optimization in a 320 pt column on the right; About takes the full width when nothing is adjustable (web pages).
- **Studio editor.** Preview left with a "More to try" strip of the other shaders under it (code editor replaces it when open); inspector panels right.
- **Now Playing bar.** Glass capsule: pill thumbnail, title, status, then previous/pause/next, Surprise Me, sound, speed. Hidden on the Workshop tab, where the pager and the preview panel run to the bottom edge.
- **Playlists.** Header, then — while a rotation runs — a stage like Home's: the wallpaper on screen (16:10, radius 24, title over a bottom gradient, "Rotating now" badge) beside a caption column that reaches the page's right edge so its Edit button lines up under the header's New Playlist: eyebrow, playlist name, summary, a 4 pt bar filling towards the next change, previous / next / Stop, and an Up Next strip (four fixed slots, click to show one now). Below, "All Playlists": each playlist is a **deck** — its first wallpaper as a 16:10 front card with the next two peeking above it (scaled 94 % / 88 %, darkened, fanning out on hover; blank prints when there are fewer). Every deck reserves the same 20 pt headroom, so front cards and the dashed "+" tile share one top edge. Play/Stop appears on hover; the context menu has Start, Edit and Delete.
- **Playlist editor.** Album-style header: a 300 pt deck, then eyebrow, editable name, summary and one row of controls (Start Rotation or Stop, interval menu, Shuffle switch, delete at the far right), plus the next-change bar while it rotates. "In This Rotation" is a track list in fixed columns (#, artwork, title + kind, resolution, length, remove on hover, drag handle); drag a row onto another to reorder, or use Move Up / Move Down / Remove in its context menu. The wallpaper on screen shows a green dot instead of its number. "Add from Library" below is the whole library; picked tiles carry an off-white numbered disc.
- **Workshop.** Two modes in a `GlassSegmentedControl`: *Steam Workshop* (default) and *On This Mac*.
  - *Steam Workshop* browses the live Workshop in Lumen's layout: a 40 pt search capsule (mirrors the toolbar search), type chips, a sort menu (Trending with a period from Today to All Time, Top Rated, Most Subscribed, Newest, Recently Updated; "Best Match" while searching), a Filters menu (resolution, features such as Approved / Audio Responsive / Customizable, content rating — Everyone by default, Mature never shown) with a count badge, refresh, the preview-sidebar toggle, then all 25 genres as quiet chips.
  - Results come **a page at a time** (30 per page, Steam caps browsing at 1000 pages): a compact ‹ 3 / 1000 › above the grid and a full pager below (first, last, two either side of the current page, a "Go to" field). A new page scrolls back to the top; recently viewed pages are cached so going back is instant.
  - Cards show the first frame and play the animated preview on hover (350 ms), with a white Download pill on hover and a status badge (Queued / % / Adding… / In Library) top-right.
  - **Preview sidebar** (on by default, `@AppStorage("workshopInspector")`): a 340 pt Liquid Glass panel floating at the right edge, independent of the grid's scrolling. It is inset 20 pt on the top, right and bottom; the top is the page header's top edge, and the grid's bottom padding is the same 20 pt so the pager meets the panel's bottom edge. A click selects a card (accent outline) and shows it there: the preview whole over a blurred fill of itself, title, stars and votes, subscribers / favorited / size / resolution / updated, a full-width Download (or progress / Open) with View on Steam, tags and description. With the sidebar hidden, a click opens the same details in a sheet.
  - **Downloads in the toolbar**: a progress ring with the running count (a green check when all are done) appears while on the Workshop tab, and anywhere while something is still downloading; it opens a popover list with thumbnails, progress, Show, Clear Finished and the account sheet.
  - *On This Mac* is the earlier view of projects already downloaded: kind in the caption, "In Library" badge, Add / Open on hover.
- **Menu bar panel.** Forced dark (`.environment(\.colorScheme, .dark)`; the menu bar window otherwise follows the system appearance). 300 × 540: the artwork fills the whole panel and its lower half melts into the artwork's atmosphere (masked gradient), so text sits on calm colour. Top: wordmark + version, two glass icon buttons. Bottom: category eyebrow, title (two lines), spec line, transport (64 pt off-white pause disc between plain heart and shuffle/next icons), then a footer with the display chip (a menu only when several displays are connected) and a small glass "Open Lumen ↗". No settings in the panel — they live in the app.

## 10. Liquid Glass rules

- Glass for floating controls: toolbar, Now Playing bar, toasts, actions over artwork and page action rows (`.lumenSecondary` / `.lumenIcon` draw neutral `glassEffect(.regular)` themselves).
- No glass for content: cards, panels, tiles, chips, badges use solid `Surface` fills.
- No glass on glass: controls inside the Now Playing bar use `BarIconButtonStyle`.
- Over bright artwork, badges use `scrim` + `scrimStroke` with white text.

## 11. Motion and energy

- Micro-interactions `.snappy(0.22)` / `.easeOut(0.14)`; page switches `.smooth(0.24)`; backdrop cross-fade 0.65 s.
- Reduce Motion removes lifts, offsets and pulsing; only opacity changes remain.
- Nothing animates continuously. Atmosphere, glow and thumbnails are cached static bitmaps decoded off the main thread. Live previews start only on hover (350 ms delay) or on the detail page, and stop when the view goes away.

## 12. Localisation and resilience

- Display English (page titles, section titles, eyebrows, stats labels) stays English with `Text(verbatim:)`. Everything operational — buttons, menus, statuses, table headers, About labels — is localised (zh-Hans in `Localizable.xcstrings`).
- Filter rows scroll horizontally; titles truncate on one line in cards and rows; the detail title truncates but stays editable in full.
- Bottom padding on every scroll view clears the Now Playing bar (the bar is a `safeAreaBar`, so pages without it simply get the space back).
- The toolbar's section picker is `.fixedSize()`: its glass shell hugs the segments, with no empty margin at either end.
- Clicking anywhere outside the toolbar search field ends editing there (`SearchFieldFocus`), as in Safari and Finder.
- Captions sit flush with the artwork edge (no extra inset); rows of controls share one height; tiles have fixed heights so wrapping can't break a row.
- Content scrolling under the toolbar gets the soft scroll-edge effect (`.scrollEdgeEffectStyle(.soft, for: .top)` on the page).

## 13. Known limits

- Many Workshop scenes ship only a 160–256 px preview GIF, so their cards and the Home stage are soft. Fixing that needs a crisp poster frame rendered from the scene (see the T32 entry on the board in `docs/STATUS.md`); the layouts above avoid full-bleed artwork for this reason.
