import Metal
import XCTest
@testable import SkyBridgeCore

final class MetalShaderSourceCompileContractTests: XCTestCase {
    private struct ShaderContract {
        let relativePath: String
        let requiredFunctions: [String]
    }

    private let shaderContracts: [ShaderContract] = [
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/RemoteDesktop/RemoteDesktopShaders.metal",
            requiredFunctions: ["scaleFrame", "convertColorSpace", "sharpenImage"]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/RemoteDesktop/Shaders/RemoteDesktopPassthrough.metal",
            requiredFunctions: ["fluidPassthroughVertex", "fluidPassthroughFragment"]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/RemoteDesktop/Shaders/RemoteDesktopHDR.metal",
            requiredFunctions: ["referenceHDRVertex", "referenceHDRFragment"]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/Rendering/Metal4Shaders.metal",
            requiredFunctions: [
                "vertex_main",
                "fragment_main",
                "compute_main",
                "ai_inference_shader",
                "neural_upscale_compute",
                "frame_interpolation_compute"
            ]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/Rendering/AuroraShaders.metal",
            requiredFunctions: ["auroraVertex", "auroraFragment"]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/Shaders/WeatherParticleShaders.metal",
            requiredFunctions: [
                "weather_particle_update",
                "weather_particle_vertex",
                "weather_particle_fragment"
            ]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/Rendering/WeatherShaders.metal",
            requiredFunctions: [
                "particle_update_compute",
                "particle_vertex",
                "particle_fragment",
                "ray_tracing_compute"
            ]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/Weather/RainShaders.metal",
            requiredFunctions: [
                "updateRainParticles",
                "updateWaterDrops",
                "rainVertexShader",
                "rainFragmentShader"
            ]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/Weather/HazeShaders.metal",
            requiredFunctions: ["hazeVertex", "hazeFragment"]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCore/Weather/HazeParticleShaders.metal",
            requiredFunctions: [
                "updateHazeParticles",
                "hazeParticleVertex",
                "hazeParticleFragment"
            ]
        ),
        ShaderContract(
            relativePath: "Sources/SkyBridgeCompassApp/GlobalHazeShaders.metal",
            requiredFunctions: [
                "globalHazeVertexShader",
                "globalHazeFragmentShader"
            ]
        )
    ]

    func testCopiedMetalShaderSourcesCompileAndExposeRequiredFunctions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable on this host.")
        }

        for contract in shaderContracts {
            let url = repositoryRoot().appendingPathComponent(contract.relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: source, options: nil)
            } catch {
                XCTFail("Expected \(contract.relativePath) to compile from copied source: \(error.localizedDescription)")
                continue
            }

            for functionName in contract.requiredFunctions {
                XCTAssertNotNil(
                    library.makeFunction(name: functionName),
                    "Expected \(contract.relativePath) to expose \(functionName) when compiled from copied source."
                )
            }
        }
    }

    func testSwiftPMMetalShaderBundleLoadsThroughRuntimeLibraryResolver() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable on this host.")
        }

        for contract in shaderContracts where contract.relativePath.hasPrefix("Sources/SkyBridgeCore/") {
            let resourceName = URL(fileURLWithPath: contract.relativePath)
                .deletingPathExtension()
                .lastPathComponent
            XCTAssertNoThrow(
                try SkyBridgeMetalShaderLibrary.load(
                    device: device,
                    bundle: SkyBridgeMetalShaderLibrary.coreResourceBundle,
                    sourceResourceNames: [resourceName],
                    requiredFunctionNames: contract.requiredFunctions
                ),
                "Expected \(contract.relativePath) to load through Bundle.module and SkyBridgeMetalShaderLibrary."
            )
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
