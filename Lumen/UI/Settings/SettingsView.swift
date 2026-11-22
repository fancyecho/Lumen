import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Playback", systemImage: "play.rectangle") { PlaybackSettings() }
            Tab("Lock Screen", systemImage: "lock.fill") { LockScreenSettings() }
            Tab("Performance", systemImage: "gauge.with.dots.needle.50percent") { PerformanceSettings() }
        }
        .frame(width: 540)
        .frame(minHeight: 580)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Open Lumen when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Picker("Show Dock icon", selection: $settings.dockIconMode) {
                    ForEach(DockIconMode.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Wallpapers keep playing after you close the window. Lumen stays in the menu bar.")
            }

            Section {
                Toggle("Match the system wallpaper", isOn: $settings.syncStillFrame)
            } footer: {
                Text("macOS shows the system wallpaper during Mission Control, Space switches and on the lock screen. Lumen sets it to a frame of your live wallpaper so those moments match, and restores your original picture when you stop using a wallpaper.")
            }

            LanguageSection()

            Section("Storage") {
                LabeledContent("Library") {
                    Text(Format.bytes(model.library.totalDiskUsage)).monospacedDigit()
                }
                Button("Show Library Folder in Finder") {
                    NSWorkspace.shared.open(AppPaths.root)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LanguageSection: View {
    @State private var selection = AppLanguage.current

    var body: some View {
        Section {
            Picker("Language", selection: $selection) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.label).tag(language)
                }
            }
            .onChange(of: selection) { _, language in language.save() }
            if selection != AppLanguage.atLaunch {
                HStack {
                    Text("Restart Lumen to use the new language.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Now") { AppLanguage.relaunch() }
                }
            }
        } footer: {
            Text("Wallpapers resume automatically after the restart.")
        }
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Video") {
                Picker("Scaling", selection: $settings.videoScaling) {
                    ForEach(VideoScaling.allCases) { Text($0.title).tag($0) }
                }
                Picker("Speed", selection: $settings.playbackRate) {
                    ForEach(Theme.playbackRates, id: \.self) { Text(Theme.rateLabel($0)).tag($0) }
                }
                Toggle("Cross-fade between wallpapers", isOn: $settings.crossfade)
            }
            Section("Audio") {
                Toggle("Play wallpaper audio", isOn: $settings.audioEnabled)
                Slider(value: $settings.volume, in: 0...1) {
                    Text("Volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                }
                .disabled(!settings.audioEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PerformanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let system = model.system
        Form {
            Section {
                Toggle("When the desktop is covered by windows", isOn: $settings.pauseWhenCovered)
                if settings.pauseWhenCovered {
                    CoverageThresholdRow(threshold: $settings.coverageThreshold)
                }
                Toggle("When running on battery", isOn: $settings.pauseOnBattery)
                Toggle("In Low Power Mode", isOn: $settings.pauseOnLowPower)
                Toggle("When the Mac is under thermal pressure", isOn: $settings.pauseOnThermalPressure)
            } header: {
                Text("Pause automatically")
            } footer: {
                Text("Wallpapers always pause while the display sleeps, the screen is locked, the screen saver runs or another user is active.")
            }

            Section {
                Picker("Frame rate", selection: $settings.shaderFrameRate) {
                    ForEach([15, 24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Render quality", selection: $settings.shaderQuality) {
                    ForEach(ShaderQuality.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Generative wallpapers")
            } footer: {
                Text(settings.shaderQuality.detail + " " + String(localized: "Video wallpapers decode on the media engine and aren't affected."))
            }

            Section("Right now") {
                LabeledContent("Power source", value: system.onBattery ? String(localized: "Battery") : String(localized: "Power adapter"))
                LabeledContent("Low Power Mode", value: system.lowPowerMode ? String(localized: "On") : String(localized: "Off"))
                LabeledContent("Thermal state", value: system.thermalDescription)
            }
        }
        .formStyle(.grouped)
    }
}
