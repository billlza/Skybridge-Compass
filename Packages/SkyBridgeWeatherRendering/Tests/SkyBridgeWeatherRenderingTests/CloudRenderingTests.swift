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

    @Test func rainHasDepthWaterAndContinuousMotion() throws {
        let renderer = try AtmosphereRenderer(kind: .rain)
        #expect(renderer.density == nil)
        #expect(MemoryLayout<RainParameters>.stride == 32)
        #expect(MemoryLayout<RainParameters>.offset(of: \.glassOptions) == 16)
        let first = try render(renderer, width: 1000, height: 600)
        let next = try render(renderer, width: 1000, height: 600, time: 12 + 1.0 / 60)
        let later = try render(renderer, width: 1000, height: 600, time: 13)
        #expect(stride(from: 3, to: first.count, by: 4).allSatisfy { first[$0] == 255 })
        let values = luma(first)
        #expect(try #require(values.max()) - #require(values.min()) > 35)
        #expect(average(Array(values.suffix(1000 * 100))) < average(Array(values.prefix(1000 * 300))))
        #expect(difference(luma(first), luma(next)) > 0.01)
        #expect(difference(luma(first), luma(next)) < 4)
        #expect(difference(Array(luma(first).suffix(1000 * 100)), Array(luma(later).suffix(1000 * 100))) > 0.15)
        try save(first, width: 1000, height: 600, name: "rain-wide.png")
        try save(try render(renderer, width: 540, height: 1170), width: 540, height: 1170, name: "rain-portrait.png")
        try save(later, width: 1000, height: 600, name: "rain-wide-later.png")
    }

    @Test func rainBeadsFollowMeasuredGlassAndClearZones() throws {
        let renderer = try AtmosphereRenderer(kind: .rain)
        let region = WeatherGlassRegion(bounds: CGRect(x: 150, y: 160, width: 550, height: 230), cornerRadius: 20)
        let appearance = RainAppearance(size: CGSize(width: 1000, height: 600), regions: [region])
        let dry = try render(renderer, width: 1000, height: 600)
        let wet = try render(renderer, width: 1000, height: 600, rain: appearance)
        let changed = zip(luma(dry), luma(wet)).enumerated().filter { abs($0.element.0 - $0.element.1) > 0.5 }
        #expect(changed.count > 20, "Real glass edges must visibly collect water")
        #expect(changed.allSatisfy { region.bounds.insetBy(dx: -14, dy: -14).contains(CGPoint(x: $0.offset % 1000, y: $0.offset / 1000)) })
        let clearing = RainAppearance(size: CGSize(width: 1000, height: 600), regions: [region],
            zones: [WeatherRainClearZone(center: CGPoint(x: 500, y: 300), radius: 800, strength: 1)])
        let cleared = try render(renderer, width: 1000, height: 600, rain: clearing)
        #expect(difference(luma(wet), luma(cleared)) > 0.01)
        #expect(RainAppearance(size: CGSize(width: 1000, height: 600), regions: Array(repeating: region, count: 30)).parameters.glassCount == 12)
        #expect(RainAppearance(regions: [region]).parameters.glassCount == 0)
        try save(wet, width: 1000, height: 600, name: "rain-glass-edges.png")
    }

    @Test func rainGpuWorkFitsTheSixtyFrameBudgetWithTwelveWetSurfaces() throws {
        let renderer = try AtmosphereRenderer(kind: .rain)
        let regions = (0..<12).map { index in
            WeatherGlassRegion(bounds: CGRect(x: 20 + (index % 4) * 310, y: 30 + (index / 4) * 180,
                                               width: 270, height: 140), cornerRadius: 20)
        }
        let appearance = RainAppearance(size: CGSize(width: 1300, height: 600), storm: true, regions: regions)
        var gpuTimes: [Double] = []
        for frame in 0..<36 {
            _ = try render(renderer, width: 1950, height: 900, time: 12 + Float(frame) / 60, rain: appearance,
                           foregroundSize: CGSize(width: 3900, height: 1800)) {
                if frame >= 4 { gpuTimes.append($0) }
            }
        }
        #expect(gpuTimes.count == 32 && gpuTimes.allSatisfy { $0 > 0 })
        let ordered = gpuTimes.sorted()
        let p95 = ordered[Int(Double(ordered.count - 1) * 0.95)]
        print("Rain GPU: device=\(renderer.device.name), background=1950x900, foreground=3900x1800, surfaces=12, samples=32, medianMs=\(ordered[16] * 1000), p95Ms=\(p95 * 1000)")
        #expect(p95 < 1.0 / 60.0, "The rain pass must fit within the configured 60 Hz frame interval")
    }

    private func render(_ renderer: AtmosphereRenderer, width: Int, height: Int, time: Float = 12,
                        quality: Float = 1, intensity: Float = 0.68, rain: RainAppearance = RainAppearance(),
                        foregroundSize: CGSize? = nil, glassOnly: Bool = false,
                        timing: (Double) -> Void = { _ in }) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, glassOnly ? 0 : 1)
        let command = try #require(renderer.queue.makeCommandBuffer())
        let uniforms = AtmosphereUniforms(resolution: SIMD2(Float(width), Float(height)), time: time,
                                          quality: quality, intensity: intensity, wind: 0.25)
        if glassOnly {
            try renderer.encodeGlass(commandBuffer: command, pass: pass, uniforms: uniforms, rain: rain)
        } else {
            try renderer.encode(commandBuffer: command, pass: pass, uniforms: uniforms, rain: rain,
                                compositeGlass: foregroundSize == nil)
        }
        if let foregroundSize {
            let foregroundDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(foregroundSize.width), height: Int(foregroundSize.height), mipmapped: false)
            foregroundDescriptor.usage = .renderTarget
            foregroundDescriptor.storageMode = .private
            let foreground = try #require(renderer.device.makeTexture(descriptor: foregroundDescriptor))
            let foregroundPass = MTLRenderPassDescriptor()
            foregroundPass.colorAttachments[0].texture = foreground
            foregroundPass.colorAttachments[0].loadAction = .clear
            foregroundPass.colorAttachments[0].storeAction = .store
            var foregroundUniforms = uniforms
            foregroundUniforms.resolution = SIMD2(Float(foreground.width), Float(foreground.height))
            try renderer.encodeGlass(commandBuffer: command, pass: foregroundPass, uniforms: foregroundUniforms, rain: rain)
        }
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)
        timing(command.gpuEndTime - command.gpuStartTime)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&data, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return data
    }

    @Test func wetForegroundPreservesTransparencyClippingAndDispersal() throws {
        let renderer = try AtmosphereRenderer(kind: .rain)
        let clip = CGRect(x: 100, y: 120, width: 700, height: 300)
        let region = WeatherGlassRegion(bounds: CGRect(x: 150, y: 80, width: 550, height: 230),
                                         cornerRadius: 20, clipBounds: clip)
        let size = CGSize(width: 1000, height: 600)
        let wet = try render(renderer, width: 1000, height: 600,
                             rain: RainAppearance(size: size, regions: [region]), glassOnly: true)
        let visible = (0..<600000).filter { wet[$0 * 4 + 3] > 0 }
        #expect(visible.count > 20)
        #expect(visible.allSatisfy { clip.contains(CGPoint(x: $0 % 1000, y: $0 / 1000)) })
        #expect(visible.allSatisfy { !region.bounds.insetBy(dx: 14, dy: 14).contains(CGPoint(x: $0 % 1000, y: $0 / 1000)) })
        #expect((0..<600000).allSatisfy { index in
            let offset = index * 4
            return wet[offset] <= wet[offset + 3] && wet[offset + 1] <= wet[offset + 3] && wet[offset + 2] <= wet[offset + 3]
        }, "Transparent foreground must contain premultiplied colors")
        let cleared = try render(renderer, width: 1000, height: 600,
            rain: RainAppearance(size: size, regions: [region], glassOpacity: 0), glassOnly: true)
        #expect(cleared.allSatisfy { $0 == 0 }, "Full mouse dispersal must clear foreground water too")
        let empty = try render(renderer, width: 1000, height: 600, glassOnly: true)
        #expect(empty.allSatisfy { $0 == 0 }, "Removing glass must clear previously displayed water")
        try save(wet, width: 1000, height: 600, name: "rain-foreground-clipped.png")
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
