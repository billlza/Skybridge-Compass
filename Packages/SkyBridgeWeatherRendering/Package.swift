// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SkyBridgeWeatherRendering",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "SkyBridgeWeatherRendering", targets: ["SkyBridgeWeatherRendering"])],
    targets: [
        .target(name: "SkyBridgeWeatherRendering", resources: [.copy("Resources")]),
        .testTarget(name: "SkyBridgeWeatherRenderingTests", dependencies: ["SkyBridgeWeatherRendering"])
    ]
)
