import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

/// Downloads Wallpaper Engine items from the Steam Workshop with the person's own account.
struct SteamPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var link = ""
    @State private var guardCode = ""
    @State private var showsBrowser = false
    @State private var showsSteamCMD = false

    var body: some View {
        let steam = model.steam
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            header
            account(steam)

            if steam.isSignedIn, !steam.isQRSignIn {
                downloadSection
            }

            if let prompt = steam.prompt { promptView(prompt) }

            if !steam.downloads.isEmpty { downloadsList(steam) }

            Spacer(minLength: 0)
        }
        .padding(Theme.Space.xl)
        .frame(width: 540, height: 560)
        .background(Theme.Surface.canvas)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onDisappear { steam.cancelQRSignIn() }
        .sheet(isPresented: $showsBrowser) {
            SteamWorkshopBrowser { id in
                model.steam.download(id)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(verbatim: "STEAM WORKSHOP")
                    .font(Theme.TypeScale.eyebrow)
                    .tracking(1.8)
                    .foregroundStyle(Theme.accent)
                Text("Download to Lumen")
                    .font(Theme.display(22))
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Download by Link or ID")
                .font(Theme.TypeScale.cardTitle)
            HStack(spacing: Theme.Space.xs) {
                TextField("Workshop link or item ID", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(startDownload)
                Button("Download", action: startDownload)
                    .buttonStyle(.glassProminent)
                    .disabled(SteamWorkshop.itemID(from: link) == nil)
            }
            Button {
                showsBrowser = true
            } label: {
                Label("Browse the Steam Workshop…", systemImage: "safari")
            }
            .buttonStyle(.glass)
        }
        .padding(Theme.Space.md)
        .lumenSurface(radius: Theme.Radius.lg)
    }

    @ViewBuilder
    private func account(_ steam: SteamWorkshop) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let account = steam.account, !steam.isQRSignIn {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.playing)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.playing.opacity(0.15)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in as \(account)")
                            .font(Theme.TypeScale.cardTitle)
                        Text(steam.usesSteamCMD ? "Connected via SteamCMD" : "Connected to Steam")
                            .font(Theme.TypeScale.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out") { steam.signOut() }
                        .buttonStyle(.glass)
                        .disabled(steam.isBusy)
                }
                if steam.usesSteamCMD { qrSignInButton(steam) }
            } else {
                Text("Workshop downloads need a Steam account that owns Wallpaper Engine.")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                if let challenge = steam.qrChallenge {
                    HStack(alignment: .center, spacing: Theme.Space.md) {
                        SteamSignInCode(url: challenge)
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            Text("Scan with Steam Guard in the Steam Mobile app, then approve the sign-in.")
                                .font(Theme.TypeScale.bodyMedium)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Cancel") { steam.cancelQRSignIn() }
                                .buttonStyle(.glass)
                        }
                    }
                } else if steam.isQRSignIn {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().controlSize(.small)
                        Text("Requesting a Steam QR code…")
                            .font(Theme.TypeScale.bodyMedium)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { steam.cancelQRSignIn() }
                            .buttonStyle(.glass)
                    }
                } else {
                    qrSignInButton(steam)
                    DisclosureGroup("Advanced: Sign In with SteamCMD", isExpanded: $showsSteamCMD) {
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            TextField("Steam account name", text: $username)
                                .textFieldStyle(.roundedBorder)
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                if steam.isSigningIn {
                                    ProgressView().controlSize(.small)
                                    Text(steam.isInstalling ? "Installing SteamCMD…" : "Signing in…")
                                        .font(Theme.TypeScale.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Sign In") {
                                    steam.signIn(username: username, password: password)
                                    password = ""
                                }
                                .buttonStyle(.glassProminent)
                                .disabled(username.isEmpty || password.isEmpty || steam.isBusy)
                            }
                            .padding(.top, Theme.Space.xxs)
                        }
                        .padding(.top, Theme.Space.xs)
                    }
                    .font(Theme.TypeScale.bodyMedium)
                }
            }
            if let error = steam.signInError {
                Text(error)
                    .foregroundStyle(Theme.danger)
                    .font(Theme.TypeScale.caption)
            }
        }
        .padding(Theme.Space.md)
        .lumenSurface(radius: Theme.Radius.lg)
    }

    private func qrSignInButton(_ steam: SteamWorkshop) -> some View {
        Button {
            steam.beginQRSignIn()
        } label: {
            Label("Sign In with Steam QR Code", systemImage: "qrcode")
        }
        .buttonStyle(.glassProminent)
        .disabled(steam.isBusy)
    }

    @ViewBuilder
    private func promptView(_ prompt: SteamWorkshop.Prompt) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            switch prompt {
            case .guardCode(let email):
                Text(email ? "Enter the Steam Guard code Steam emailed you." : "Enter the code from the Steam Mobile app.")
                    .font(Theme.TypeScale.bodyMedium.weight(.semibold))
                HStack(spacing: Theme.Space.xs) {
                    TextField("Code", text: $guardCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendGuardCode)
                    Button("Continue", action: sendGuardCode)
                        .buttonStyle(.glassProminent)
                        .disabled(guardCode.isEmpty)
                    Button("Cancel") { model.steam.cancelPrompt() }
                        .buttonStyle(.glass)
                }
            case .mobileConfirmation:
                HStack(spacing: Theme.Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Open Steam Guard in the Steam Mobile app, choose Steam Client, and approve the sign-in.")
                        .font(Theme.TypeScale.bodyMedium)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.xs)
                    Button("Cancel") { model.steam.cancelPrompt() }
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(Theme.Space.md)
        .lumenSurface(radius: Theme.Radius.lg, stroke: Theme.accent.opacity(0.6))
    }

    private func downloadsList(_ steam: SteamWorkshop) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text("Downloads")
                    .font(Theme.TypeScale.cardTitle)
                Spacer()
                Button("Clear Finished") { steam.clearFinished() }
                    .buttonStyle(.link)
                    .font(Theme.TypeScale.caption)
            }
            ScrollView {
                VStack(spacing: Theme.Space.xs) {
                    ForEach(steam.downloads) { download in
                        DownloadRow(download: download) { id in
                            dismiss()
                            model.router.open(.wallpaper(id))
                        }
                    }
                }
            }
            .frame(maxHeight: 210)
        }
    }

    private func startDownload() {
        guard let id = SteamWorkshop.itemID(from: link) else { return }
        model.steam.download(id)
        link = ""
    }

    private func sendGuardCode() {
        model.steam.answer(guardCode.trimmingCharacters(in: .whitespaces))
        guardCode = ""
    }
}

private struct SteamSignInCode: View {
    let url: URL
    private static let context = CIContext()

    private var image: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 5, y: 5)) else { return nil }
        return Self.context.createCGImage(output, from: output.extent)
    }

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 124, height: 124)
                .padding(Theme.Space.sm - 2)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .accessibilityLabel(Text("Steam sign-in QR code"))
        }
    }
}

private struct DownloadRow: View {
    let download: SteamWorkshop.Download
    let open: (UUID) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm - 2) {
            AsyncImage(url: download.previewURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Theme.Surface.mediaFill
            }
            .frame(width: 56, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .strokeBorder(Theme.Surface.stroke, lineWidth: 0.75)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: download.title)
                    .font(Theme.TypeScale.bodyMedium)
                    .lineLimit(1)
                status
            }
            Spacer()
            if case .done(let id?) = download.state {
                Button("Show") { open(id) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(Theme.Space.xs + 2)
        .lumenSurface(radius: Theme.Radius.sm)
    }

    @ViewBuilder
    private var status: some View {
        switch download.state {
        case .queued:
            Text("Waiting").font(Theme.TypeScale.caption).foregroundStyle(.secondary)
        case .preparing:
            Text("Preparing download…").font(Theme.TypeScale.caption).foregroundStyle(.secondary)
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress).frame(width: 140)
            } else {
                Text("Downloading…").font(Theme.TypeScale.caption).foregroundStyle(.secondary)
            }
        case .importing:
            Text("Adding to library…").font(Theme.TypeScale.caption).foregroundStyle(.secondary)
        case .done:
            Label("In your library", systemImage: "checkmark.circle.fill")
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.playing)
        case .failed(let message):
            Text(message)
                .font(Theme.TypeScale.caption)
                .foregroundStyle(Theme.danger)
                .lineLimit(2)
        }
    }
}

/// The Steam Workshop website for Wallpaper Engine, with a Download button on item pages.
struct SteamWorkshopBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let onDownload: (String) -> Void
    @State private var currentURL: URL?
    @State private var navigator = BrowserNavigator()
    @State private var requested: Set<String> = []

    private var itemID: String? { currentURL.flatMap { SteamWorkshop.itemID(from: $0.absoluteString) }.flatMap { currentURL?.path.contains("filedetails") == true ? $0 : nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                GlassEffectContainer(spacing: Theme.Space.xxs) {
                    HStack(spacing: Theme.Space.xxs) {
                        Button { navigator.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                        Button { navigator.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                        Button { navigator.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                    }
                    .buttonStyle(.glass)
                }
                Text(verbatim: currentURL?.host() ?? "steamcommunity.com")
                    .font(Theme.TypeScale.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, Theme.Space.xxs)
                Spacer()
                if let itemID {
                    Button {
                        onDownload(itemID)
                        requested.insert(itemID)
                    } label: {
                        Label(requested.contains(itemID) ? "Added to Downloads" : "Download to Lumen", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(requested.contains(itemID))
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.vertical, Theme.Space.sm - 2)
            .background(Theme.Surface.canvas)
            SteamWebView(url: URL(string: "https://steamcommunity.com/app/431960/workshop/")!, navigator: navigator) { url in
                currentURL = url
            }
        }
        .frame(width: 1100, height: 760)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}

@MainActor
final class BrowserNavigator {
    weak var webView: WKWebView?
}

private struct SteamWebView: NSViewRepresentable {
    let url: URL
    let navigator: BrowserNavigator
    let onNavigate: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNavigate: onNavigate) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.observation = webView.observe(\.url, options: [.new]) { view, _ in
            MainActor.assumeIsolated { context.coordinator.onNavigate(view.url) }
        }
        navigator.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let onNavigate: (URL?) -> Void
        var observation: NSKeyValueObservation?

        init(onNavigate: @escaping (URL?) -> Void) {
            self.onNavigate = onNavigate
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigate(webView.url)
        }
    }
}
