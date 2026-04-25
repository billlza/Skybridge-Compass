// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "WebRTCLocal",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "WebRTC", targets: ["WebRTC"]),
    ],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/147.0.0/WebRTC-M147.xcframework.zip",
            checksum: "49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40"
        ),
    ]
)
