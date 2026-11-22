import SwiftUI

struct StudioView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 440), spacing: 24, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                PageHeader(
                    eyebrow: "Studio",
                    title: "Generative wallpapers",
                    subtitle: String(localized: "Rendered live on the GPU within a fixed pixel budget. Tune colours and motion, or write your own Metal shader.")
                ) {
                    Button(action: createShader) {
                        Label("New Shader", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 16) {
                    SectionTitle("Presets")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                        ForEach(model.library.builtins) { WallpaperCard(wallpaper: $0) }
                    }
                }

                if !model.library.customShaders.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle("Your creations")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
                            ForEach(model.library.customShaders) { WallpaperCard(wallpaper: $0) }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: 1480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func createShader() {
        let base = BuiltinShaders.all[0].params
        let wallpaper = model.library.saveShader(
            title: String(localized: "Untitled Shader"),
            config: ShaderConfig(presetKey: nil, customSource: ShaderSources.customTemplate, params: base),
            category: "Abstract"
        )
        model.router.open(.studio(wallpaper.id))
    }
}
