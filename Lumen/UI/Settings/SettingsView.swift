import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Playback", systemImage: "play.rectangle") { PlaybackSettings() }
            Tab("Lock Screen", systemImage: "lock.fill") { LockScreenSettings() }
            Tab("Performance", systemImage: "gauge.with.dots.needle.50percent") { PerformanceSettings() }
            Tab("Wallpaper Engine", systemImage: "square.3.layers.3d") { WallpaperEngineSettings() }
        }
        .frame(width: 580)
        .frame(minHeight: 580)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            ApplicationSection()

            Section {
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

private struct ApplicationSection: View {
    @Environment(\.openURL) private var openURL
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginRequiresApproval = LoginItem.requiresApproval
    @State private var loginError: String?
    @State private var checking = false
    @State private var update: ReleaseUpdate?
    @State private var showsUpdate = false
    @State private var updateStatus: String?

    var body: some View {
        Section("Application") {
            Toggle("Open Lumen when you log in", isOn: Binding(
                get: { launchAtLogin },
                set: { enabled in
                    do {
                        try LoginItem.setEnabled(enabled)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    refreshLoginItem()
                }
            ))
            if loginRequiresApproval {
                Button("Approve in Login Items Settings") { LoginItem.openSettings() }
            }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
            if let feed = ReleaseUpdate.feedURL {
                Button(checking ? "Checking for Updates…" : "Check for Updates") {
                    Task { await check(feed) }
                }
                .disabled(checking)
                if let updateStatus {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: refreshLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
        .alert("Lumen Update Available", isPresented: $showsUpdate, presenting: update) { release in
            Button("Download") { openURL(release.downloadURL) }
            Button("Later", role: .cancel) {}
        } message: { release in
            Text("Lumen \(release.version) is available.\n\n\(release.notes)")
        }
    }

    private func refreshLoginItem() {
        launchAtLogin = LoginItem.isEnabled
        loginRequiresApproval = LoginItem.requiresApproval
    }

    private func check(_ feed: URL) async {
        checking = true
        updateStatus = nil
        defer { checking = false }
        do {
            update = try await ReleaseUpdate.check(feed)
            showsUpdate = update != nil
            if update == nil { updateStatus = String(localized: "Lumen is up to date.") }
        } catch {
            updateStatus = error.localizedDescription
        }
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
