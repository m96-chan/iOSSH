// Run on a Mac with a Metal device: swift Packages/TerminalRender/Scripts/validate-metal.swift
// Compiles the shipped shaders and verifies instancing and linear-light alpha blending.
import Foundation
import Metal

struct Instance {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var color: SIMD4<Float>
}

enum ValidationError: Error { case unavailable(String), incorrectPixel([UInt8]) }

let shaderURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/TerminalRender/Shaders/Terminal.metal")
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    throw ValidationError.unavailable("A Metal device is required")
}
let library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: nil)
var pipelines: [String: any MTLRenderPipelineState] = [:]
for fragment in ["terminalSolid", "terminalGlyph", "terminalImage"] {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "terminalVertex")
    descriptor.fragmentFunction = library.makeFunction(name: fragment)
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    pipelines[fragment] = try device.makeRenderPipelineState(descriptor: descriptor)
}
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 32, height: 16, mipmapped: false)
descriptor.storageMode = .shared
descriptor.usage = [.renderTarget]
guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
    throw ValidationError.unavailable("Cannot create render resources")
}
let pass = MTLRenderPassDescriptor()
pass.colorAttachments[0].texture = texture
pass.colorAttachments[0].loadAction = .clear
pass.colorAttachments[0].storeAction = .store
pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
    throw ValidationError.unavailable("Cannot create render encoder")
}
let instances = [
    Instance(rect: SIMD4(0, 0, 16, 16), uv: .zero, color: SIMD4(1, 0, 0, 1)),
    Instance(rect: SIMD4(16, 0, 16, 16), uv: .zero, color: SIMD4(0, 0, 1, 1)),
    Instance(rect: SIMD4(0, 0, 16, 16), uv: .zero, color: SIMD4(0, 0.5, 0, 0.5))
]
var viewport = SIMD2<Float>(32, 16)
encoder.setRenderPipelineState(pipelines["terminalSolid"]!)
encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
instances.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
if let error = command.error { throw error }
var pixels = [UInt8](repeating: 0, count: 32 * 16 * 4)
pixels.withUnsafeMutableBytes {
    texture.getBytes($0.baseAddress!, bytesPerRow: 32 * 4, from: MTLRegionMake2D(0, 0, 32, 16), mipmapLevel: 0)
}
let left = Array(pixels[(8 * 32 + 8) * 4..<(8 * 32 + 8) * 4 + 4])
let right = Array(pixels[(8 * 32 + 24) * 4..<(8 * 32 + 24) * 4 + 4])
guard left[0] == 0, abs(Int(left[1]) - 188) <= 1, abs(Int(left[2]) - 188) <= 1, left[3] == 255 else {
    throw ValidationError.incorrectPixel(left)
}
guard right == [255, 0, 0, 255] else { throw ValidationError.incorrectPixel(right) }
print("PASS: three shader pipelines, instanced rectangles, and sRGB linear alpha blending")
