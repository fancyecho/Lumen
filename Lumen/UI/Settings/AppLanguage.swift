import AppKit

/// In-app language override. macOS reads `AppleLanguages` from the app's own
/// defaults domain at launch, so a change takes effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    /// Shown in its own language so it's recognisable whatever the UI language is.
    var label: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        }
    }

    private var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }

    /// Reads only the app's own domain; the global default would always look "set".
    static var current: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
              let first = languages.first
        else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// The choice in effect for this run; captured at launch by the app delegate.
    static let atLaunch = current

    /// The language the running process actually resolved at launch.
    static var active: AppLanguage {
        let resolved = Bundle.main.preferredLocalizations.first ?? "en"
        return resolved.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    func save() {
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        let bundlePath = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
