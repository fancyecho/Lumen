import Foundation
import Observation

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case home, library, workshop, studio, playlists

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: String(localized: "Home")
        case .library: String(localized: "Library")
        case .workshop: String(localized: "Workshop")
        case .studio: String(localized: "Studio")
        case .playlists: String(localized: "Playlists")
        }
    }
}

enum Route: Hashable {
    case wallpaper(UUID)
    case studio(UUID)
    case playlist(UUID)
}

/// Navigation state for the main window: a tab plus a stack of detail pages.
@MainActor
@Observable
final class Router {
    var tab: AppTab = .home {
        didSet { if oldValue != tab { path.removeAll() } }
    }
    private(set) var path: [Route] = []
    var searchText = ""

    var route: Route? { path.last }

    func open(_ route: Route) {
        path.append(route)
    }

    func back() {
        _ = path.popLast()
    }

    func show(_ tab: AppTab) {
        self.tab = tab
        path.removeAll()
    }
}
