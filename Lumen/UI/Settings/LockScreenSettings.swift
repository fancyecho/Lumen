import SwiftUI

/// Settings tab for playing a wallpaper on the macOS Lock Screen and screen saver.
struct LockScreenSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let lockScreen = model.lockScreen
        Form {
            Section {
                LockScreenPreview(wallpaper: previewWallpaper, isEnabled: settings.lockScreenEnabled)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            }

            Section {
                Toggle("Play on the Lock Screen", isOn: $settings.lockScreenEnabled)
                    .disabled(!lockScreen.isSupported && !settings.lockScreenEnabled)
                Picker("Wallpaper", selection: $settings.lockScreenWallpaperID) {
                    Text("Same as the desktop").tag(UUID?.none)
                    Divider()
                    ForEach(model.library.videos) { wallpaper in
                        Text(verbatim: wallpaper.title).tag(UUID?.some(wallpaper.id))
                    }
                    if !model.library.videos.isEmpty { Divider() }
                    ForEach(model.library.customShaders + model.library.builtins) { wallpaper in
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

extension LockScreenSettings {
    /// What the Lock Screen will show: the chosen wallpaper, or the main display's.
    fileprivate var previewWallpaper: Wallpaper? {
        if let id = model.settings.lockScreenWallpaperID, let chosen = model.library.wallpaper(id: id) {
            return chosen
        }
        return model.engine.primaryDisplay?.wallpaperID.flatMap { model.library.wallpaper(id: $0) }
    }
}

/// A miniature Lock Screen: the wallpaper with the clock laid over it, as macOS shows it.
private struct LockScreenPreview: View {
    let wallpaper: Wallpaper?
    let isEnabled: Bool

    var body: some View {
        ZStack {
            if let wallpaper {
                ThumbnailView(wallpaper: wallpaper)
            } else {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
            }
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 2) {
                TimelineView(.everyMinute) { context in
                    VStack(spacing: 2) {
                        Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.system(size: 12, weight: .semibold))
                        Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                            .font(.system(size: 46, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(8)
                    .background(Circle().fill(.white.opacity(0.18)))
            }
            .foregroundStyle(.white.opacity(0.92))
            .shadow(color: .black.opacity(0.35), radius: 6)
            .padding(.vertical, 16)

            if !isEnabled {
                Color.black.opacity(0.5)
                Text("Lock Screen shows the system wallpaper")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .frame(maxWidth: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: isEnabled)
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
        case .keepingPrevious(let title):
            Group {
                if let title {
                    Text("This wallpaper can't be recorded: its files or Wallpaper Engine's assets are missing. Still showing “\(title)”.")
                } else {
                    Text("This wallpaper can't be recorded: its files or Wallpaper Engine's assets are missing.")
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
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
