import AppKit
import AVFoundation

// Records a Lock Screen loop for a scene or web package folder, or a native wallpaper's resource
// folder, without installing anything.
// Usage: loop-recorder scene|web|codesea|prostrands <folder> <entry> <output.mov> [assets folder] [WxH]
let args = CommandLine.arguments
let kind = args[1], folder = URL(fileURLWithPath: args[2]), entry = args[3], output = URL(fileURLWithPath: args[4])
let assets = args.count > 5 && !args[5].isEmpty ? URL(fileURLWithPath: args[5]) : nil
let size: CGSize = {
    let parts = (args.count > 6 ? args[6] : "2560x1664").split(separator: "x").compactMap { Double($0) }
    return CGSize(width: parts[0], height: parts[1])
}()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let started = Date()
    do {
        if let native = NativeWallpaper(rawValue: kind) {
            var values: [String: PropertyValue] = [:]
            for property in native.properties { values[property.id] = property.defaultValue }
            try await Task.detached {
                switch native {
                case .codeSea:
                    try CodeSea.recordLoop(avatarURL: CodeSea.avatarURL(in: folder), values: values, size: size, scale: 2, to: output) { _ in }
                case .proStrands:
                    guard let image = PROStrands.imageURL(in: folder) else { throw CodeSea.SeaError("no image.png in \(folder.path)") }
                    try PROStrands.recordLoop(imageURL: image, values: values, size: size, to: output) { _ in }
                }
            }.value
            try await report(kind, output, started)
            exit(0)
        }
        let project = try WEProject.load(folder: folder)
        var values: [String: PropertyValue] = [:]
        for property in project.properties { values[property.id] = property.defaultValue }
        if kind == "scene" {
            let source = SceneLoopRecorder.Source(folder: folder, entry: entry, assets: assets, values: values)
            try await Task.detached {
                try SceneLoopRecorder.record(source, framing: WallpaperFraming(), scaling: .fill, size: size, to: output) { _ in }
            }.value
        } else {
            try await WebLoopRecorder.record(.folder(folder, entry: entry, id: UUID()), properties: project.properties, values: values,
                                             size: size, to: output) { _ in }
        }
        try await report(kind, output, started)
    } catch {
        print("FAIL", error.localizedDescription)
    }
    exit(0)
}
app.run()

func report(_ kind: String, _ output: URL, _ started: Date) async throws {
    let asset = AVURLAsset(url: output)
    let track = try await asset.loadTracks(withMediaType: .video).first
    let frames = try await track?.load(.nominalFrameRate) ?? 0
    let duration = try await asset.load(.duration).seconds
    let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.size] as? Int ?? 0
    print(String(format: "OK %@ %.1fs video, %.1f fps, recorded in %.1fs, %.1f MB", kind, duration, frames,
                 Date().timeIntervalSince(started), Double(bytes) / 1_048_576))
}

// LumenApp.swift (with @main) is left out of this tool; its window IDs are needed by views.
enum SceneID {
    static let main = "main"
    static let menuPreview = "menu-preview"
}
