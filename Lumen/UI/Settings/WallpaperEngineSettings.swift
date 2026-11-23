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
                LabeledContent("Assets folder") {
                    if let assets {
                        Text(verbatim: abbreviated(assets))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.paused)
                    }
                }
                HStack {
                    Button("Choose Folder…") { chooseAssets() }
                    if !settings.sceneAssetsPath.isEmpty {
                        Button("Find Automatically") { settings.sceneAssetsPath = "" }
                    }
                    Spacer()
                    if let assets {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([assets]) }
                    }
                }
            } header: {
                Text("Scene assets")
            } footer: {
                Text("Scenes use shaders, materials and effects that ship with Wallpaper Engine itself. Choose the “assets” folder of a Wallpaper Engine installation you own (for example copied from a Windows PC), or one another app downloaded. Lumen only reads it.")
            }

            Section {
                Toggle("Web and scene wallpapers follow the pointer", isOn: $settings.interactiveWallpapers)
            } footer: {
                Text("When the pointer rests on the desktop, web wallpapers receive mouse moves and clicks and scenes can react with parallax and ripples. Nothing is sent while you work in other windows.")
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

    private func chooseAssets() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose Wallpaper Engine's “assets” folder.")
        panel.prompt = String(localized: "Use Folder")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if SceneAssetsLocator.isAssetsFolder(url) || SceneAssetsLocator.isAssetsFolder(url.appending(path: "assets")) {
            model.settings.sceneAssetsPath = url.path
        } else {
            model.showToast(String(localized: "That folder doesn't look like Wallpaper Engine's assets."), symbol: "exclamationmark.triangle.fill")
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
