// Compile alongside Listen/Views/OrbMetalSurface.swift to exercise the app's real
// CPU uniform layout against the native fragment and a direct shader reference.
import Foundation
import Metal

@main enum CheckNativeOrb {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Provide FluidOrb.metal on a Metal-capable Mac") }
        var source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        source = source.replacingOccurrences(of: "#include <SwiftUI/SwiftUI_Metal.h>", with: "")
            .replacingOccurrences(of: "[[ stitchable ]]", with: "static")
        source += """
        kernel void orbReference(device float4 *out [[buffer(0)]], constant float *v [[buffer(1)]], const device float *wave [[buffer(2)]], uint2 p [[thread_position_in_grid]]) {
            float2 size = float2(v[10], v[11]);
            out[p.y * 64 + p.x] = float4(forSRGBLayer(fluidOrb((float2(p) + 0.5) / 64.0 * size, half4(1), size,
                v[0], v[1], v[2], v[3], v[4], v[5], float2(v[6], v[7]), v[8], v[9], v[12], v[13], wave, 64), v[5]));
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "listenOrbVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "listenOrbFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let native = try device.makeRenderPipelineState(descriptor: descriptor)
        let reference = try device.makeComputePipelineState(function: library.makeFunction(name: "orbReference")!)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 64, mipmapped: false)
        textureDescriptor.storageMode = .shared; textureDescriptor.usage = .renderTarget
        let texture = device.makeTexture(descriptor: textureDescriptor)!
        let output = device.makeBuffer(length: 64 * 64 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
        var largest: Float = 0, visible = 0
        for scenario in 0..<24 {
            var wave = (0..<64).map { Float(sin(Double($0) * 0.37)) * 0.6 }
            let morph: Float = [0, 0.25, 1][scenario % 3]
            var u = OrbGPUUniforms(canvas: SIMD2(850, scenario % 2 == 0 ? 850 : 550), pixels: SIMD2(64, 64), lean: SIMD2(0.25, -0.5),
                time: Float(scenario) * 2.7, morph: morph, level: 0.6, speakers: 2, active: 1, dark: scenario % 2 == 0 ? 1 : 0,
                gather: scenario % 4 == 0 ? 1 : 0, since: scenario % 3 == 0 ? 0.3 : 99, bleed: 165, gain: 0.2, waveCount: 64)
            var values: [Float] = [u.time, u.morph, u.level, u.speakers, u.active, u.dark, u.lean.x, u.lean.y, u.gather, u.since, u.canvas.x, u.canvas.y, u.bleed, u.gain]
            let command = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let draw = command.makeRenderCommandEncoder(descriptor: pass)!
            draw.setRenderPipelineState(native)
            draw.setFragmentBytes(&u, length: MemoryLayout<OrbGPUUniforms>.stride, index: 0)
            draw.setFragmentBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 1)
            draw.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); draw.endEncoding()
            let compute = command.makeComputeCommandEncoder()!; compute.setComputePipelineState(reference)
            compute.setBuffer(output, offset: 0, index: 0)
            compute.setBytes(&values, length: values.count * MemoryLayout<Float>.stride, index: 1)
            compute.setBytes(&wave, length: wave.count * MemoryLayout<Float>.stride, index: 2)
            compute.dispatchThreads(MTLSize(width: 64, height: 64, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)); compute.endEncoding()
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { fatalError("Native GPU validation failed") }
            var bytes = [UInt16](repeating: 0, count: 64 * 64 * 4)
            texture.getBytes(&bytes, bytesPerRow: 64 * 8, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            let expected = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 64 * 64)
            for pixel in 0..<(64 * 64) { for channel in 0..<4 {
                let difference = abs(Float(Float16(bitPattern: bytes[pixel * 4 + channel])) - expected[pixel][channel])
                guard difference.isFinite else { fatalError("Nonfinite native output") }
                largest = max(largest, difference); if difference > 1.0 / 255 { visible += 1 }
            } }
        }
        print("Native fragment vs reference: 24 scenarios, 98304 pixels, max difference \(largest), channels over 1/255: \(visible)")
        guard visible == 0 else { exit(1) }
    }
}
