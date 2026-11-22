import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var router = model.router
        @Bindable var bindableModel = model

        ZStack {
            AmbientBackdrop(focus: focusedWallpaper)
            page
                .id(pageID)
                .transition(.opacity.combined(with: .offset(y: 10)))
        }
        .animation(.smooth(duration: 0.32), value: pageID)
        .safeAreaBar(edge: .bottom) {
            NowPlayingBar().padding(.bottom, 14)
        }
        .overlay(alignment: .top) {
            ToastOverlay().padding(.top, 8)
        }
        .overlay {
            if isDropTargeted { DropTargetOverlay().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
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
            allowedContentTypes: MediaInspector.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
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
        .frame(minWidth: 1020, minHeight: 680)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear(perform: windowAppeared)
        .onDisappear(perform: windowDisappeared)
        .onChange(of: router.searchText) { _, text in
            if !text.isEmpty, router.tab != .library || router.route != nil {
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
            .frame(width: 360)
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
            Button {
                model.isImporterPresented = true
            } label: {
                Label("Add Wallpaper", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help("Add videos to your library (⌘O)")
        }
        .sharedBackgroundVisibility(.hidden)
    }

    private func windowAppeared() {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "LumenDebugMenuPreview") {
            openWindow(id: SceneID.menuPreview)
        }
        #endif
        if model.launchedAsLoginItem {
            // Started by launch-at-login: run quietly from the menu bar.
            model.launchedAsLoginItem = false
            Task { @MainActor in dismissWindow(id: SceneID.main) }
        }
    }

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
                            model.router.open(wallpaper.kind == .video ? .wallpaper(id) : .studio(id))
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
            HStack(spacing: 9) {
                Image(systemName: toast.symbol).foregroundStyle(Theme.accent)
                Text(toast.message)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.id)
        }
    }
}

struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Drop to add to your library")
                    .font(Theme.display(24))
                Text("MP4 or MOV · HEVC, H.264, ProRes · AV1 on M3 and later")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 44)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                    .foregroundStyle(Theme.accent.opacity(0.8))
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
