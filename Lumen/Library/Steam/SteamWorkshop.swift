import Foundation
import Observation

/// What Steam says about a Workshop item.
struct WorkshopItemDetails: Sendable {
    let id: String
    var title: String
    var previewURL: URL?
    var fileSize: Int64?
}

/// Queues Wallpaper Engine Workshop downloads under the user's native or SteamCMD sign-in.
@MainActor
@Observable
final class SteamWorkshop {
    enum Prompt: Equatable {
        case guardCode(email: Bool)
        case mobileConfirmation
    }

    struct Download: Identifiable, Equatable {
        enum State: Equatable {
            case queued
            case preparing
            case downloading(Double?)
            case importing
            case done(UUID?)
            case failed(String)
        }

        let id: String
        var title: String
        var previewURL: URL?
        var state: State
    }

    static let appID = "431960"
    private static let accountKey = "steamAccountName"

    private var steamCMDAccount: String? = UserDefaults.standard.string(forKey: SteamWorkshop.accountKey)
    private var nativeAccount: String?
    var account: String? { nativeAccount ?? steamCMDAccount }
    var usesSteamCMD: Bool { nativeAccount == nil && steamCMDAccount != nil }
    private(set) var qrChallenge: URL?
    private(set) var isQRSignIn = false
    private(set) var prompt: Prompt?
    private(set) var downloads: [Download] = []
    private(set) var isSigningIn = false
    private(set) var signInError: String?
    private(set) var isInstalling = false

    /// Downloading Wallpaper Engine's shared scene assets into Lumen's own folder.
    enum AssetsDownload: Equatable {
        case idle
        case downloading(Double?)
        case failed(String)
    }

    private(set) var assetsDownload: AssetsDownload = .idle

    @ObservationIgnored private var assetsTask: Task<Void, Never>?
    @ObservationIgnored private var session: SteamCMDSession?
    @ObservationIgnored private var qrTask: Task<Void, Never>?
    @ObservationIgnored private var nativeCredential: SteamNativeCredential?
    @ObservationIgnored private var pendingPassword: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
        do {
            nativeCredential = try SteamNativeKeychain.load()
            nativeAccount = nativeCredential?.account
        } catch {
            signInError = SteamNativeError.keychain.localizedDescription
        }
    }

    var isSignedIn: Bool { account != nil }
    var isBusy: Bool { worker != nil || isSigningIn }

    /// Either sign-in can fetch the assets: the native client reads the app depot directly,
    /// SteamCMD downloads the content depot with its cached login.
    var canDownloadSceneAssets: Bool { isSignedIn }

    // MARK: Scene assets

    /// Fetches Wallpaper Engine's `assets/` from Steam and installs it as Lumen's own copy.
    /// `onInstalled` runs once the new folder is in place, so open scenes can reload.
    func downloadSceneAssets(onInstalled: @escaping @MainActor () -> Void) {
        // SteamCMD runs one session at a time; Workshop downloads wait for this one.
        guard assetsTask == nil, worker == nil, !isSigningIn, isSignedIn else { return }
        assetsDownload = .downloading(nil)
        assetsTask = Task { [weak self] in
            guard let self else { return }
            let staging = AppPaths.root.appending(path: "SceneAssets.download-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: AppPaths.root, withIntermediateDirectories: true)
                if let credential = nativeCredential {
                    try await SteamSceneAssetsDownload().download(credential: credential, to: staging) { [weak self] progress in
                        await self?.reportAssetsProgress(progress)
                    }
                } else if let steamCMDAccount {
                    try await downloadSceneAssetsWithSteamCMD(account: steamCMDAccount, to: staging)
                }
                try SceneAssetsLocator.install(staging)
                assetsDownload = .idle
                onInstalled()
            } catch is CancellationError {
                assetsDownload = .idle
            } catch {
                if let failure = error as? SteamCMD.Failure, failure == .notSignedIn {
                    steamCMDAccount = nil
                    UserDefaults.standard.removeObject(forKey: Self.accountKey)
                }
                if let failure = error as? SteamNativeError, failure == .signInRequired || failure == .expired {
                    try? SteamNativeKeychain.remove()
                    nativeCredential = nil
                    nativeAccount = nil
                }
                assetsDownload = .failed(error.localizedDescription)
            }
            assetsTask = nil
            startNext()
        }
    }

    /// Downloads the content depot (about 360 MB) with SteamCMD's cached login, keeps only its
    /// `assets` folder (about 85 MB) and deletes the rest.
    private func downloadSceneAssetsWithSteamCMD(account: String, to staging: URL) async throws {
        try await ensureInstalled()
        let depotID = String(SteamSceneAssetsDownload.contentDepot)
        let result = await runSteamCMD(["+@sSteamCmdForcePlatformType", "windows", "+login", account,
                                        "+download_depot", Self.appID, depotID, "+quit"])
        guard result.loggedIn, result.status == 0, let path = result.depotFolders.last else {
            throw result.failure ?? SteamCMD.Failure.downloadFailed(String(localized: "SteamCMD did not confirm the download."))
        }
        let root = SteamCMD.folder.resolvingSymlinksInPath().standardizedFileURL
        let depot = URL(fileURLWithPath: path.replacingOccurrences(of: "\\", with: "/"))
            .resolvingSymlinksInPath().standardizedFileURL
        guard depot.path.hasPrefix(root.path + "/"), depot.lastPathComponent == "depot_\(depotID)" else {
            throw SteamCMD.Failure.downloadFailed(String(localized: "SteamCMD couldn't download Wallpaper Engine's files."))
        }
        defer { try? FileManager.default.removeItem(at: depot) }
        let assets = depot.appending(path: "assets", directoryHint: .isDirectory)
        guard SceneAssetsLocator.isAssetsFolder(assets) else {
            throw SteamCMD.Failure.downloadFailed(String(localized: "SteamCMD couldn't download Wallpaper Engine's files."))
        }
        try FileManager.default.moveItem(at: assets, to: staging)
    }

    private func reportAssetsProgress(_ progress: Double) {
        // Thousands of small files finish quickly; redraw only in visible steps.
        if case .downloading(let shown) = assetsDownload, let shown, progress - shown < 0.005, progress < 1 { return }
        assetsDownload = .downloading(progress)
    }

    // MARK: Account

    func beginQRSignIn() {
        guard !isBusy, nativeCredential == nil else { return }
        signInError = nil
        isSigningIn = true
        isQRSignIn = true
        qrTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.qrChallenge = nil
                self.qrTask = nil
                self.isQRSignIn = false
                self.isSigningIn = false
                self.startNext()
            }
            do {
                let auth = SteamQRSignIn()
                var challenge = try await auth.begin()
                let deadline = ContinuousClock.now + .seconds(180)
                self.qrChallenge = challenge.url
                while ContinuousClock.now < deadline {
                    try await Task.sleep(for: .seconds(challenge.interval))
                    switch try await auth.poll(challenge) {
                    case .waiting(let updated):
                        challenge = updated
                        self.qrChallenge = updated.url
                    case .authorised(let credential):
                        try Task.checkCancellation()
                        try SteamNativeKeychain.store(credential)
                        self.nativeCredential = credential
                        self.nativeAccount = credential.account
                        return
                    }
                }
                throw SteamNativeError.expired
            } catch is CancellationError {
                // Closing the panel or cancelling the challenge leaves the account unchanged.
            } catch {
                self.signInError = error.localizedDescription
            }
        }
    }

    func cancelQRSignIn() {
        qrTask?.cancel()
    }

    /// Signs in once; SteamCMD remembers the login so downloads don't ask again.
    func signIn(username: String, password: String) {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isBusy else { return }
        isSigningIn = true
        signInError = nil
        pendingPassword = password
        Task {
            do {
                try await ensureInstalled()
                let result = await runSteamCMD(["+login", name, "+quit"])
                if result.status == 0, result.loggedIn {
                    steamCMDAccount = name
                    UserDefaults.standard.set(name, forKey: Self.accountKey)
                } else if let failure = result.failure {
                    signInError = failure == .cancelled ? nil : failure.localizedDescription
                } else {
                    signInError = String(localized: "Steam sign-in didn't finish.")
                }
            } catch {
                signInError = error.localizedDescription
            }
            pendingPassword = nil
            prompt = nil
            isSigningIn = false
            startNext()
        }
    }

    func signOut() {
        guard !isBusy else { return }
        signInError = nil
        if nativeCredential != nil {
            do {
                try SteamNativeKeychain.remove()
                nativeCredential = nil
                nativeAccount = nil
            } catch {
                signInError = error.localizedDescription
                return
            }
        }
        SteamCMD.signOut()
        steamCMDAccount = nil
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
    }

    /// Answers SteamCMD's current prompt.
    func answer(_ text: String) {
        prompt = nil
        session?.send(text)
    }

    func cancelPrompt() {
        prompt = nil
        session?.cancel()
    }

    // MARK: Downloads

    /// Accepts a Workshop link (`…/filedetails/?id=123`) or a bare id.
    static func itemID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 6, let id = numericID(trimmed) { return String(id) }
        if let components = URLComponents(string: trimmed),
           let value = components.queryItems?.first(where: { $0.name == "id" })?.value,
           let id = numericID(value) { return String(id) }
        if let match = trimmed.firstMatch(of: /(?:id=|\/)([0-9]{6,})/), let id = numericID(String(match.1)) {
            return String(id)
        }
        return nil
    }

    private static func numericID(_ value: String) -> UInt64? {
        guard value.utf8.allSatisfy({ (48...57).contains($0) }), let id = UInt64(value), id > 0 else { return nil }
        return id
    }

    func download(_ requestedID: String) {
        guard let canonical = Self.numericID(requestedID) else { return }
        let id = String(canonical)
        guard !downloads.contains(where: { $0.id == id && !$0.isFinished }) else { return }
        if let existing = library.wallpaper(workshopID: id) {
            downloads.insert(Download(id: id, title: existing.title, previewURL: nil, state: .done(existing.id)), at: 0)
            return
        }
        downloads.removeAll { $0.id == id }
        downloads.insert(Download(id: id, title: String(localized: "Workshop item \(id)"), previewURL: nil, state: .queued), at: 0)
        Task {
            if let details = await Self.details(for: id), let index = downloads.firstIndex(where: { $0.id == id }) {
                downloads[index].title = details.title
                downloads[index].previewURL = details.previewURL
            }
        }
        startNext()
    }

    func clearFinished() {
        downloads.removeAll { $0.isFinished }
    }

    private func startNext() {
        guard worker == nil, assetsTask == nil, !isSigningIn, let next = downloads.last(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.run(next.id)
            self?.worker = nil
            self?.startNext()
        }
    }

    private func run(_ id: String) async {
        guard isSignedIn else {
            update(id, .failed(SteamCMD.Failure.notSignedIn.localizedDescription))
            return
        }
        update(id, .preparing)
        do {
            if let credential = nativeCredential, let itemID = UInt64(id), let appID = UInt64(Self.appID) {
                let scratch = AppPaths.root.appending(path: "SteamNativeDownloads/\(UUID().uuidString)", directoryHint: .isDirectory)
                defer { try? FileManager.default.removeItem(at: scratch) }
                let folder = scratch.appending(path: id, directoryHint: .isDirectory)
                update(id, .downloading(nil))
                try await SteamNativeDownload(appID: appID).download(itemID: itemID, credential: credential, to: folder) { [weak self] progress in
                    await self?.update(id, .downloading(progress))
                }
                await importDownload(id, folder: folder)
            } else if let steamCMDAccount {
                try await ensureInstalled()
                try FileManager.default.createDirectory(at: SteamCMD.contentFolder, withIntermediateDirectories: true)
                let folder = try await downloadWithSteamCMD(id, account: steamCMDAccount)
                defer { try? FileManager.default.removeItem(at: folder) }
                await importDownload(id, folder: folder)
            }
        } catch {
            if let failure = error as? SteamCMD.Failure, failure == .notSignedIn {
                steamCMDAccount = nil
                UserDefaults.standard.removeObject(forKey: Self.accountKey)
            }
            if let failure = error as? SteamNativeError, failure == .signInRequired || failure == .expired {
                try? SteamNativeKeychain.remove()
                nativeCredential = nil
                nativeAccount = nil
            }
            update(id, .failed(error.localizedDescription))
        }
    }

    private func importDownload(_ id: String, folder: URL) async {
        update(id, .importing)
        let result = await library.importFiles([folder], source: "steam")
        if let added = result.added.first {
            update(id, .done(added.id))
        } else {
            update(id, .failed(result.failures.first?.reason ?? String(localized: "Couldn't add it to the library.")))
        }
    }

    private func update(_ id: String, _ state: Download.State) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = state
    }

    private func downloadWithSteamCMD(_ id: String, account: String) async throws -> URL {
        let arguments = ["+force_install_dir", SteamCMD.contentFolder.path, "+login", account,
                         "+workshop_download_item", Self.appID, id, "validate", "+quit"]
        let root = SteamCMD.contentFolder.resolvingSymlinksInPath().standardizedFileURL
        var authenticated = false
        var retries = 0
        while true {
            let result = await runSteamCMD(arguments) { [weak self] event in
                switch event {
                case .progress(let value): self?.update(id, .downloading(value))
                case .loggedIn: self?.update(id, .downloading(nil))
                default: break
                }
            }
            authenticated = authenticated || result.loggedIn
            if result.loggedIn, result.status == 0, let path = result.downloads[id] {
                let folder = URL(fileURLWithPath: path.replacingOccurrences(of: "\\", with: "/"))
                    .resolvingSymlinksInPath().standardizedFileURL
                guard folder.path.hasPrefix(root.path + "/"), folder.lastPathComponent == id,
                      WEProject.isProjectFolder(folder) else {
                    throw SteamCMD.Failure.downloadFailed(String(localized: "SteamCMD did not return a Wallpaper Engine project."))
                }
                return folder
            }
            guard let failure = result.failure else {
                throw SteamCMD.Failure.downloadFailed(String(localized: "SteamCMD did not confirm the download."))
            }
            guard let delay = SteamCMD.retryDelay(attempt: retries, authenticated: authenticated, failure: failure,
                                                  cancelled: Task.isCancelled) else { throw failure }
            retries += 1
            update(id, .preparing)
            try await Task.sleep(for: delay)
        }
    }

    // MARK: SteamCMD

    private func ensureInstalled() async throws {
        guard !SteamCMD.isInstalled else { return }
        isInstalling = true
        defer { isInstalling = false }
        try await SteamCMD.install()
    }

    /// Runs SteamCMD, answering the password prompt with the sign-in password (if any) and
    /// surfacing Steam Guard prompts to the UI.
    private func runSteamCMD(_ arguments: [String], events: ((SteamCMDSession.Event) -> Void)? = nil) async -> SteamCMDSession.Result {
        let session = SteamCMDSession(arguments: ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "0"] + arguments)
        session.onEvent = { [weak self, weak session] event in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                switch event {
                case .needsPassword:
                    if let password = self.pendingPassword {
                        self.pendingPassword = nil
                        session.send(password)
                    } else {
                        session.stop(.notSignedIn)
                    }
                case .needsGuardCode(let email):
                    self.prompt = .guardCode(email: email)
                case .needsMobileConfirmation:
                    self.prompt = .mobileConfirmation
                case .loggedIn:
                    self.prompt = nil
                default:
                    break
                }
                events?(event)
            }
        }
        self.session = session
        defer {
            self.session = nil
            prompt = nil
        }
        return await session.run()
    }

    // MARK: Details

    /// Title and preview from Steam's public API, falling back to the item's web page.
    static func details(for id: String) async -> WorkshopItemDetails? {
        if let fromAPI = await apiDetails(for: id) { return fromAPI }
        guard let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)"),
              let (data, _) = try? await URLSession.shared.data(from: url)
        else { return nil }
        let html = String(decoding: data, as: UTF8.self)
        func meta(_ property: String) -> String? {
            html.firstMatch(of: try! Regex("<meta property=\"\(property)\" content=\"([^\"]*)\"")).flatMap { $0.output[1].substring.map(String.init) }
        }
        guard let title = meta("og:title") else { return nil }
        let cleaned = title.replacingOccurrences(of: "Steam Workshop::", with: "")
        return WorkshopItemDetails(id: id, title: WEProject.plainText(cleaned), previewURL: meta("og:image").flatMap(URL.init(string:)), fileSize: nil)
    }

    private static func apiDetails(for id: String) async -> WorkshopItemDetails? {
        guard let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("itemcount=1&publishedfileids%5B0%5D=\(id)".utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any],
              let item = (response["publishedfiledetails"] as? [[String: Any]])?.first,
              (item["result"] as? Int) == 1
        else { return nil }
        return WorkshopItemDetails(
            id: id,
            title: item["title"] as? String ?? id,
            previewURL: (item["preview_url"] as? String).flatMap(URL.init(string:)),
            fileSize: (item["file_size"] as? NSNumber)?.int64Value ?? Int64(item["file_size"] as? String ?? "")
        )
    }
}

extension SteamWorkshop.Download {
    var isFinished: Bool {
        switch state {
        case .done, .failed: true
        default: false
        }
    }
}
