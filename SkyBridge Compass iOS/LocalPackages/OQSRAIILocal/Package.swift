// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OQSRAIILocal",
    products: [
        .library(name: "OQSRAII", targets: ["OQSRAII"])
    ],
    targets: [
        .binaryTarget(
            name: "liboqs",
            path: "../../Vendor/liboqs.xcframework"
        ),
        .target(
            name: "OQSRAII",
            dependencies: ["liboqs"],
            path: "Sources/OQSRAII",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++20"])
            ]
        )
    ]
)
