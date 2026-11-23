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

    var body: some View {
        let steam = model.steam
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Steam Workshop", systemImage: "arrow.down.circle")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            account(steam)

            if steam.isSignedIn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Download").font(.system(size: 13, weight: .semibold))
                    HStack {
                        TextField("Workshop link or item ID", text: $link)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(startDownload)
                        Button("Download", action: startDownload)
                            .disabled(SteamWorkshop.itemID(from: link) == nil)
                    }
                    Button {
                        showsBrowser = true
                    } label: {
                        Label("Browse the Steam Workshop…", systemImage: "safari")
                    }
                    .buttonStyle(.glass)
                }
            }

            if let prompt = steam.prompt { promptView(prompt) }

            if !steam.downloads.isEmpty { downloadsList(steam) }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 520, height: 560)
        .sheet(isPresented: $showsBrowser) {
            SteamWorkshopBrowser { id in
                model.steam.download(id)
            }
        }
    }

    @ViewBuilder
    private func account(_ steam: SteamWorkshop) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let account = steam.account {
                HStack {
                    Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Theme.playing)
                    Text("Signed in as \(account)")
                    Spacer()
                    Button("Sign Out") { steam.signOut() }
                        .disabled(steam.isBusy)
                }
            } else {
                Text("Workshop downloads need a Steam account that owns Wallpaper Engine. Lumen uses Valve's own SteamCMD; your password goes straight to it and isn't saved. SteamCMD remembers the sign-in afterwards.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Form {
                    TextField("Steam account name", text: $username)
                    SecureField("Password", text: $password)
                }
                .formStyle(.columns)
                HStack {
                    if steam.isSigningIn {
                        ProgressView().controlSize(.small)
                        Text(steam.isInstalling ? "Installing SteamCMD…" : "Signing in…")
                            .foregroundStyle(.secondary)
                    }
                    if let error = steam.signInError {
                        Text(error).foregroundStyle(.red).font(.system(size: 12))
                    }
                    Spacer()
                    Button("Sign In") {
                        steam.signIn(username: username, password: password)
                        password = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.isEmpty || password.isEmpty || steam.isSigningIn)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
    }

    @ViewBuilder
    private func promptView(_ prompt: SteamWorkshop.Prompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch prompt {
            case .guardCode(let email):
                Text(email ? "Enter the Steam Guard code Steam emailed you." : "Enter the code from the Steam Mobile app.")
                    .font(.system(size: 13, weight: .semibold))
                HStack {
                    TextField("Code", text: $guardCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(sendGuardCode)
                    Button("Continue", action: sendGuardCode)
                        .disabled(guardCode.isEmpty)
                    Button("Cancel") { model.steam.cancelPrompt() }
                }
            case .mobileConfirmation:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Approve the sign-in in the Steam Mobile app on your phone.")
                        .font(.system(size: 13))
                }
            case .password:
                Text("Steam needs your password again. Sign out and sign in once more.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.6)))
    }

    private func downloadsList(_ steam: SteamWorkshop) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear Finished") { steam.clearFinished() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(steam.downloads) { download in
                        DownloadRow(download: download) { id in
                            dismiss()
                            model.router.open(.wallpaper(id))
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
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

private struct DownloadRow: View {
    let download: SteamWorkshop.Download
    let open: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: download.previewURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.06)
            }
            .frame(width: 54, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: download.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                status
            }
            Spacer()
            if case .done(let id?) = download.state {
                Button("Show") { open(id) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    @ViewBuilder
    private var status: some View {
        switch download.state {
        case .queued:
            Text("Waiting").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .preparing:
            Text("Starting SteamCMD…").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress).frame(width: 140)
            } else {
                Text("Downloading…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        case .importing:
            Text("Adding to library…").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .done:
            Label("In your library", systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(Theme.playing)
        case .failed(let message):
            Text(message).font(.system(size: 11.5)).foregroundStyle(.red).lineLimit(2)
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
            HStack(spacing: 10) {
                Button { navigator.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                Button { navigator.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                Button { navigator.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }
                Text(verbatim: currentURL?.host() ?? "steamcommunity.com")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            }
            .padding(10)
            SteamWebView(url: URL(string: "https://steamcommunity.com/app/431960/workshop/")!, navigator: navigator) { url in
                currentURL = url
            }
        }
        .frame(width: 1100, height: 760)
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
