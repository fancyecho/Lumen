import CoreAudio
import Foundation

/// Listens to everything the Mac is playing through a Core Audio process tap (macOS 14.2+),
/// so audio-reactive wallpapers can follow the music. The first use asks for the "System
/// Audio Recording" permission; samples are analysed in memory and never stored.
final class SystemAudioCapture {
    typealias Handler = (_ channels: [UnsafeBufferPointer<Float>], _ stride: Int, _ frames: Int, _ sampleRate: Double) -> Void

    enum Failure: LocalizedError {
        case coreAudio(String, OSStatus)
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .coreAudio(let step, let status): "\(step) failed (\(status))"
            case .unsupportedFormat: "the tap's audio format isn't 32-bit float"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let queue: DispatchQueue
    private let handler: Handler

    init(queue: DispatchQueue, handler: @escaping Handler) throws {
        self.queue = queue
        self.handler = handler
        do {
            try start()
        } catch {
            invalidate()
            throw error
        }
        // Headphones plugged in, AirPlay picked…: rebuild on the new output's clock.
        var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.teardownDevice()
            try? self.start()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            outputListener = listener
        }
    }

    deinit { invalidate() }

    func invalidate() {
        if let listener = outputListener {
            var address = Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            outputListener = nil
        }
        teardownDevice()
    }

    private func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Lumen audio-reactive wallpapers"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        try check("Reading the tap format", AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &format))
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            throw Failure.unsupportedFormat
        }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lumen Audio Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("AudioHardwareCreateAggregateDevice", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID))

        let sampleRate = format.mSampleRate
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let handler = self.handler
        try check("AudioDeviceCreateIOProcIDWithBlock", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, let data = first.mData else { return }
            if interleaved {
                let channels = max(Int(first.mNumberChannels), 1)
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                let base = data.assumingMemoryBound(to: Float.self)
                let views = (0..<min(channels, 2)).map { UnsafeBufferPointer(start: base + $0, count: frames * channels - $0) }
                handler(views, channels, frames, sampleRate)
            } else {
                let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let views = buffers.prefix(2).compactMap { buffer in
                    buffer.mData.map { UnsafeBufferPointer(start: $0.assumingMemoryBound(to: Float.self), count: frames) }
                }
                handler(views, 1, frames, sampleRate)
            }
        })
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, procID))
    }

    private func teardownDevice() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure.coreAudio(step, status) }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr else { throw Failure.coreAudio("Finding the output device", status) }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioDevicePropertyDeviceUID)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw Failure.coreAudio("Reading the output device", status) }
        return uid.takeRetainedValue() as String
    }
}
