import Foundation
import Metal

enum AtmosphereRenderError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self { case .unavailable(let detail): return "Atmosphere rendering: \(detail)" }
    }
}

struct AtmosphereUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var quality: Float
    var intensity: Float
    var wind: Float
    var padding: SIMD2<Float> = .zero
}

enum AtmosphereKind: CaseIterable, Sendable {
    case clouds, haze, rain

    var resource: String {
        switch self { case .clouds: "CloudVolume"; case .haze: "HazeVolume"; case .rain: "RainVolume" }
    }
    var entryPrefix: String {
        switch self { case .clouds: "cloud"; case .haze: "haze"; case .rain: "rain" }
    }
}

struct HazeAppearance: Equatable {
    var tint = SIMD3<Float>(0.78, 0.72, 0.58)
    var grain: Float = 1
}

/// Immutable GPU resources shared by the macOS and iOS presentation adapters.
final class AtmosphereRenderer {
    let kind: AtmosphereKind
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    let glassPipeline: (any MTLRenderPipelineState)?
    let density: (any MTLTexture)?

    @concurrent
    static func load(kind: AtmosphereKind) async throws -> sending AtmosphereRenderer {
        try AtmosphereRenderer(kind: kind)
    }

    init(kind: AtmosphereKind = .clouds) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw AtmosphereRenderError.unavailable("Metal device or command queue is unavailable")
        }
        self.device = device
        self.queue = queue
        self.kind = kind
        let bundle = try Self.resourceBundle()
        guard let sourceURL = bundle.url(forResource: kind.resource, withExtension: "metal", subdirectory: "Resources") else {
            throw AtmosphereRenderError.unavailable("\(kind.resource) shader is missing from the resource bundle")
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: kind.entryPrefix + "Vertex"),
              let fragment = library.makeFunction(name: kind.entryPrefix + "Fragment") else {
            throw AtmosphereRenderError.unavailable("\(kind.resource) shader entry points are missing")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        if kind == .rain {
            guard let glassVertex = library.makeFunction(name: "rainGlassVertex"),
                  let glassFragment = library.makeFunction(name: "rainGlassFragment") else {
                throw AtmosphereRenderError.unavailable("rain glass shader entry points are missing")
            }
            descriptor.vertexFunction = glassVertex
            descriptor.fragmentFunction = glassFragment
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            glassPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } else {
            glassPipeline = nil
        }
        density = kind == .clouds ? try Self.loadDensity(device: device, bundle: bundle) : nil
    }

    private static func loadDensity(device: any MTLDevice, bundle: Bundle) throws -> any MTLTexture {
        guard let densityURL = bundle.url(forResource: "cloud_noise_volume", withExtension: "rgba", subdirectory: "Resources") else {
            throw AtmosphereRenderError.unavailable("cloud density atlas is missing from the resource bundle")
        }
        // This is linear data, not a colour image. Preserve all three density channels.
        let bytes = try Data(contentsOf: densityURL)
        guard bytes.count == 528 * 528 * 4 else {
            throw AtmosphereRenderError.unavailable("density atlas must contain exactly 528 x 528 RGBA8 texels")
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
            throw AtmosphereRenderError.unavailable("density texture allocation failed")
        }
        try bytes.withUnsafeBytes { raw in
            guard let address = raw.baseAddress else {
                throw AtmosphereRenderError.unavailable("density atlas data has no storage")
            }
            density.replace(region: MTLRegionMake2D(0, 0, 528, 528), mipmapLevel: 0,
                            withBytes: address, bytesPerRow: 528 * 4)
        }
        return density
    }

    func encode(commandBuffer: any MTLCommandBuffer, pass: MTLRenderPassDescriptor, uniforms: AtmosphereUniforms,
                appearance: HazeAppearance = HazeAppearance(), rain: RainAppearance = RainAppearance(),
                compositeGlass: Bool = true) throws {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw AtmosphereRenderError.unavailable("render command encoder allocation failed")
        }
        defer { encoder.endEncoding() }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        if let density { encoder.setFragmentTexture(density, index: 0) }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
        if kind == .haze {
            var appearance = appearance
            encoder.setFragmentBytes(&appearance, length: MemoryLayout<HazeAppearance>.stride, index: 1)
        }
        if kind == .rain {
            try bindRain(rain, to: encoder)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if kind == .rain, compositeGlass { try encodeGlass(encoder: encoder, uniforms: uniforms, rain: rain) }
    }

    /// Transparent foreground, encoded on the background's command buffer and clock.
    func encodeGlass(commandBuffer: any MTLCommandBuffer, pass: MTLRenderPassDescriptor,
                     uniforms: AtmosphereUniforms, rain: RainAppearance) throws {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw AtmosphereRenderError.unavailable("glass command encoder allocation failed")
        }
        defer { encoder.endEncoding() }
        try encodeGlass(encoder: encoder, uniforms: uniforms, rain: rain)
    }

    private func bindRain(_ rain: RainAppearance, to encoder: any MTLRenderCommandEncoder) throws {
        var parameters = rain.parameters
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<RainParameters>.stride, index: 1)
        try rain.glass.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else {
                throw AtmosphereRenderError.unavailable("rain glass constants have no storage")
            }
            encoder.setFragmentBytes(address, length: bytes.count, index: 2)
            encoder.setVertexBytes(address, length: bytes.count, index: 2)
        }
        try rain.clearZones.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else {
                throw AtmosphereRenderError.unavailable("rain interaction constants have no storage")
            }
            encoder.setFragmentBytes(address, length: bytes.count, index: 3)
        }
    }

    private func encodeGlass(encoder: any MTLRenderCommandEncoder, uniforms: AtmosphereUniforms,
                             rain: RainAppearance) throws {
        guard let glassPipeline else { throw AtmosphereRenderError.unavailable("rain glass pipeline is unavailable") }
        var uniforms = uniforms
        encoder.setRenderPipelineState(glassPipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 0)
        try bindRain(rain, to: encoder)
        for (index, clip) in rain.clips.enumerated() {
            let width = Int(uniforms.resolution.x), height = Int(uniforms.resolution.y)
            let x = max(0, min(width, Int(floor(clip.minX * Double(width)))))
            let y = max(0, min(height, Int(floor(clip.minY * Double(height)))))
            let right = max(x, min(width, Int(ceil(clip.maxX * Double(width)))))
            let bottom = max(y, min(height, Int(ceil(clip.maxY * Double(height)))))
            guard right > x, bottom > y else { continue }
            encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: right - x, height: bottom - y))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                                   instanceCount: 4, baseInstance: index * 4)
        }
    }

    private static func resourceBundle() throws -> Bundle {
        // Packaged apps stage SwiftPM resources inside their resource directory. The CLI
        // accessor's build-machine path must never be used as a shipping dependency.
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "SkyBridgeWeatherRendering_SkyBridgeWeatherRendering", withExtension: "bundle"),
                  let bundle = Bundle(url: url) else {
                throw AtmosphereRenderError.unavailable("weather resource bundle is not installed")
            }
            return bundle
        }
        return Bundle.module
    }
}
