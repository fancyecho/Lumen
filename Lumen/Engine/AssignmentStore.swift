import Foundation

/// Which wallpaper belongs on which display, keyed by stable display UUIDs.
/// "All displays" also covers screens plugged in later, unless excluded.
struct AssignmentStore: Codable, Equatable {
    var perDisplay: [String: UUID] = [:]
    var allDisplays: UUID?
    var excluded: Set<String> = []

    func resolve(_ displayID: String) -> UUID? {
        if excluded.contains(displayID) { return nil }
        return perDisplay[displayID] ?? allDisplays
    }

    mutating func assign(_ id: UUID, to target: DisplayTarget) {
        switch target {
        case .allDisplays:
            allDisplays = id
            perDisplay.removeAll()
            excluded.removeAll()
        case .display(let displayID):
            perDisplay[displayID] = id
            excluded.remove(displayID)
        }
    }

    mutating func clear(_ target: DisplayTarget) {
        switch target {
        case .allDisplays:
            allDisplays = nil
            perDisplay.removeAll()
            excluded.removeAll()
        case .display(let displayID):
            perDisplay[displayID] = nil
            if allDisplays != nil { excluded.insert(displayID) }
        }
    }

    mutating func remove(wallpaperID: UUID) {
        perDisplay = perDisplay.filter { $0.value != wallpaperID }
        if allDisplays == wallpaperID { allDisplays = nil }
    }

    private static let defaultsKey = "displayAssignments"

    static func load() -> AssignmentStore {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let store = try? JSONDecoder().decode(AssignmentStore.self, from: data)
        else { return AssignmentStore() }
        return store
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
