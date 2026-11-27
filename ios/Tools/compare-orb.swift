// Compares two orb shaders on the GPU, without a window or microphone.
// Usage: swift ios/Tools/compare-orb.swift before.metal after.metal [--benchmark]
// --calm-only checks forms through 0.55; --allow-visual-change benchmarks an intentional redesign.
import Foundation
import Metal

var paths = Array(CommandLine.arguments.dropFirst())
let benchmark = paths.contains("--benchmark")
let calmOnly = paths.contains("--calm-only")
let visualChange = paths.contains("--allow-visual-change") && !calmOnly
paths.removeAll { ["--benchmark", "--calm-only", "--allow-visual-change"].contains($0) }
guard paths.count == 2, let device = MTLCreateSystemDefaultDevice(),
      let queue = device.makeCommandQueue() else {
    fatalError("Provide two shader paths on a Mac with Metal support")
}
let side = 64
let pixels = side * side
let byteCount = pixels * MemoryLayout<SIMD4<Float>>.stride

func pipeline(_ path: String, side: Int = 64) throws -> MTLComputePipelineState {
    var source = try String(contentsOfFile: path, encoding: .utf8)
    source = source.replacingOccurrences(of: "#include <SwiftUI/SwiftUI_Metal.h>", with: "")
    // SwiftUI links stitchable functions at runtime. The harness calls the same
    // function body directly from a compute kernel instead.
    source = source.replacingOccurrences(of: "[[ stitchable ]]", with: "static")
    let gain = source.contains("float gain,") ? "v[12], " : ""
    source += """

    kernel void checkOrb(device float4 *out [[buffer(0)]],
                         constant float *v [[buffer(1)]],
                         const device float *wave [[buffer(2)]],
                         uint2 p [[thread_position_in_grid]]) {
        float2 size = float2(v[10], v[11]);
        float2 position = (float2(p) + 0.5) / \(side).0 * size;
        out[p.y * \(side) + p.x] = float4(fluidOrb(position, half4(1), size,
            v[0], v[1], v[2], v[3], v[4], v[5], float2(v[6], v[7]),
            v[8], v[9], min(size.x, size.y) * 0.3, \(gain)wave, 64));
    }
    """
    let library = try device.makeLibrary(source: source, options: nil)
    return try device.makeComputePipelineState(function: library.makeFunction(name: "checkOrb")!)
}

let pipelines = try paths.map { try pipeline($0) }
let outputs = (0..<2).map { _ in device.makeBuffer(length: byteCount, options: .storageModeShared)! }
var maxDifference: Float = 0
var changed = 0
var visibleDifferences = 0
let scenarios = 144
for scenario in 0..<scenarios {
    let morph: Float = (calmOnly ? [0, 0.25, 0.55] : [0, 0.25, 1])[scenario % 3]
    let level: Float = scenario % 2 == 0 ? 0 : 0.6
    var wave = (0..<64).map { i in Float(sin(Double(i) * 0.37)) * level }
    let peak = wave.reduce(Float(0)) { max($0, abs($1)) }
    let nominal: Float = scenario % 2 == 0 ? 340 : 84
    let width = nominal * (scenario % 5 == 0 ? 2 : 1) + nominal * 1.5
    let height = nominal * 2.5
    // time, morph, level, speakers, active, dark, lean x/y, gather, since, size, gain
    var values: [Float] = [Float(scenario) * 2.731, morph, level,
        scenario % 4 == 0 ? 4 : 1, scenario % 7 == 0 ? 0 : 1,
        scenario % 2 == 0 ? 1 : 0,
        [Float(-1.2), 0, 1.2][(scenario / 3) % 3],
        [Float(-1.2), 0, 1.2][(scenario / 9) % 3],
        scenario % 4 == 0 ? 1 : 0, [Float(0), 0.15, 0.7, 99][(scenario / 3) % 4],
        width, height, 0.12 / max(peak, 0.10)]
    let command = queue.makeCommandBuffer()!
    for index in 0..<2 {
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipelines[index])
        encoder.setBuffer(outputs[index], offset: 0, index: 0)
        encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 1)
        encoder.setBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 2)
        encoder.dispatchThreads(MTLSize(width: side, height: side, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { fatalError("GPU comparison failed: \(String(describing: command.error))") }
    let before = outputs[0].contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels)
    let after = outputs[1].contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels)
    for pixel in 0..<pixels {
        for channel in 0..<4 {
            let difference = abs(before[pixel][channel] - after[pixel][channel])
            guard difference.isFinite else { fatalError("Nonfinite output") }
            maxDifference = max(maxDifference, difference)
            if difference > 0 { changed += 1 }
            if difference > 1.0 / 255 { visibleDifferences += 1 }
        }
    }
}
print("\(scenarios) scenarios, \(scenarios * pixels) pixels; changed channels: \(changed); max difference: \(maxDifference); channels differing by more than 1/255: \(visibleDifferences)")
guard visibleDifferences == 0 || visualChange else { exit(1) }


// Optional GPU-only timing, separate from the 64px correctness comparison. This
// runs on the host Mac; it is not an iPhone UI, display-FPS or voice benchmark.
if benchmark {
    let benchmarkSide = 512
    let timedPipelines = try paths.map { try pipeline($0, side: benchmarkSide) }
    let output = device.makeBuffer(length: benchmarkSide * benchmarkSide * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
    var wave = (0..<64).map { Float(sin(Double($0) * 0.37)) * 0.6 }
    for (name, morph, since) in [("quiet", Float(0), Float(99)), ("signal", Float(1), Float(99)), ("wake", Float(0), Float(0.3))] {
        var durations = [[Double](), [Double]()]
        for round in 0..<14 {
            for index in (round % 2 == 0 ? [0, 1] : [1, 0]) {
                var values: [Float] = [40 + Float(round) * 0.03, morph, morph == 0 ? 0 : 0.6, 1, 1, 1, 0, 0, 1, since, 850, 850, 0.2]
                let command = queue.makeCommandBuffer()!
                let encoder = command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(timedPipelines[index])
                encoder.setBuffer(output, offset: 0, index: 0)
                encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 1)
                encoder.setBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 2)
                encoder.dispatchThreads(MTLSize(width: benchmarkSide, height: benchmarkSide, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                guard command.status == .completed, command.gpuEndTime > command.gpuStartTime else { fatalError("GPU timing unavailable") }
                if round >= 2 { durations[index].append((command.gpuEndTime - command.gpuStartTime) * 1000) }
            }
        }
        let medians = durations.map { values -> Double in let sorted = values.sorted(); return (sorted[5] + sorted[6]) / 2 }
        print(String(format: "Host Mac GPU, %@, 512x512, 12 paired samples: before %.3f ms, after %.3f ms (%+.1f%%)", name, medians[0], medians[1], (medians[1] / medians[0] - 1) * 100))
    }
}
