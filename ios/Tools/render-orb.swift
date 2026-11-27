// Renders the orb shader to an animated PNG, without a window or microphone: it wakes up,
// gathers into one body and flies with its wings, exactly as the app draws it.
// Usage: swift ios/Tools/render-orb.swift <FluidOrb.metal> <out.png> [--dark] [--width 360]
//        [--height 360] [--seconds 6] [--fps 20] [--start 40] [--backdrop 0d1117] [--radius 24]
//        [--morph 1 --signal --steady] [--transition] [--level 0.6] [--gather 1] [--bleed 0]
// --signal is a synthetic speech-shaped fixture, never a recording or microphone input.
// Without --backdrop the picture is transparent. The README's banner is made with:
//   swift ios/Tools/render-orb.swift ios/Listen/Views/FluidOrb.metal design/figures/orb.png \
//     --dark --width 840 --height 330 --seconds 5 --fps 15 --backdrop 0d1117 --radius 28
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: Double) -> Double {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count,
          let value = Double(arguments[index + 1]) else { return fallback }
    arguments.removeSubrange(index...(index + 1))
    return value
}
let width = Int(option("--width", 360))
let height = Int(option("--height", 360))
let radius = Float(option("--radius", 24))
let seconds = option("--seconds", 6)
let fps = option("--fps", 20)
let start = option("--start", 40)
let morph = Float(option("--morph", 0))
let level = Float(option("--level", 0))
let gather = Float(option("--gather", 1))
let requestedBleed = option("--bleed", -1)
let signal = arguments.contains("--signal")
let steady = arguments.contains("--steady")
let transition = arguments.contains("--transition")
arguments.removeAll { ["--signal", "--steady", "--transition"].contains($0) }
let dark: Float = arguments.contains("--dark") ? 1 : 0
arguments.removeAll { $0 == "--dark" }
var backdrop: SIMD3<Float>?
if let index = arguments.firstIndex(of: "--backdrop"), index + 1 < arguments.count, let hex = UInt32(arguments[index + 1], radix: 16) {
    backdrop = SIMD3(Float(hex >> 16 & 255), Float(hex >> 8 & 255), Float(hex & 255)) / 255
    arguments.removeSubrange(index...(index + 1))
}
guard arguments.count == 2, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("Usage: swift render-orb.swift <FluidOrb.metal> <out.png> [--dark] [--size n] [--seconds s] [--fps f] [--start t]")
}

// The same harness as compare-orb.swift: the stitchable function is called from a compute kernel.
var source = try String(contentsOfFile: arguments[0], encoding: .utf8)
source = source.replacingOccurrences(of: "#include <SwiftUI/SwiftUI_Metal.h>", with: "")
source = source.replacingOccurrences(of: "[[ stitchable ]]", with: "static")
source += """

kernel void renderOrb(device float4 *out [[buffer(0)]],
                      constant float *v [[buffer(1)]],
                      const device float *wave [[buffer(2)]],
                      uint2 p [[thread_position_in_grid]]) {
    float2 size = float2(v[10], v[13]);
    float2 position = float2(p) + 0.5;
    out[p.y * uint(v[10]) + p.x] = float4(fluidOrb(position, half4(1), size,
        v[0], v[1], v[2], v[3], v[4], v[5], float2(v[6], v[7]), v[8], v[9], v[11], v[12], wave, 64));
}
"""
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "renderOrb")!)
let pixels = width * height
let buffer = device.makeBuffer(length: pixels * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
var wave = [Float](repeating: 0, count: 64)

// The canvas reaches beyond the orb's place by `bleed` on every side, as in the app (Theme.swift),
// but a little tighter, so the orb is larger in the picture.
let bleed = requestedBleed >= 0 ? Float(requestedBleed) : (Float(min(width, height)) - Float(min(width, height)) / 2.2) / 2

let url = URL(fileURLWithPath: arguments[1])
let frames = Int(seconds * fps)
guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, frames, nil) else {
    fatalError("Cannot write \(url.path)")
}
CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for frame in 0..<frames {
    let since = Float(Double(frame) / fps)
    let progress = since / Float(seconds)
    func ease(_ x: Float) -> Float { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
    let shape = transition ? ease((progress - 0.12) / 0.22) * (1 - ease((progress - 0.68) / 0.22)) : morph
    if signal {
        for index in wave.indices {
            let x = Float(index) / Float(wave.count - 1)
            let envelope = 0.55 + 0.45 * cos(x * 5.7 - 0.5 + 0.25 * sin(since * 1.7))
            wave[index] = envelope * (0.50 * sin(x * 22 + 0.28 * sin(since * 1.1)) + 0.10 * sin(x * 47 + 0.5))
        }
    }
    // time, morph, level, speakers, active, dark, lean x/y, gather, since, size, bleed, gain
    let peak = wave.reduce(Float.zero) { max($0, abs($1)) }
    var values: [Float] = [Float(start) + since, shape, level, 1, steady ? 1 : min(1, since / 0.8), dark, 0, 0,
                           gather, steady ? 99 : since, Float(width), bleed, 0.12 / max(peak, 0.10), Float(height)]
    let command = queue.makeCommandBuffer()!
    let encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 1)
    encoder.setBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 2)
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { fatalError("GPU render failed: \(String(describing: command.error))") }
    // The shader returns premultiplied colour; PNG keeps premultiplied-last in CoreGraphics' hands.
    let floats = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: pixels)
    var bytes = [UInt8](repeating: 0, count: pixels * 4)
    for i in 0..<pixels {
        let a = min(max(floats[i].w, 0), 1)
        var colour = SIMD3(floats[i].x, floats[i].y, floats[i].z).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: a))
        var alpha = a
        if let backdrop {
            // The orb over the backdrop, inside a rectangle with round corners.
            let x = Float(i % width) + 0.5, y = Float(i / width) + 0.5
            let dx = max(radius - x, x - (Float(width) - radius), 0), dy = max(radius - y, y - (Float(height) - radius), 0)
            let inside = min(max(radius - (dx * dx + dy * dy).squareRoot() + 0.5, 0), 1)
            colour = (backdrop * (1 - a) + colour) * inside
            alpha = inside
        }
        for c in 0..<3 { bytes[i * 4 + c] = UInt8(min(colour[c], 1) * 255 + 0.5) }
        bytes[i * 4 + 3] = UInt8(alpha * 255 + 0.5)
    }
    let image = bytes.withUnsafeMutableBytes { raw -> CGImage in
        let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 1 / fps]] as CFDictionary)
}
guard CGImageDestinationFinalize(destination) else { fatalError("Could not finish \(url.path)") }
print("wrote \(url.path): \(frames) frames, \(width)×\(height)")
