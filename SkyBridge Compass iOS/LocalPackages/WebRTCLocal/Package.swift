// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebRTCLocal",
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            path: "../../Vendor/WebRTC/WebRTC.xcframework"
        ),
    ]
)
