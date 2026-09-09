import Foundation
import Metal

enum CloudRenderError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self { case .unavailable(let detail): return "Cloud rendering: \(detail)" }
    }
}

struct CloudUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var quality: Float
    var intensity: Float
    var wind: Float
    var padding: SIMD2<Float> = .zero
}

/// Immutable GPU resources shared by the macOS and iOS presentation adapters.
final class CloudVolumeRenderer {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let density: any MTLTexture

    @concurrent
    static func load() async throws -> sending CloudVolumeRenderer {
        try CloudVolumeRenderer()
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw CloudRenderError.unavailable("Metal device or command queue is unavailable")
        }
        self.device = device
        self.queue = queue
        let bundle = try Self.resourceBundle()
        guard let sourceURL = bundle.url(forResource: "CloudVolume", withExtension: "metal", subdirectory: "Resources"),
              let densityURL = bundle.url(forResource: "cloud_noise_volume", withExtension: "rgba", subdirectory: "Resources") else {
            throw CloudRenderError.unavailable("cloud shader or density atlas is missing from the resource bundle")
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "cloudVertex"),
              let fragment = library.makeFunction(name: "cloudFragment") else {
            throw CloudRenderError.unavailable("cloud shader entry points are missing")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        // This is linear data, not a colour image. Preserve all three density channels.
        let bytes = try Data(contentsOf: densityURL)
        guard bytes.count == 528 * 528 * 4 else {
            throw CloudRenderError.unavailable("density atlas must contain exactly 528 x 528 RGBA8 texels")
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 528, height: 528, mipmapped: false
        )
        #if os(macOS)
        textureDescriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        textureDescriptor.storageMode = .shared
        #endif
        textureDescriptor.usage = .shaderRead
        guard let density = device.makeTexture(descriptor: textureDescriptor) else {
            throw CloudRenderError.unavailable("density texture allocation failed")
        }
        try bytes.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else {
                throw CloudRenderError.unavailable("density atlas data has no storage")
            }
            density.replace(region: MTLRegionMake2D(0, 0, 528, 528), mipmapLevel: 0,
                            withBytes: address, bytesPerRow: 528 * 4)
        }
        self.density = density
    }

    func encode(commandBuffer: any MTLCommandBuffer, pass: MTLRenderPassDescriptor, uniforms: CloudUniforms) throws {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw CloudRenderError.unavailable("render command encoder allocation failed")
        }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(density, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CloudUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private static func resourceBundle() throws -> Bundle {
        // Packaged apps stage SwiftPM resources inside their resource directory. The CLI
        // accessor's build-machine path must never be used as a shipping dependency.
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "SkyBridgeWeatherRendering_SkyBridgeWeatherRendering", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else {
                throw CloudRenderError.unavailable("weather resource bundle is not installed")
            }
            return bundle
        }
        return Bundle.module
    }
}
