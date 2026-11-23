import Accelerate
import Foundation
import os

/// The system's audio spectrum in Wallpaper Engine's shape: 64 bands per channel from bass
/// to treble, roughly 0…1, plus the 32- and 16-band versions shaders and scripts ask for.
struct AudioBands: Sendable {
    static let bandCount = 64

    var left: [Float]
    var right: [Float]
    private(set) var left32: [Float]
    private(set) var right32: [Float]
    private(set) var left16: [Float]
    private(set) var right16: [Float]

    static let silent = AudioBands(left: Array(repeating: 0, count: bandCount), right: Array(repeating: 0, count: bandCount))

    init(left: [Float], right: [Float]) {
        self.left = left
        self.right = right
        left32 = Self.halve(left)
        right32 = Self.halve(right)
        left16 = Self.halve(left32)
        right16 = Self.halve(right32)
    }

    var isSilent: Bool { !left.contains { $0 > 0.001 } && !right.contains { $0 > 0.001 } }

    /// The bands at Wallpaper Engine's 16, 32 or 64 resolution.
    func channel(right isRight: Bool, resolution: Int) -> [Float] {
        switch resolution {
        case ...16: isRight ? right16 : left16
        case ...32: isRight ? right32 : left32
        default: isRight ? right : left
        }
    }

    /// Wallpaper Engine's "audio response" for effects and particle emitters: the average of
    /// 16-band values from `start` through `end` (mode 1 left, 2 right, 3 both), eased into
    /// `bounds` and raised to `exponent`.
    func response(mode: Int, start: Int, end: Int, bounds: SIMD2<Float>, exponent: Float) -> Float {
        guard mode > 0 else { return 1 }
        let low = max(0, min(start, end)), high = min(15, max(start, end))
        guard low <= high else { return 0 }
        var sum: Float = 0
        for index in low...high {
            if mode != 2 { sum += left16[index] }
            if mode != 1 { sum += right16[index] }
        }
        let average = sum / Float((high - low + 1) * (mode == 3 ? 2 : 1))
        let eased = Self.smoothstep(bounds.x, bounds.y, average)
        return min(max(pow(eased, exponent), 0), 1)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 != edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func halve(_ values: [Float]) -> [Float] {
        stride(from: 0, to: values.count - 1, by: 2).map { (values[$0] + values[$0 + 1]) / 2 }
    }
}

/// Turns blocks of PCM samples into smoothed `AudioBands` with an FFT.
final class AudioSpectrumAnalyzer {
    private let size = 2048
    private let hop = 1024
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var history: [[Float]]
    private var pending = 0
    private var smoothed: [[Float]]
    private var bandBins: [(Int, Int)] = []
    private var bandTilt: [Float] = []
    private var sampleRate: Double = 0
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]

    init() {
        fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        history = Array(repeating: Array(repeating: 0, count: size), count: 2)
        smoothed = Array(repeating: Array(repeating: 0, count: AudioBands.bandCount), count: 2)
        real = Array(repeating: 0, count: size / 2)
        imaginary = Array(repeating: 0, count: size / 2)
        magnitudes = Array(repeating: 0, count: size / 2)
    }

    /// Adds `frames` samples per channel (one or two channels); returns new bands every hop.
    func append(channels: [UnsafeBufferPointer<Float>], stride: Int, frames: Int, sampleRate: Double) -> AudioBands? {
        guard frames > 0, !channels.isEmpty else { return nil }
        if sampleRate != self.sampleRate { configure(sampleRate: sampleRate) }
        for channel in 0..<2 {
            let source = channels[min(channel, channels.count - 1)]
            var samples = history[channel]
            let count = min(frames, size)
            // Shift the window left and append the newest samples.
            samples.removeFirst(count)
            for frame in (frames - count)..<frames { samples.append(source[frame * stride]) }
            history[channel] = samples
        }
        pending += frames
        guard pending >= hop else { return nil }
        pending = 0
        let elapsed = Float(hop) / Float(sampleRate)
        for channel in 0..<2 { analyze(channel, elapsed: elapsed) }
        return AudioBands(left: smoothed[0], right: smoothed[1])
    }

    /// Lets the bands fall back to zero when no audio arrives.
    func reset() {
        for channel in 0..<2 {
            history[channel] = Array(repeating: 0, count: size)
            smoothed[channel] = Array(repeating: 0, count: AudioBands.bandCount)
        }
        pending = 0
    }

    private func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        let binWidth = sampleRate / Double(size)
        // Kick drums (50–100 Hz) land in the first two of 16 bands, as effects expect.
        let low = 45.0, high = min(16_000, sampleRate / 2 * 0.95)
        bandBins = []
        bandTilt = []
        for band in 0..<AudioBands.bandCount {
            let from = low * pow(high / low, Double(band) / Double(AudioBands.bandCount))
            let to = low * pow(high / low, Double(band + 1) / Double(AudioBands.bandCount))
            let first = max(1, Int((from / binWidth).rounded(.down)))
            let last = max(first, min(size / 2 - 1, Int((to / binWidth).rounded(.up)) - 1))
            bandBins.append((first, last))
            // Music has less energy higher up (about 3 dB per octave); level it out.
            bandTilt.append(Float(3 * log2(sqrt(from * to) / 400)))
        }
    }

    private func analyze(_ channel: Int, elapsed: Float) {
        var windowed = vDSP.multiply(history[channel], window)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeMutableBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                }
                fft.forward(input: split, output: &split)
                magnitudes.withUnsafeMutableBufferPointer { vDSP_zvabs(&split, 1, $0.baseAddress!, 1, vDSP_Length(size / 2)) }
            }
        }
        // A full-scale sine peaks at size/2 after the Hann window and vDSP's ×2 scaling.
        let scale = 2 / Float(size)
        // Bars fall with a ~90 ms half-life and rise almost at once.
        let fall = pow(0.5, elapsed / 0.09)
        var output = smoothed[channel]
        for band in 0..<AudioBands.bandCount {
            let (first, last) = bandBins[band]
            var peak: Float = 0
            for bin in first...last { peak = max(peak, magnitudes[bin]) }
            let decibels = 20 * log10(peak * scale + 1e-9) + bandTilt[band]
            let level = min(max((decibels + 60) / 48, 0), 1.2)
            let previous = output[band]
            output[band] = level >= previous ? previous + (level - previous) * 0.75 : max(level, previous * fall)
        }
        smoothed[channel] = output
    }
}

/// Shares one system-audio analysis between every audio-reactive wallpaper. Capture runs only
/// while at least one active wallpaper asks for it.
final class AudioSpectrumService: @unchecked Sendable {
    static let shared = AudioSpectrumService()

    private let state = OSAllocatedUnfairLock(initialState: AudioBands.silent)
    private let queue = DispatchQueue(label: "app.lumen.audio-spectrum", qos: .userInteractive)
    private var clients: Set<ObjectIdentifier> = []
    private var capture: SystemAudioCapture?
    private let analyzer = AudioSpectrumAnalyzer()

    /// The latest bands; cheap enough to read every frame from any thread.
    var bands: AudioBands { state.withLock { $0 } }

    /// Starts capture for `client` (idempotent).
    @MainActor
    func retain(_ client: AnyObject) {
        let id = ObjectIdentifier(client)
        guard !clients.contains(id) else { return }
        clients.insert(id)
        if clients.count == 1 { queue.async { self.start() } }
    }

    /// Stops capture once the last client lets go.
    @MainActor
    func release(_ client: AnyObject) {
        guard clients.remove(ObjectIdentifier(client)) != nil, clients.isEmpty else { return }
        queue.async { self.stop() }
    }

    private func start() {
        guard capture == nil else { return }
        do {
            let capture = try SystemAudioCapture(queue: queue) { [weak self] channels, stride, frames, sampleRate in
                guard let self, let bands = self.analyzer.append(channels: channels, stride: stride, frames: frames, sampleRate: sampleRate) else { return }
                self.state.withLock { $0 = bands }
            }
            self.capture = capture
            Log.engine.info("System audio capture started")
        } catch {
            Log.engine.error("System audio capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stop() {
        capture?.invalidate()
        capture = nil
        analyzer.reset()
        state.withLock { $0 = .silent }
        Log.engine.info("System audio capture stopped")
    }
}
