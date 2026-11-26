import SwiftUI

/// Downloads Wallpaper Engine's shared scene assets from Steam, or says how to make that possible.
/// `inForm` uses plain system controls for the Settings window.
struct SceneAssetsDownloadControl: View {
    @Environment(AppModel.self) private var model
    var inForm = false
    /// Set when the person signs in from here, so the download starts as soon as Steam approves.
    @State private var downloadAfterSignIn = false

    var body: some View {
        let steam = model.steam
        switch steam.assetsDownload {
        case .downloading(let progress):
            HStack(spacing: Theme.Space.sm) {
                if let progress {
                    ProgressView(value: progress).frame(width: 120)
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparing download…").foregroundStyle(.secondary)
                }
            }
            .font(Theme.TypeScale.caption)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(message)
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                downloadButton(title: "Try Again")
            }
        case .idle:
            if steam.canDownloadSceneAssets {
                downloadButton(title: "Download from Steam")
            } else {
                signIn(steam)
                    .onChange(of: steam.canDownloadSceneAssets) { _, canDownload in
                        guard canDownload, downloadAfterSignIn else { return }
                        downloadAfterSignIn = false
                        model.downloadSceneAssets()
                    }
            }
        }
    }

    /// Wallpaper Engine's app depot is only readable with the native QR sign-in, so offer it here.
    @ViewBuilder
    private func signIn(_ steam: SteamWorkshop) -> some View {
        if let challenge = steam.qrChallenge {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                SteamSignInCode(url: challenge)
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text("Scan with Steam Guard in the Steam Mobile app, then approve the sign-in.")
                        .font(Theme.TypeScale.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") {
                        downloadAfterSignIn = false
                        steam.cancelQRSignIn()
                    }
                }
            }
        } else if steam.isQRSignIn {
            HStack(spacing: Theme.Space.sm) {
                ProgressView().controlSize(.small)
                Text("Requesting a Steam QR code…").foregroundStyle(.secondary)
            }
            .font(Theme.TypeScale.caption)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Downloading them needs the Steam QR sign-in of an account that owns Wallpaper Engine.")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                signInButton(steam)
            }
        }
    }

    @ViewBuilder
    private func signInButton(_ steam: SteamWorkshop) -> some View {
        let button = Button {
            downloadAfterSignIn = true
            steam.beginQRSignIn()
        } label: {
            Label("Sign In with Steam QR Code", systemImage: "qrcode")
        }
        .disabled(steam.isBusy)
        if inForm {
            button
        } else {
            button.buttonStyle(.lumenPrimary)
        }
    }

    @ViewBuilder
    private func downloadButton(title: LocalizedStringKey) -> some View {
        let button = Button {
            model.downloadSceneAssets()
        } label: {
            Label(title, systemImage: "arrow.down.circle")
        }
        if inForm {
            button
        } else {
            button.buttonStyle(.lumenPrimary)
        }
    }
}
