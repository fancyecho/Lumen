import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var router = model.router
        @Bindable var bindableModel = model

        ZStack {
            AmbientBackdrop(focus: focusedWallpaper)
            page
                .id(pageID)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
        }
        .animation(reduceMotion ? nil : Theme.Motion.smooth, value: pageID)
        .safeAreaBar(edge: .bottom) {
            NowPlayingBar().padding(.bottom, Theme.Space.sm)
        }
        .overlay(alignment: .top) {
            ToastOverlay().padding(.top, Theme.Space.xs)
        }
        .overlay {
            if isDropTargeted { DropTargetOverlay().transition(.opacity) }
        }
        .animation(reduceMotion ? nil : Theme.Motion.quick, value: isDropTargeted)
        .toolbar { toolbarContent }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(text: $router.searchText, placement: .toolbar, prompt: "Search wallpapers")
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

    private var focusedWallpaper: Wallpaper? {
        switch model.router.route {
        case .wallpaper(let id), .studio(let id): model.library.wallpaper(id: id)
        default: nil
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if model.router.route != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.router.back()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back")
            }
        }

        ToolbarItem(placement: .principal) {
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
            .frame(minWidth: 360, idealWidth: 420, maxWidth: 450)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            DisplaysMenu()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Videos, Projects or Folders…") { model.isImporterPresented = true }
                Button("Web Page…") { model.isWebPageSheetPresented = true }
                Divider()
                Button("Wallpaper Engine Projects on This Mac") { model.router.show(.workshop) }
                Button("Download from Steam Workshop…") { model.isSteamPanelPresented = true }
            } label: {
                Label("Add Wallpaper", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            } primaryAction: {
                model.isImporterPresented = true
            }
            .menuStyle(.button)
            .buttonStyle(.glassProminent)
            .fixedSize()
            .help("Add videos, Wallpaper Engine projects or web pages (⌘O)")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func windowAppeared() {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "LumenDebugMenuPreview") {
            openWindow(id: SceneID.menuPreview)
        }
        if let dir = UserDefaults.standard.string(forKey: "LumenDebugCaptureDir"), !dir.isEmpty {
            Task { @MainActor in await runDebugCapture(to: URL(fileURLWithPath: dir)) }
        }
        #endif
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
                Image(systemName: toast.symbol).foregroundStyle(Theme.accent)
                Text(toast.message)
                    .font(Theme.TypeScale.bodyMedium)
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
            VStack(spacing: Theme.Space.sm) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Drop to add to your library")
                    .font(Theme.display(22))
                Text("Videos · Wallpaper Engine projects · HTML folders")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 44)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                    .fill(Theme.Surface.canvas.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
