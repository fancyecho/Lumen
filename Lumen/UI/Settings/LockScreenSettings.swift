import SwiftUI

/// Settings tab for playing a wallpaper on the macOS Lock Screen and screen saver.
struct LockScreenSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let lockScreen = model.lockScreen
        Form {
            Section {
                Toggle("Play on the Lock Screen", isOn: $settings.lockScreenEnabled)
                    .disabled(!lockScreen.isSupported && !settings.lockScreenEnabled)
                Picker("Wallpaper", selection: $settings.lockScreenWallpaperID) {
                    Text("Same as the desktop").tag(UUID?.none)
                    Divider()
                    ForEach(model.library.all) { wallpaper in
                        Text(verbatim: wallpaper.title).tag(UUID?.some(wallpaper.id))
                    }
                }
                .disabled(!settings.lockScreenEnabled)
                LabeledContent("Status") {
                    LockScreenStatusLabel(status: lockScreen.status)
                }
                if settings.lockScreenEnabled {
                    Button("Rebuild Lock Screen Video") { lockScreen.rebuild() }
                }
            } footer: {
                Text("Lumen adds the wallpaper to macOS's Aerial collection, under “Lumen”, and selects it for the Lock Screen and screen saver. It keeps playing even when Lumen isn't running. Turning this off restores your previous choice.")
            }

            Section("Good to know") {
                Label("Lock your Mac with ⌃⌘Q, or start the screen saver, to see it.", systemImage: "lock")
                Label("Short loops are repeated to an hour without taking more disk space. Non-HEVC videos and repositioned wallpapers are converted once.", systemImage: "film.stack")
                Label("Other wallpaper apps that manage the Lock Screen may replace Lumen's choice while they're running.", systemImage: "exclamationmark.triangle")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct LockScreenStatusLabel: View {
    let status: LockScreenStatus

    var body: some View {
        switch status {
        case .off:
            Text("Off").foregroundStyle(.secondary)
        case .waitingForWallpaper:
            Text("Set a desktop wallpaper first").foregroundStyle(.secondary)
        case .preparing(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 90)
                Text("Preparing \(Int(progress * 100))%").monospacedDigit()
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing…")
            }
        case .active(let title):
            HStack(spacing: 6) {
                StatusDot(color: Theme.playing)
                Text("Showing “\(title)”")
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Pause when covered" threshold, with the live coverage of each display.
struct CoverageThresholdRow: View {
    @Environment(AppModel.self) private var model
    @Binding var threshold: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pause when at least")
                Spacer()
                Text("\(Int((threshold * 100).rounded()))% covered")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $threshold, in: 0.5...1, step: 0.05) {
                Text("Coverage threshold")
            } minimumValueLabel: {
                Text("50%").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("100%").font(.caption).foregroundStyle(.secondary)
            }
            .labelsHidden()
            let measured = model.engine.displays.compactMap { display in
                display.coverage.map { (display.name, $0) }
            }
            if !measured.isEmpty {
                Text(measured.map { "\($0.0): \(Int(($0.1 * 100).rounded()))%" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
