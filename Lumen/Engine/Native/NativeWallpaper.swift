import Foundation
import Metal

/// Wallpapers whose renderer is compiled into Lumen. Each is a library item whose package
/// folder holds the person's own resources, copied from the wallpaper's project folder on import
/// (Code Sea's portrait stays out of this repository, as it does in Code Sea's own).
enum NativeWallpaper: String, CaseIterable {
    case codeSea = "codesea"
    case proStrands = "prostrands"

    /// `PackageAsset.source` that marks a native wallpaper; `PackageAsset.entry` is the raw value.
    static let packageSource = "native"

    init?(package: PackageAsset?) {
        guard let package, package.source == Self.packageSource else { return nil }
        self.init(rawValue: package.entry)
    }

    /// Recognises a project folder (the wallpaper's source checkout) for import.
    static func detect(folder: URL) -> NativeWallpaper? {
        allCases.first { native in
            native.markers.allSatisfy { FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }
        }
    }

    private var markers: [String] {
        switch self {
        case .codeSea: ["Resources/Sea.metal", "Sources/SeaRenderer.swift"]
        case .proStrands: ["Resources/Shaders.metal", "Sources/StrandSim.swift"]
        }
    }

    /// Files copied into the library item, as (path in the project folder, name in the package).
    var importedFiles: [(source: String, stored: String)] {
        switch self {
        case .codeSea: [("Resources/avatar.png", CodeSea.avatarFile), ("Resources/preview.jpg", "preview.jpg")]
        case .proStrands: [("Resources/16InchPro.png", PROStrands.imageFile), ("Resources/preview.jpg", "preview.jpg")]
        }
    }

    /// A stored file the wallpaper can't play without (Code Sea plays without its portrait).
    var requiredFile: String? {
        switch self {
        case .codeSea: nil
        case .proStrands: PROStrands.imageFile
        }
    }

    var title: String {
        switch self {
        case .codeSea: String(localized: "Code Sea", table: "Native")
        case .proStrands: String(localized: "PRO Strands", table: "Native")
        }
    }

    var category: String {
        switch self {
        case .codeSea, .proStrands: "Abstract"
        }
    }

    /// Settings shown in the wallpaper's Customize panel. Rebuilt on every library load, so labels
    /// follow the app language and new settings appear without importing again.
    var properties: [WEProperty] {
        switch self {
        case .codeSea: CodeSea.properties
        case .proStrands: PROStrands.properties
        }
    }

    /// Applies the current property definitions to a stored item, keeping the person's values.
    static func refresh(_ wallpaper: inout Wallpaper) {
        guard var package = wallpaper.package, let native = NativeWallpaper(package: package) else { return }
        package.properties = native.properties
        let known = Set(package.properties.map(\.id))
        package.values = package.values.filter { known.contains($0.key) }
        wallpaper.package = package
    }
}

struct NativeRenderSettings: Equatable {
    /// Lumen's frame-rate setting; a native wallpaper's own adaptive rate never goes above it.
    var frameRate: Int
    var onBattery: Bool

    static let preview = NativeRenderSettings(frameRate: 30, onBattery: false)
}

extension WEProperty {
    static func slider(_ id: String, _ label: String, order: Int, value: Double, range: ClosedRange<Double>, step: Double = 1) -> WEProperty {
        WEProperty(id: id, kind: .slider, label: label, order: order, defaultValue: .number(value),
                   min: range.lowerBound, max: range.upperBound, step: step, precision: 0)
    }

    static func toggle(_ id: String, _ label: String, order: Int, value: Bool) -> WEProperty {
        WEProperty(id: id, kind: .bool, label: label, order: order, defaultValue: .bool(value))
    }

    static func choice(_ id: String, _ label: String, order: Int, value: String, options: [(String, String)]) -> WEProperty {
        WEProperty(id: id, kind: .combo, label: label, order: order, defaultValue: .string(value),
                   options: options.map { Option(label: $0.1, value: $0.0) })
    }
}

/// Compiles a native wallpaper's bundled Metal source once per run. Runtime compilation keeps the
/// build free of Xcode's optional Metal toolchain (the `.msl` extension stops Xcode compiling the
/// file at build time); callers run it off the main thread.
enum NativeShaders {
    private static let lock = NSLock()
    private static var libraries: [String: MTLLibrary] = [:]

    static func library(named name: String, device: MTLDevice) throws -> MTLLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let library = libraries[name] { return library }
        guard let url = Bundle.main.url(forResource: name, withExtension: "msl") else {
            throw CodeSea.SeaError("\(name).msl is missing from the app")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        libraries[name] = library
        return library
    }
}
