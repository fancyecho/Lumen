import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var router = model.router
        @Bindable var bindableModel = model

        ZStack {
            AmbientBackdrop(focus: focusedWallpaper)
            page
                .id(pageID)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
                // The room runs up behind the toolbar; the system edge effect would draw a solid band
                // across it (at rest too, on macOS 27).
                .scrollEdgeEffectHidden(true, for: .top)
        }
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: pageID)
        .safeAreaBar(edge: .bottom) {
            if showsNowPlaying {
                NowPlayingBar()
                    .padding(.bottom, Theme.Space.sm)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: showsNowPlaying)
        .overlay(alignment: .top) {
            ToastOverlay().padding(.top, Theme.Space.xs)
        }
        .overlay {
            if isDropTargeted { DropTargetOverlay().transition(.opacity) }
        }
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: isDropTargeted)
        .toolbar { toolbarContent }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // ⌘F, as the system search item had.
        .background {
            Button("Search wallpapers") { isSearchFocused = true }
                .keyboardShortcut("f")
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importFiles(urls)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .fileImporter(
            isPresented: $bindableModel.isImporterPresented,
            allowedContentTypes: MediaInspector.supportedTypes + [.folder, .html, .json],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .sheet(isPresented: $bindableModel.isWebPageSheetPresented) {
            AddWebPageSheet()
        }
        .sheet(isPresented: $bindableModel.isSteamPanelPresented) {
            SteamPanel()
        }
        .confirmationDialog(
            "Delete “\(model.pendingDeletion?.title ?? "")”?",
            isPresented: Binding(
                get: { model.pendingDeletion != nil },
                set: { if !$0 { model.pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let wallpaper = model.pendingDeletion { model.delete(wallpaper) }
                model.pendingDeletion = nil
            }
        } message: {
            Text("Lumen's copy of this wallpaper is removed. The original file you imported is not touched.")
        }
        .frame(minWidth: Theme.Layout.minWindowWidth, minHeight: Theme.Layout.minWindowHeight)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear(perform: windowAppeared)
        .onDisappear(perform: windowDisappeared)
        .onChange(of: router.searchText) { _, text in
            if !text.isEmpty, (router.tab != .library && router.tab != .workshop) || router.route != nil {
                router.show(.library)
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch model.router.route {
        case .wallpaper(let id): WallpaperDetailView(wallpaperID: id)
        case .studio(let id): StudioEditorView(wallpaperID: id)
        case .playlist(let id): PlaylistEditorView(playlistID: id)
        case nil:
            switch model.router.tab {
            case .home: HomeView()
            case .library: LibraryView()
            case .workshop: WorkshopView()
            case .studio: StudioView()
            case .playlists: PlaylistsView()
            }
        }
    }

    private var pageID: String {
        model.router.route.map { String(describing: $0) } ?? model.router.tab.rawValue
    }

    /// The Workshop is a store front with its own pager and preview sidebar running to the bottom
    /// edge; a transport bar floating over them only gets in the way, so it steps aside there.
    private var showsNowPlaying: Bool {
        !(model.router.route == nil && model.router.tab == .workshop)
    }

    private var focusedWallpaper: Wallpaper? {
        switch model.router.route {
        case .wallpaper(let id), .studio(let id): model.library.wallpaper(id: id)
        default: nil
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Navigation sits on the leading edge and actions on the trailing one, so the bar balances
        // instead of crowding the centre and right — and the tabs never butt up against the action
        // buttons, where their glass shapes melted into one. Back keeps its slot (dimmed on top-level
        // pages) so the tabs don't jump sideways every time a detail page opens or closes.
        ToolbarItem(placement: .navigation) {
            ToolbarBackButton(isEnabled: model.router.route != nil) { model.router.back() }
                // Its own glass circle with a real gap: inside the shared toolbar background it
                // melted into the tab bar beside it (a fixed spacer doesn't apply on the leading edge).
                .padding(.trailing, Theme.Space.xs)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .navigation) {
            Picker("Section", selection: Binding(
                get: { model.router.tab },
                set: { model.router.show($0) }
            )) {
                ForEach(AppTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Natural size, so the toolbar's glass shell hugs the segments instead of padding a
            // fixed-width frame with empty space at both ends.
            .fixedSize()
        }

        // macOS lines toolbar items up from the leading edge; this carries the rest to the trailing
        // edge as one group: search, Add Wallpaper, then display and settings in the corner. (The
        // system search item always claimed its own region at the far right, stranding these
        // buttons mid-bar, so search is Lumen's own field.)
        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .automatic) {
            ToolbarSearchField(
                text: Binding(get: { model.router.searchText }, set: { model.router.searchText = $0 }),
                isFocused: $isSearchFocused
            )
        }

        ToolbarSpacer(.fixed)

        ToolbarItem(placement: .automatic) {
            Menu {
                Button("Videos, Projects or Folders…") { model.isImporterPresented = true }
                Button("Web Page…") { model.isWebPageSheetPresented = true }
                Divider()
                Button("Browse the Steam Workshop") { showWorkshop(.steam) }
                Button("Wallpaper Engine Projects on This Mac") { showWorkshop(.local) }
            } label: {
                Label("Add Wallpaper", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            } primaryAction: {
                model.isImporterPresented = true
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Add videos, Wallpaper Engine projects or web pages (⌘O)")
        }

        if showsDownloads {
            ToolbarItem(placement: .automatic) {
                DownloadsToolbarButton()
            }
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup(placement: .automatic) {
            DisplaysMenu()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }
    }

    /// Workshop downloads in the toolbar: always on the Workshop tab once there are any, elsewhere
    /// only while something is still downloading.
    private var showsDownloads: Bool {
        let downloads = model.steam.downloads
        guard !downloads.isEmpty else { return false }
        return model.router.tab == .workshop || downloads.contains { !$0.isFinished }
    }

    private func showWorkshop(_ mode: WorkshopMode) {
        // The Workshop page keeps its mode in this key (@AppStorage there).
        UserDefaults.standard.set(mode.rawValue, forKey: "workshopSource")
        model.router.show(.workshop)
    }

    private func windowAppeared() {
        NSApp.setActivationPolicy(.regular)
        SearchFieldFocus.install()
        #if DEBUG
        // Launch flags live in the argument domain for the whole process, and this runs every time
        // the window reappears (menu bar, Dock). Applying them again snapped a window the person had
        // resized back to the launch size — suddenly narrower — so they apply to the first window only.
        guard !DebugLaunchFlags.applied else { return finishAppearing() }
        DebugLaunchFlags.applied = true
        if UserDefaults.standard.bool(forKey: "LumenDebugMenuPreview") {
            openWindow(id: SceneID.menuPreview)
        }
        // `-LumenDebugWindowSize 1280x840` opens the main window at an exact size for layout checks.
        let requested = (UserDefaults.standard.string(forKey: "LumenDebugWindowSize") ?? "").split(separator: "x").compactMap { Double($0) }
        if requested.count == 2 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.windows.first { $0.isVisible && $0.level == .normal && $0.frame.width >= 900 }?
                    .setContentSize(NSSize(width: requested[0], height: requested[1]))
            }
        }
        if let dir = UserDefaults.standard.string(forKey: "LumenDebugCaptureDir"), !dir.isEmpty {
            Task { @MainActor in await runDebugCapture(to: URL(fileURLWithPath: dir)) }
        }
        #endif
        finishAppearing()
    }

    private func finishAppearing() {
        if model.launchedAsLoginItem {
            // Started by launch-at-login: run quietly from the menu bar.
            model.launchedAsLoginItem = false
            Task { @MainActor in dismissWindow(id: SceneID.main) }
        }
    }

    #if DEBUG
    private func runDebugCapture(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rawSuffix = UserDefaults.standard.string(forKey: "LumenDebugCaptureSuffix") ?? ""
        let suffix = rawSuffix.isEmpty ? "" : (rawSuffix.hasPrefix("-") ? rawSuffix : "-\(rawSuffix)")
        let mainWindow = { NSApp.windows.first { $0.isVisible && $0.level == .normal && $0.frame.width >= 900 } }
        func snap(_ name: String, sheet: Bool = false) {
            guard let win = mainWindow() else { return }
            let targetWin = sheet ? (win.attachedSheet ?? win) : win
            guard let view = targetWin.contentView?.superview ?? targetWin.contentView else { return }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appending(path: "\(name)\(suffix).png"))
            }
        }
        try? await Task.sleep(for: .seconds(2.2))
        mainWindow()?.setContentSize(NSSize(width: 1280, height: 840))
        try? await Task.sleep(for: .milliseconds(400))
        model.router.show(.home)
        try? await Task.sleep(for: .milliseconds(900))
        snap("home")

        model.router.show(.library)
        try? await Task.sleep(for: .milliseconds(1200))
        snap("library")

        model.router.show(.workshop)
        try? await Task.sleep(for: .seconds(2.2))
        snap("workshop")

        if suffix.isEmpty {
            model.isSteamPanelPresented = true
            try? await Task.sleep(for: .milliseconds(900))
            snap("steam", sheet: true)
            model.isSteamPanelPresented = false
            try? await Task.sleep(for: .milliseconds(500))
        }

        if let scene = model.library.scenes.max(by: { ($0.package?.properties.count ?? 0) < ($1.package?.properties.count ?? 0) }) {
            model.router.open(.wallpaper(scene.id))
            try? await Task.sleep(for: .seconds(2.0))
            snap("detail-scene")
        }
        if suffix.isEmpty, let video = model.library.videos.first {
            model.router.open(.wallpaper(video.id))
            try? await Task.sleep(for: .milliseconds(1200))
            snap("detail-video")
        }
        if suffix.isEmpty {
            model.router.show(.studio)
            try? await Task.sleep(for: .milliseconds(900))
            snap("studio")
            model.router.show(.playlists)
            try? await Task.sleep(for: .milliseconds(900))
            snap("playlists")
            mainWindow()?.setContentSize(NSSize(width: 1020, height: 680))
            model.router.show(.home)
            try? await Task.sleep(for: .milliseconds(700))
            snap("home-min")
            model.router.show(.library)
            try? await Task.sleep(for: .milliseconds(700))
            snap("library-min")
        }
        NSApp.terminate(nil)
    }
    #endif

    private func windowDisappeared() {
        if model.settings.dockIconMode == .whileWindowOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

#if DEBUG
@MainActor
private enum DebugLaunchFlags {
    static var applied = false
}
#endif

/// Ends editing in the toolbar search field when the person clicks anywhere else in the window.
///
/// AppKit only moves keyboard focus when another text field is clicked, so after one search the
/// field kept its focus ring — looking like it still waited for input — until the window closed.
/// Safari and Finder let a click on the page dismiss the field; this does the same.
@MainActor
enum SearchFieldFocus {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { endSearchIfClickedElsewhere(event) }
            return event
        }
    }

    private static func endSearchIfClickedElsewhere(_ event: NSEvent) {
        // Only the toolbar's search field: toolbar views live beside the content view, not in it,
        // so fields on a page (which end editing the usual way) are left alone.
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField,
              let content = window.contentView, !field.isDescendant(of: content)
        else { return }
        // The frame view is the window's root, so its hit-testing takes window coordinates and
        // covers the toolbar as well as the content.
        let root = window.contentView?.superview ?? window.contentView
        guard let hit = root?.hitTest(event.locationInWindow) else { return }
        if hit === field || hit.isDescendant(of: field) { return }
        // Clicking another field moves focus there by itself.
        if hit is NSTextField || hit is NSTextView { return }
        window.makeFirstResponder(nil)
    }
}

/// The toolbar's search field: magnifier, plain text field, clear button; Escape clears it.
private struct ToolbarSearchField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.Ink.tertiary)
                .accessibilityHidden(true)
            TextField("Search wallpapers", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Ink.primary)
                .focused(isFocused)
                .onExitCommand {
                    text = ""
                    isFocused.wrappedValue = false
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear"))
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(width: 230)
    }
}

/// A 36 pt glass circle like the toolbar's other round buttons; dimmed, not removed, on top-level
/// pages so the tabs beside it keep their place.
private struct ToolbarBackButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.Ink.primary : Theme.Ink.quaternary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color.white.opacity(hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.quick, value: hovering)
        .help("Back")
        .accessibilityLabel(Text("Back"))
    }
}

/// Toolbar menu summarising what every display is doing.
struct DisplaysMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engine = model.engine
        Menu {
            ForEach(engine.displays) { display in
                Section(display.name) {
                    if let id = display.wallpaperID, let wallpaper = model.library.wallpaper(id: id) {
                        let state = display.pauseReason?.title ?? String(localized: "Playing")
                        Button(wallpaper.title + " — " + state) {
                            model.router.open(wallpaper.kind == .shader ? .studio(id) : .wallpaper(id))
                        }
                        Button("Use System Wallpaper") { model.clearWallpaper(on: .display(display.id)) }
                    } else {
                        Text("System wallpaper")
                    }
                }
            }
            Divider()
            Button(engine.userPaused ? "Resume All" : "Pause All") { engine.toggleUserPause() }
                .disabled(!engine.isAnyWallpaperSet)
        } label: {
            Label("Displays", systemImage: engine.displays.count > 1 ? "display.2" : "display")
        }
        .help("Displays")
    }
}

struct ToastOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: toast.symbol).foregroundStyle(Theme.accentInk)
                Text(toast.message)
                    .font(Theme.TypeScale.bodyMedium)
                    .foregroundStyle(Theme.Ink.primary)
                    .lineLimit(2)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm - 2)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.id)
        }
    }
}

struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: Theme.Space.md) {
                IconWell(symbol: "square.and.arrow.down.on.square", size: 60)
                Text("Drop to add to your library")
                    .font(Theme.TypeScale.panelTitle)
                    .foregroundStyle(Theme.Ink.primary)
                Text("Videos · Wallpaper Engine projects · HTML folders")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.secondary)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                    .fill(Theme.Surface.canvas.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [8, 7]))
                    .foregroundStyle(Theme.accentInk.opacity(0.8))
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
