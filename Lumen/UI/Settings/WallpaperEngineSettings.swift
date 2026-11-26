import SwiftUI

/// Settings for web and scene wallpapers: Wallpaper Engine's assets, interaction, and the
/// folders the Workshop page reads.
struct WallpaperEngineSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let assets = settings.sceneAssets
        Form {
            Section {
                let own = SceneAssetsLocator.ownFolder
                let ready = assets != nil
                LabeledContent("Assets folder") {
                    HStack(spacing: Theme.Space.xs) {
                        Text(verbatim: abbreviated(own))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        if ready {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.playing)
                                .accessibilityLabel(Text("Ready"))
                        } else {
                            Label("Not downloaded", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.paused)
                        }
                    }
                }
                if !ready || model.steam.assetsDownload != .idle {
                    SceneAssetsDownloadControl(inForm: true)
                }
                HStack {
                    Button("Import from Folder…") { importAssets() }
                        .disabled(model.steam.assetsDownload != .idle)
                    Spacer()
                    if ready {
                        Button("Download Again") { model.downloadSceneAssets() }
                            .disabled(!model.steam.canDownloadSceneAssets || model.steam.assetsDownload != .idle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([own]) }
                    }
                }
            } header: {
                Text("Scene assets")
            } footer: {
                Text("Scenes use shaders, materials and effects that ship with Wallpaper Engine itself. Lumen downloads them from Steam with the account you signed in with and keeps them in its own folder, so they don't depend on any other app.")
            }

            Section {
                Toggle("Web and scene wallpapers follow the pointer", isOn: $settings.interactiveWallpapers)
            } footer: {
                Text("When the pointer rests on the desktop, web wallpapers receive mouse moves and clicks and scenes can react with parallax and ripples. Nothing is sent while you work in other windows.")
            }

            Section {
                Toggle("Audio-reactive wallpapers follow the music", isOn: $settings.audioReactiveWallpapers)
            } footer: {
                Text("Spectrum bars, pulsing effects and beat-driven particles listen to what your Mac is playing. macOS asks once for permission to record system audio. Lumen only measures loudness per frequency, in memory, and listens only while such a wallpaper is on screen.")
            }

            Section {
                let workshop = model.workshop
                ForEach(WorkshopLibrary.defaultSources(custom: workshop.customFolders)) { source in
                    HStack {
                        Image(systemName: source.kind == .folder ? "folder" : "shippingbox")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: source.title)
                            Text(verbatim: abbreviated(source.url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if source.kind == .folder {
                            Button("Remove") { workshop.removeFolder(source.url) }
                        }
                    }
                }
                Button("Add Folder…") { chooseWorkshopFolder() }
            } header: {
                Text("Workshop folders")
            } footer: {
                Text("Lumen finds Steam's Wallpaper Engine downloads and other apps' libraries automatically. Adding a wallpaper copies it into Lumen's library; on the same disk the copy takes no extra space.")
            }
        }
        .formStyle(.grouped)
    }

    private func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// Copies an assets folder (for example from a Windows PC) into Lumen's own folder.
    private func importAssets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose Wallpaper Engine's “assets” folder.")
        panel.prompt = String(localized: "Use Folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SceneAssetsLocator.isAssetsFolder(url) || SceneAssetsLocator.isAssetsFolder(url.appending(path: "assets")) else {
            model.showToast(String(localized: "That folder doesn't look like Wallpaper Engine's assets."), symbol: "exclamationmark.triangle.fill")
            return
        }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try SceneAssetsLocator.importCopy(from: url) }.value
                model.settings.sceneAssetsDidChange()
                model.showToast(String(localized: "Scene assets copied into Lumen."), symbol: "checkmark.circle.fill")
            } catch {
                model.showToast(String(localized: "Couldn't copy the assets folder."), symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func chooseWorkshopFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder of Wallpaper Engine projects.")
        panel.prompt = String(localized: "Add Folder")
        if panel.runModal() == .OK, let url = panel.url { model.workshop.addFolder(url) }
    }
}
