import Foundation
import CoreGraphics
import ImageIO
import Metal
import Testing
@testable import SkyBridgeWeatherRendering

@Suite(.serialized)
struct CloudRenderingTests {
    @Test func boundedResolutionPreservesAspectAtEveryQuality() {
        for size in [CGSize(width: 1440, height: 3120), CGSize(width: 3840, height: 2160), CGSize(width: 320, height: 240)] {
            for quality: Float in [0, 0.45, 1] {
                let result = AtmosphereRenderPolicy.drawableSize(for: size, quality: quality)
                let multiplier: CGFloat = quality > 0.65 ? 1 : 0.75
                #expect(min(result.width, result.height) <= 600 * multiplier)
                #expect(max(result.width, result.height) <= 1300 * multiplier)
                #expect(abs(result.width / result.height - size.width / size.height) < 0.01)
                #expect(result.width <= size.width && result.height <= size.height)
            }
        }
        #expect(AtmosphereRenderPolicy.drawableSize(for: .zero, quality: 1) == .zero)
        #expect(AtmosphereRenderPolicy.drawableSize(for: CGSize(width: CGFloat.infinity, height: 10), quality: 1) == .zero)
    }

    @Test func clockDoesNotJumpAfterPauseOrLongDeviceUptime() {
        var clock = AtmosphereAnimationClock()
        #expect(clock.sample(at: 9_000_000, animating: true) == 0)
        #expect(abs(clock.sample(at: 9_000_000 + 1.0 / 30, animating: true) - 1.0 / 30) < 0.00001)
        clock.pause()
        let paused = clock.elapsed
        #expect(abs(Double(clock.sample(at: 10_000_000, animating: true)) - paused) < 0.00001)
        #expect(abs(Double(clock.sample(at: 20_000_000, animating: true)) - paused - 0.1) < 0.00001)
    }

    @Test func nativeCloudFramesAreOpaqueShadedAndReadable() throws {
        let renderer = try AtmosphereRenderer()
        #expect(MemoryLayout<AtmosphereUniforms>.stride == 32)
        for quality: Float in [0, 0.45, 1] {
            let frame = try render(renderer, width: 540, height: 1170, quality: quality)
            #expect(stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 255 })
            let luminance = luma(frame)
            let upper = luminance.prefix(luminance.count / 3)
            #expect(try #require(upper.max()) - #require(upper.min()) > 25)
            #expect(average(Array(luminance.suffix(luminance.count / 5))) < 60)
            #expect(upper.filter { $0 > 245 }.count < upper.count / 100)
            try save(frame, width: 540, height: 1170, name: "clouds-quality-\(quality).png")
        }
    }

    @Test func windIsContinuousAndWideProjectionPreservesCloudShape() throws {
        let renderer = try AtmosphereRenderer()
        let a = try render(renderer, width: 360, height: 780)
        let b = try render(renderer, width: 360, height: 780, time: 12 + 1.0 / 30)
        let c = try render(renderer, width: 360, height: 780, time: 24)
        let adjacent = difference(luma(a), luma(b))
        let drift = difference(luma(a), luma(c))
        #expect(adjacent < 2)
        #expect(drift > 0.5)
        #expect(adjacent < drift)
        try save(c, width: 360, height: 780, name: "clouds-after-12-seconds.png")

        let portrait = try render(renderer, width: 270, height: 585)
        let wide = try render(renderer, width: 780, height: 585)
        let wideLuma = luma(wide)
        let crop = (0..<585).flatMap { Array(wideLuma[($0 * 780 + 255)..<($0 * 780 + 525)]) }
        #expect(difference(luma(portrait), crop) < 8)
        try save(wide, width: 780, height: 585, name: "clouds-wide.png")
    }

    @Test func hazeHasAFilteredSunDepthAndAReadableForeground() throws {
        let renderer = try AtmosphereRenderer(kind: .haze)
        #expect(renderer.density == nil)
        #expect(MemoryLayout<HazeAppearance>.stride == 32)
        #expect(MemoryLayout<HazeAppearance>.offset(of: \.grain) == 16)
        for quality: Float in [0, 0.45, 1] {
            let frame = try render(renderer, width: 540, height: 1170, quality: quality)
            #expect(stride(from: 3, to: frame.count, by: 4).allSatisfy { frame[$0] == 255 })
            let luminance = luma(frame)
            let upper = Array(luminance.prefix(luminance.count / 2))
            let foreground = Array(luminance.suffix(luminance.count / 5))
            #expect(try #require(upper.max()) - #require(upper.min()) > 30)
            #expect(average(upper) > average(foreground) + 25)
            #expect(average(foreground) < 75)
            #expect(upper.filter { $0 > 245 }.count < upper.count / 100)
            try save(frame, width: 540, height: 1170, name: "haze-quality-\(quality).png")
        }
    }

    @Test func hazeDriftsContinuouslyAndRespondsToDensity() throws {
        let renderer = try AtmosphereRenderer(kind: .haze)
        let first = try render(renderer, width: 360, height: 780)
        let adjacent = try render(renderer, width: 360, height: 780, time: 12 + 1.0 / 30)
        let later = try render(renderer, width: 360, height: 780, time: 24)
        let step = difference(luma(first), luma(adjacent))
        let drift = difference(luma(first), luma(later))
        #expect(step < 1)
        #expect(drift > 0.08 && drift > step)
        let thin = try render(renderer, width: 360, height: 780, intensity: 0.2)
        let dense = try render(renderer, width: 360, height: 780, intensity: 0.95)
        #expect(difference(luma(thin), luma(dense)) > 2)
        try save(thin, width: 360, height: 780, name: "haze-thin.png")
        try save(dense, width: 360, height: 780, name: "haze-dense.png")
        try save(later, width: 360, height: 780, name: "haze-after-12-seconds.png")
    }

    @Test func hazeProjectionAndQualityPreserveTheAtmosphere() throws {
        let renderer = try AtmosphereRenderer(kind: .haze)
        let portrait = try render(renderer, width: 270, height: 585)
        let wide = try render(renderer, width: 780, height: 585)
        let wideLuma = luma(wide)
        let crop = (0..<585).flatMap { Array(wideLuma[($0 * 780 + 255)..<($0 * 780 + 525)]) }
        #expect(difference(luma(portrait), crop) < 2)
        let reduced = try render(renderer, width: 270, height: 585, quality: 0.45)
        #expect(difference(luma(portrait), luma(reduced)) < 4)
        try save(wide, width: 780, height: 585, name: "haze-wide.png")
    }

    private func render(_ renderer: AtmosphereRenderer, width: Int, height: Int, time: Float = 12,
                        quality: Float = 1, intensity: Float = 0.68) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try #require(renderer.queue.makeCommandBuffer())
        try renderer.encode(commandBuffer: command, pass: pass,
                            uniforms: AtmosphereUniforms(resolution: SIMD2(Float(width), Float(height)), time: time,
                                                    quality: quality, intensity: intensity, wind: 0.25))
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return data
    }

    private func luma(_ bytes: [UInt8]) -> [Double] {
        stride(from: 0, to: bytes.count, by: 4).map { index in
            let blue = Double(bytes[index]) * 19.0
            let green = Double(bytes[index + 1]) * 183.0
            let red = Double(bytes[index + 2]) * 54.0
            return (blue + green + red) / 256.0
        }
    }
    private func average(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
    private func difference(_ a: [Double], _ b: [Double]) -> Double { average(zip(a, b).map { abs($0 - $1) }) }

    private func save(_ bytes: [UInt8], width: Int, height: Int, name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skybridge-cloud-render-verification")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data(bytes)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: space,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
