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
    }
}

enum SceneID {
    static let main = "main"
}

struct LumenCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Wallpapers…") { model.isImporterPresented = true }
                .keyboardShortcut("o")
        }
        CommandMenu("Playback") {
            Button(model.engine.userPaused ? "Resume All" : "Pause All") {
                model.engine.toggleUserPause()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Next in Playlist") { model.playlists.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model.playlists.active == nil)
        }
    }
}
