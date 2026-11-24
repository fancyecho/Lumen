import SwiftUI

/// Live shader editor: palette, motion and (optionally) the Metal source itself.
struct StudioEditorView: View {
    @Environment(AppModel.self) private var model
    let wallpaperID: UUID

    @State private var config: ShaderConfig?
    @State private var title = ""
    @State private var source = ""
    @State private var compileError: String?
    @State private var showsCode = false

    var body: some View {
        Group {
            if let base = model.library.wallpaper(id: wallpaperID), let config {
                ScrollView {
                    HStack(alignment: .top, spacing: Theme.Space.xl) {
                        VStack(alignment: .leading, spacing: Theme.Space.md) {
                            preview(config: config, framing: base.resolvedFraming)
                            if showsCode {
                                codeEditor
                            } else {
                                presetStrip(current: base)
                                    .padding(.top, Theme.Space.md)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        controls(base: base, config: config)
                            .frame(width: Theme.Layout.inspectorWidth)
                    }
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, Theme.Space.lg)
                    .padding(.bottom, Theme.Space.xxl + Theme.Space.xs)
                    .frame(maxWidth: Theme.Layout.galleryMaxWidth)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("Shader not found", systemImage: "questionmark.square.dashed")
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Preview

    private func preview(config: ShaderConfig, framing: WallpaperFraming) -> some View {
        ShaderPreview(config: config, settings: ShaderRenderSettings(frameRate: 60, pixelBudget: 1_600_000), framing: framing)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xxl, style: .continuous).strokeBorder(Theme.Surface.scrimStroke))
            .overlay(alignment: .topLeading) {
                ArtBadge(text: "Live", symbol: "sparkles").padding(Theme.Space.md)
            }
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
    }

    private var codeEditor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
            HStack(spacing: Theme.Space.xs) {
                Text("Fragment shader")
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
                Text(verbatim: "Metal Shading Language")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.Ink.tertiary)
                Spacer()
                Button("Reset") { source = self.config?.resolvedSource ?? "" }
                    .buttonStyle(.lumenSecondary)
                Button(action: runCode) {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.lumenPrimary)
                .keyboardShortcut(.return, modifiers: .command)
            }
            TextEditor(text: $source)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(Theme.Space.sm)
                .frame(minHeight: 320)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).fill(Color.black.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.Surface.stroke))
            if let compileError {
                Label {
                    Text(compileError)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(Theme.danger)
                .padding(Theme.Space.sm)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).fill(Theme.danger.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.danger.opacity(0.3)))
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// The other shaders, one click away, so trying presets doesn't mean bouncing back to the grid.
    private func presetStrip(current: Wallpaper) -> some View {
        let others = (model.library.builtins + model.library.customShaders).filter { $0.id != current.id }
        return VStack(alignment: .leading, spacing: Theme.Space.md) {
            SectionTitle("More to try")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: Theme.Space.sm)], alignment: .leading, spacing: Theme.Space.md) {
                ForEach(others) { shader in
                    PresetThumbnail(wallpaper: shader) {
                        model.router.back()
                        model.router.open(.studio(shader.id))
                    }
                }
            }
        }
    }

    // MARK: Controls

    private func controls(base: Wallpaper, config: ShaderConfig) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Eyebrow(text: base.isBuiltin ? "Preset" : "Your shader")
                TextField("Name", text: $title)
                    .textFieldStyle(.plain)
                    .font(Theme.TypeScale.artworkTitle)
                    .foregroundStyle(Theme.Ink.primary)
                if let preset = BuiltinShaders.preset(id: base.id) {
                    Text(preset.tagline)
                        .font(Theme.TypeScale.body)
                        .foregroundStyle(Theme.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            panel("Palette", symbol: "paintpalette") {
                HStack(spacing: Theme.Space.sm - 2) {
                    ForEach(0..<4, id: \.self) { index in
                        ColorPicker("Colour \(index + 1)", selection: colorBinding(index), supportsOpacity: false)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: Theme.Space.xs) {
                    Button { randomizePalette() } label: { Label("Shuffle", systemImage: "shuffle") }
                    Button { resetParams(base: base) } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                }
                .buttonStyle(.lumenSecondary)
                .controlSize(.small)
            }

            panel("Motion", symbol: "waveform.path") {
                slider("Speed", value: paramBinding(\.speed), range: 0.1...3, format: { Theme.rateLabel(($0 * 20).rounded() / 20) })
                slider("Scale", value: paramBinding(\.scale), range: 0.4...2.5, format: { String(format: "%.2f", $0) })
                slider("Intensity", value: paramBinding(\.intensity), range: 0...2, format: { String(format: "%.0f%%", $0 * 100) })
            }

            panel("Position", symbol: "crop") {
                FramingSliders(wallpaper: base)
                HStack {
                    Spacer()
                    FramingResetButton(wallpaper: base)
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.sm - 2) {
                SetWallpaperButton { target in apply(base: base, target: target) }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: Theme.Space.xs) {
                    Button { save(base: base) } label: {
                        if base.isBuiltin {
                            Label("Save Copy", systemImage: "square.and.arrow.down")
                        } else {
                            Label("Save", systemImage: "square.and.arrow.down")
                        }
                    }
                    Button {
                        withAnimation(.smooth) { showsCode.toggle() }
                    } label: {
                        if showsCode {
                            Label("Hide Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        } else {
                            Label("Edit Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                    if !base.isBuiltin {
                        Button(role: .destructive) { model.pendingDeletion = base } label: {
                            Image(systemName: "trash")
                        }
                        .help("Delete shader")
                        .accessibilityLabel(Text("Delete shader"))
                    }
                }
                .buttonStyle(.lumenSecondary)
            }

            Text("Runs at \(model.settings.shaderFrameRate) fps on the desktop, rendered at \(model.settings.shaderQuality.title.lowercased()) quality. Change this in Settings → Performance.")
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func panel<Content: View>(_ title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm - 2) {
                IconWell(symbol: symbol, size: 28)
                Text(title)
                    .font(Theme.TypeScale.cardTitle)
                    .foregroundStyle(Theme.Ink.primary)
            }
            content()
        }
        .padding(Theme.Space.md)
        .lumenSurface(radius: Theme.Radius.xl)
    }

    private func slider(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack {
                Text(label)
                    .font(Theme.TypeScale.body)
                    .foregroundStyle(Theme.Ink.primary)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(Theme.TypeScale.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    // MARK: Bindings

    private func paramBinding(_ keyPath: WritableKeyPath<ShaderParams, Double>) -> Binding<Double> {
        Binding(
            get: { config?.params[keyPath: keyPath] ?? 1 },
            set: { config?.params[keyPath: keyPath] = $0 }
        )
    }

    private func colorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                guard let colors = config?.params.colors, colors.indices.contains(index) else { return .black }
                return colors[index].color
            },
            set: { newValue in
                guard config?.params.colors.indices.contains(index) == true else { return }
                config?.params.colors[index] = RGBAColor(newValue)
            }
        )
    }

    // MARK: Actions

    private func load() {
        guard config == nil, let base = model.library.wallpaper(id: wallpaperID), let shader = base.shader else { return }
        config = shader
        title = base.title
        source = shader.resolvedSource ?? ""
        showsCode = !base.isBuiltin && shader.presetKey == nil
    }

    private func runCode() {
        compileError = MetalContext.shared.compileError(for: source)
        if compileError == nil {
            config?.customSource = source
        }
    }

    private func randomizePalette() {
        let hue = Double.random(in: 0...1)
        func color(_ offset: Double, _ saturation: Double, _ brightness: Double) -> RGBAColor {
            RGBAColor(Color(hue: (hue + offset).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness))
        }
        withAnimation(.smooth) {
            config?.params.colors = [
                color(0, 0.7, 0.12),
                color(0.06, 0.72, 0.78),
                color(0.22, 0.55, 0.92),
                color(0.12, 0.22, 1.0),
            ]
        }
    }

    private func resetParams(base: Wallpaper) {
        if let preset = BuiltinShaders.preset(id: base.id) {
            config?.params = preset.params
        } else if let preset = config?.presetKey.flatMap(BuiltinShaders.preset(key:)) {
            config?.params = preset.params
        } else if let stored = base.shader {
            config?.params = stored.params
        }
    }

    /// Builtins are immutable: edits become a new library item. Own shaders update in place.
    @discardableResult
    private func save(base: Wallpaper) -> Wallpaper? {
        guard let config else { return nil }
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? base.title : title
        if base.isBuiltin {
            let copy = model.library.saveShader(
                title: name == base.title ? "\(base.title) Remix" : name,
                config: config, category: base.category
            )
            model.showToast(String(localized: "Saved “\(copy.title)” to your library"), symbol: "square.and.arrow.down.fill")
            return copy
        }
        var updated = base
        updated.title = name
        updated.shader = config
        model.library.update(updated)
        model.engine.reload(wallpaperID: updated.id)
        model.showToast(String(localized: "Saved “\(updated.title)”"), symbol: "checkmark.circle.fill")
        return updated
    }

    private func apply(base: Wallpaper, target: DisplayTarget) {
        guard let config else { return }
        if base.isBuiltin, config == base.shader {
            model.setWallpaper(base, on: target)
        } else if let saved = save(base: base) {
            model.setWallpaper(saved, on: target)
            if base.isBuiltin { model.router.back() ; model.router.open(.studio(saved.id)) }
        }
    }
}

/// Small, captioned shader thumbnail for the editor's "More to try" strip.
private struct PresetThumbnail: View {
    let wallpaper: Wallpaper
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.xs - 2) {
                ThumbnailView(wallpaper: wallpaper)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .artworkFrame(radius: Theme.Radius.sm, isHovering: hovering)
                Text(wallpaper.title)
                    .font(Theme.TypeScale.label)
                    .foregroundStyle(hovering ? Theme.Ink.primary : Theme.Ink.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.quick, value: hovering)
    }
}
