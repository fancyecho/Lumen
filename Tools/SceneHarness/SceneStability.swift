import Foundation
import Metal
import QuartzCore

enum SceneStability {
    private struct Sample {
        let time: Double
        let medianGPU: Double
        let p90GPU: Double
        let footprint: Double
        let metal: Double
    }

    static func run(
        _ instance: SceneInstance, minutes: Double, queue: MTLCommandQueue, audio: AudioBands
    ) throws -> Bool {
        let frameInterval = 1.0 / 30
        let duration = minutes * 60
        let start = CACurrentMediaTime()
        let window = min(15, (duration - 5) / 3)
        var nextSample = 5 + window
        var gpuTimes: [Double] = []
        var samples: [Sample] = []
        var frames = 0
        var lastFrame = start
        instance.setPlaying(true)
        defer { instance.setPlaying(false) }

        while lastFrame - start < duration {
            let now = CACurrentMediaTime()
            let elapsed = now - start
            let delta = Float(min(now - lastFrame, 0.1))
            lastFrame = now
            let time = try autoreleasepool {
                guard let command = queue.makeCommandBuffer() else { throw CocoaError(.featureUnsupported) }
                let center = SIMD2<Float>(repeating: 0.5)
                instance.encode(into: command, frame: .init(
                    time: Float(elapsed), delta: delta, pointerCanvas: nil, daytime: 0.5,
                    pointer: center, pointerLast: center, cameraOffset: .zero, parallax: center, audio: audio
                ))
                command.commit()
                command.waitUntilCompleted()
                guard command.status == .completed else { throw command.error ?? CocoaError(.featureUnsupported) }
                return (command.gpuEndTime - command.gpuStartTime) * 1_000
            }
            frames += 1
            if elapsed > 5, time.isFinite, time > 0 { gpuTimes.append(time) }
            if elapsed >= nextSample || (elapsed >= duration && lastFrame - start - (samples.last?.time ?? 5) >= window / 2), !gpuTimes.isEmpty {
                gpuTimes.sort()
                let sample = Sample(time: elapsed, medianGPU: gpuTimes[gpuTimes.count / 2],
                                    p90GPU: gpuTimes[(gpuTimes.count - 1) * 9 / 10],
                                    footprint: try memoryFootprint(),
                                    metal: Double(queue.device.currentAllocatedSize) / 1_048_576)
                samples.append(sample)
                gpuTimes.removeAll(keepingCapacity: true)
                nextSample += window
                print(String(format: "  %6.1fs  GPU p50 %6.2f ms p90 %6.2f ms  footprint %6.1f MiB  Metal %6.1f MiB",
                             sample.time, sample.medianGPU, sample.p90GPU, sample.footprint, sample.metal))
                fflush(stdout)
            }
            let remaining = now + frameInterval - CACurrentMediaTime()
            if remaining > 0 { RunLoop.main.run(until: Date().addingTimeInterval(remaining)) }
        }

        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return false }
        let footprintGrowth = last.footprint - first.footprint
        let metalGrowth = last.metal - first.metal
        let gpuGrowth = last.medianGPU - first.medianGPU
        let passed = footprintGrowth <= max(32, first.footprint * 0.1)
            && metalGrowth <= max(16, first.metal * 0.1)
            && gpuGrowth <= max(2, first.medianGPU * 0.25)
        print(String(format: "%@ %d frames at %.1f fps  Δfootprint %+.1f MiB  ΔMetal %+.1f MiB  ΔGPU %+.2f ms",
                     passed ? "PASS" : "FAIL", frames, Double(frames) / (lastFrame - start),
                     footprintGrowth, metalGrowth, gpuGrowth))
        return passed
    }

    private static func memoryFootprint() throws -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw CocoaError(.featureUnsupported) }
        return Double(info.phys_footprint) / 1_048_576
    }
}
