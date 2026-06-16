import Foundation
import Metal

public enum SkyBridgeMetalShaderLibraryError: LocalizedError {
    case libraryUnavailable(requiredFunctions: [String], attemptedLocations: [String])

    public var errorDescription: String? {
        switch self {
        case .libraryUnavailable(let requiredFunctions, let attemptedLocations):
            let functionList = requiredFunctions.isEmpty ? "none" : requiredFunctions.joined(separator: ", ")
            let attempted = attemptedLocations.isEmpty ? "none" : attemptedLocations.joined(separator: "; ")
            return "Metal shader library unavailable. Required functions: \(functionList). Attempted: \(attempted)."
        }
    }
}

public enum SkyBridgeMetalShaderLibrary {
    internal static var coreResourceBundle: Bundle {
        Bundle.module
    }

    public static let coreShaderResourceNames = [
        "RemoteDesktopShaders",
        "RemoteDesktopPassthrough",
        "RemoteDesktopHDR",
        "Metal4Shaders",
        "AuroraShaders",
        "WeatherParticleShaders",
        "WeatherShaders",
        "RainShaders",
        "HazeShaders",
        "HazeParticleShaders"
    ]

    public static func loadIfAvailable(
        device: MTLDevice,
        bundle: Bundle,
        sourceResourceNames: [String],
        requiredFunctionNames: [String]
    ) -> MTLLibrary? {
        try? load(
            device: device,
            bundle: bundle,
            sourceResourceNames: sourceResourceNames,
            requiredFunctionNames: requiredFunctionNames
        )
    }

    public static func load(
        device: MTLDevice,
        bundle: Bundle,
        sourceResourceNames: [String],
        requiredFunctionNames: [String]
    ) throws -> MTLLibrary {
        var attemptedLocations: [String] = []

        if let library = device.makeDefaultLibrary() {
            if library.containsAllFunctions(requiredFunctionNames) {
                return library
            }
            attemptedLocations.append("default library missing required functions")
        } else {
            attemptedLocations.append("default library unavailable")
        }

        do {
            let library = try device.makeDefaultLibrary(bundle: bundle)
            if library.containsAllFunctions(requiredFunctionNames) {
                return library
            }
            attemptedLocations.append("bundle default library missing required functions")
        } catch {
            attemptedLocations.append("bundle default library unavailable: \(error.localizedDescription)")
        }

        for resourceName in sourceResourceNames {
            if let library = try loadPrecompiledLibraryIfPresent(
                device: device,
                bundle: bundle,
                resourceName: resourceName,
                requiredFunctionNames: requiredFunctionNames,
                attemptedLocations: &attemptedLocations
            ) {
                return library
            }

            if let library = try loadSourceLibraryIfPresent(
                device: device,
                bundle: bundle,
                resourceName: resourceName,
                requiredFunctionNames: requiredFunctionNames,
                attemptedLocations: &attemptedLocations
            ) {
                return library
            }
        }

        throw SkyBridgeMetalShaderLibraryError.libraryUnavailable(
            requiredFunctions: requiredFunctionNames,
            attemptedLocations: attemptedLocations
        )
    }

    private static func loadPrecompiledLibraryIfPresent(
        device: MTLDevice,
        bundle: Bundle,
        resourceName: String,
        requiredFunctionNames: [String],
        attemptedLocations: inout [String]
    ) throws -> MTLLibrary? {
        guard let url = resourceURL(in: bundle, resourceName: resourceName, extension: "metallib") else {
            attemptedLocations.append("\(resourceName).metallib not found")
            return nil
        }

        do {
            let library = try device.makeLibrary(URL: url)
            if library.containsAllFunctions(requiredFunctionNames) {
                return library
            }
            attemptedLocations.append("\(resourceName).metallib missing required functions")
            return nil
        } catch {
            attemptedLocations.append("\(resourceName).metallib failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadSourceLibraryIfPresent(
        device: MTLDevice,
        bundle: Bundle,
        resourceName: String,
        requiredFunctionNames: [String],
        attemptedLocations: inout [String]
    ) throws -> MTLLibrary? {
        guard let url = resourceURL(in: bundle, resourceName: resourceName, extension: "metal") else {
            attemptedLocations.append("\(resourceName).metal not found")
            return nil
        }

        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let library = try device.makeLibrary(source: source, options: nil)
            if library.containsAllFunctions(requiredFunctionNames) {
                return library
            }
            attemptedLocations.append("\(resourceName).metal missing required functions")
            return nil
        } catch {
            attemptedLocations.append("\(resourceName).metal failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func resourceURL(in bundle: Bundle, resourceName: String, extension pathExtension: String) -> URL? {
        if let url = bundle.url(forResource: resourceName, withExtension: pathExtension) {
            return url
        }

        guard let resourceURL = bundle.resourceURL,
              let enumerator = FileManager.default.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: nil
              ) else {
            return nil
        }

        let expectedFileName = "\(resourceName).\(pathExtension)"
        for case let url as URL in enumerator where url.lastPathComponent == expectedFileName {
            return url
        }

        return nil
    }
}

private extension MTLLibrary {
    func containsAllFunctions(_ functionNames: [String]) -> Bool {
        functionNames.allSatisfy { makeFunction(name: $0) != nil }
    }
}
