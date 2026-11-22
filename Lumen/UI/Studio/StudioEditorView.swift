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
                    HStack(alignment: .top, spacing: 26) {
                        VStack(alignment: .leading, spacing: 18) {
                            preview(config: config)
                            if showsCode { codeEditor }
                        }
                        .frame(maxWidth: .infinity)

                        controls(base: base, config: config)
                            .frame(width: 320)
                    }
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 22)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 1480)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("Shader not found", systemImage: "questionmark.square.dashed")
            }
        }
        .onAppear(perform: load)
    }

    // MARK: Preview

    private func preview(config: ShaderConfig) -> some View {
        ShaderPreview(config: config, settings: ShaderRenderSettings(frameRate: 60, pixelBudget: 1_600_000))
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.5), radius: 26, y: 14)
    }

    private var codeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Fragment shader").font(.system(size: 13, weight: .semibold))
                Text(verbatim: "Metal Shading Language").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { source = self.config?.resolvedSource ?? "" }
                    .buttonStyle(.glass)
                Button(action: runCode) {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            TextEditor(text: $source)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .padding(12)
                .frame(minHeight: 320)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.surfaceStroke))
            if let compileError {
                Text(compileError)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(red: 1, green: 0.5, blue: 0.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.red.opacity(0.12)))
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Controls

    private func controls(base: Wallpaper, config: ShaderConfig) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: base.isBuiltin ? "PRESET" : "YOUR SHADER")
                    .font(Theme.eyebrow).tracking(1.8).foregroundStyle(Theme.accent)
                TextField("Name", text: $title)
                    .textFieldStyle(.plain)
                    .font(Theme.display(28))
                if let preset = BuiltinShaders.preset(id: base.id) {
                    Text(preset.tagline).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }

            panel("Palette") {
                HStack(spacing: 10) {
                    ForEach(0..<4, id: \.self) { index in
                        ColorPicker("Colour \(index + 1)", selection: colorBinding(index), supportsOpacity: false)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 8) {
                    Button { randomizePalette() } label: { Label("Shuffle", systemImage: "shuffle") }
                    Button { resetParams(base: base) } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            panel("Motion") {
                slider("Speed", value: paramBinding(\.speed), range: 0.1...3, format: { Theme.rateLabel(($0 * 20).rounded() / 20) })
                slider("Scale", value: paramBinding(\.scale), range: 0.4...2.5, format: { String(format: "%.2f", $0) })
                slider("Intensity", value: paramBinding(\.intensity), range: 0...2, format: { String(format: "%.0f%%", $0 * 100) })
            }

            VStack(alignment: .leading, spacing: 10) {
                SetWallpaperButton { target in apply(base: base, target: target) }
                    .controlSize(.large)
                HStack(spacing: 8) {
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
                    }
                }
                .buttonStyle(.glass)
            }

            Text("Runs at \(model.settings.shaderFrameRate) fps on the desktop, rendered at \(model.settings.shaderQuality.title.lowercased()) quality. Change this in Settings → Performance.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func panel<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.surfaceStroke))
    }

    private func slider(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 13))
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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
