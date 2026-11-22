import SwiftUI

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("Lumen", id: SceneID.main) {
            RootView()
                .environment(model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 840)
        .windowResizability(.contentMinSize)
        .commands { LumenCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            Image(systemName: model.engine.isAnyPlaying ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
        }
        .menuBarExtraStyle(.window)

        #if DEBUG
        // `-LumenDebugMenuPreview YES` shows the menu bar panel in a normal window for UI checks.
        Window("Menu Bar Preview", id: SceneID.menuPreview) {
            MenuBarPanel()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        #endif
    }
}

enum SceneID {
    static let main = "main"
    static let menuPreview = "menu-preview"
}

struct LumenCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Wallpapers…") { model.isImporterPresented = true }
                .keyboardShortcut("o")
        }
        CommandMenu("Playback") {
            Button {
                model.engine.toggleUserPause()
            } label: {
                if model.engine.userPaused { Text("Resume All") } else { Text("Pause All") }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Next in Playlist") { model.playlists.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model.playlists.active == nil)
        }
    }
}
