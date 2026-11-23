import AVFoundation
import Foundation

/// A scene's sound objects (background music, ambience). They follow the app's audio
/// settings and pause with the wallpaper.
final class SceneSoundPlayer: @unchecked Sendable {
    private struct Track {
        let player: AVAudioPlayer
        let volume: Float
    }

    private var tracks: [Track] = []
    private var muted = true
    private var masterVolume: Float = 1
    private var playing = false

    init(document: SceneDocument, files: SceneFileSystem, values: SceneValues) {
        for object in document.objects where object.kind == .sound && object.visible {
            let paths = (object.raw["sound"] as? [Any])?.compactMap { $0 as? String } ?? []
            guard let path = paths.first, let data = files.data(path), let player = try? AVAudioPlayer(data: data) else { continue }
            let mode = object.raw["playbackmode"] as? String ?? "loop"
            player.numberOfLoops = mode == "single" ? 0 : -1
            player.prepareToPlay()
            tracks.append(Track(player: player, volume: values.float(object.raw["volume"], default: 1)))
        }
    }

    var isEmpty: Bool { tracks.isEmpty }

    func configure(muted: Bool, volume: Float) {
        self.muted = muted
        masterVolume = volume
        apply()
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        apply()
    }

    private func apply() {
        for track in tracks {
            track.player.volume = track.volume * masterVolume
            if playing && !muted {
                if !track.player.isPlaying { track.player.play() }
            } else if track.player.isPlaying {
                track.player.pause()
            }
        }
    }
}
