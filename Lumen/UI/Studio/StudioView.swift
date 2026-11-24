import SwiftUI

struct StudioView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 440), spacing: Theme.Space.xl, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section - Theme.Space.xs) {
                PageHeader(
                    eyebrow: "Studio",
                    title: "Generative wallpapers",
                    subtitle: String(localized: "Rendered live on the GPU within a fixed pixel budget. Tune colours and motion, or write your own Metal shader.")
                ) {
                    Button(action: createShader) {
                        Label("New Shader", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .buttonStyle(.lumenPrimary)
                    .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    SectionTitle("Presets", subtitle: String(localized: "Tuned shaders that cost a fraction of a video. Open one to change colours and motion."))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xxl) {
                        ForEach(model.library.builtins) { WallpaperCard(wallpaper: $0) }
                    }
                }

                if !model.library.customShaders.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        SectionTitle("Your creations")
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xxl) {
                            ForEach(model.library.customShaders) { WallpaperCard(wallpaper: $0) }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, Theme.Space.lg)
            .padding(.bottom, Theme.Space.xxl + Theme.Space.xs)
            .frame(maxWidth: Theme.Layout.galleryMaxWidth, alignment: .leading)
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
