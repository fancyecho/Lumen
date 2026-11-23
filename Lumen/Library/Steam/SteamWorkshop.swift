import Foundation
import Observation

/// What Steam says about a Workshop item.
struct WorkshopItemDetails: Sendable {
    let id: String
    var title: String
    var previewURL: URL?
    var fileSize: Int64?
}

/// Steam Workshop downloads for Wallpaper Engine (app 431960) through SteamCMD, with the
/// person's own Steam account. Lumen never stores the password.
@MainActor
@Observable
final class SteamWorkshop {
    enum Prompt: Equatable {
        case password
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

    private(set) var account: String? = UserDefaults.standard.string(forKey: SteamWorkshop.accountKey)
    private(set) var prompt: Prompt?
    private(set) var downloads: [Download] = []
    private(set) var isSigningIn = false
    private(set) var signInError: String?
    private(set) var isInstalling = false

    @ObservationIgnored private var session: SteamCMDSession?
    @ObservationIgnored private var pendingPassword: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let library: LibraryStore

    init(library: LibraryStore) {
        self.library = library
    }

    var isSignedIn: Bool { account != nil }
    var isBusy: Bool { worker != nil || isSigningIn }

    // MARK: Account

    /// Signs in once; SteamCMD remembers the login so downloads don't ask again.
    func signIn(username: String, password: String) {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        pendingPassword = password
        Task {
            do {
                try await ensureInstalled()
                let status = try await runSteamCMD(["+login", name, "+quit"])
                if status == 0 {
                    account = name
                    UserDefaults.standard.set(name, forKey: Self.accountKey)
                } else if signInError == nil {
                    signInError = String(localized: "Steam sign-in didn't finish.")
                }
            } catch {
                signInError = error.localizedDescription
            }
            pendingPassword = nil
            prompt = nil
            isSigningIn = false
        }
    }

    func signOut() {
        session?.cancel()
        SteamCMD.signOut()
        account = nil
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
        if trimmed.allSatisfy(\.isNumber), trimmed.count >= 6 { return trimmed }
        if let components = URLComponents(string: trimmed),
           let id = components.queryItems?.first(where: { $0.name == "id" })?.value, id.allSatisfy(\.isNumber) {
            return id
        }
        return trimmed.firstMatch(of: /(?:id=|\/)(\d{6,})/).map { String($0.1) }
    }

    func download(_ id: String) {
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
        guard worker == nil, let next = downloads.last(where: { $0.state == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.run(next.id)
            self?.worker = nil
            self?.startNext()
        }
    }

    private func run(_ id: String) async {
        guard let account else {
            update(id, .failed(SteamCMD.Failure.notSignedIn.localizedDescription))
            return
        }
        update(id, .preparing)
        do {
            try await ensureInstalled()
            try FileManager.default.createDirectory(at: SteamCMD.contentFolder, withIntermediateDirectories: true)
            var downloadedPath: String?
            var failure: SteamCMD.Failure?
            let status = try await runSteamCMD(
                ["+force_install_dir", SteamCMD.contentFolder.path, "+login", account,
                 "+workshop_download_item", Self.appID, id, "validate", "+quit"]
            ) { [weak self] event in
                switch event {
                case .progress(let value): self?.update(id, .downloading(value))
                case .loggedIn: self?.update(id, .downloading(nil))
                case .downloaded(_, let path): downloadedPath = path
                case .failed(let error): failure = error
                default: break
                }
            }
            let folder = downloadedPath.map { URL(fileURLWithPath: $0.replacingOccurrences(of: "\\", with: "/")) }
                ?? SteamCMD.contentFolder.appending(path: "steamapps/workshop/content/\(Self.appID)/\(id)")
            guard WEProject.isProjectFolder(folder) else {
                throw failure ?? SteamCMD.Failure.downloadFailed(status == 0 ? String(localized: "nothing was downloaded") : "SteamCMD \(status)")
            }
            update(id, .importing)
            let result = await library.importFiles([folder], source: "steam")
            // Lumen keeps its own copy; SteamCMD's is no longer needed.
            try? FileManager.default.removeItem(at: folder)
            if let added = result.added.first {
                update(id, .done(added.id))
            } else {
                update(id, .failed(result.failures.first?.reason ?? String(localized: "Couldn't add it to the library.")))
            }
        } catch {
            update(id, .failed(error.localizedDescription))
        }
    }

    private func update(_ id: String, _ state: Download.State) {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        downloads[index].state = state
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
    private func runSteamCMD(_ arguments: [String], events: ((SteamCMDSession.Event) -> Void)? = nil) async throws -> Int32 {
        let session = SteamCMDSession(arguments: ["+@ShutdownOnFailedCommand", "1", "+@NoPromptForPassword", "0"] + arguments)
        session.onEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .needsPassword:
                    if let password = self.pendingPassword {
                        self.pendingPassword = nil
                        session.send(password)
                    } else {
                        self.prompt = .password
                    }
                case .needsGuardCode(let email):
                    self.prompt = .guardCode(email: email)
                case .needsMobileConfirmation:
                    self.prompt = .mobileConfirmation
                case .loggedIn:
                    if self.prompt == .mobileConfirmation { self.prompt = nil }
                case .failed(let failure):
                    if self.isSigningIn { self.signInError = failure.localizedDescription }
                default:
                    break
                }
                events?(event)
            }
        }
        self.session = session
        defer { self.session = nil }
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
