import XCTest
@testable import SkyBridgeCore

final class DeviceClassifierCameraTests: XCTestCase {
    func testRTSPServiceClassifiesCameraWithoutAuthorizingGenericConnection() {
        let device = DiscoveredDevice(
            id: UUID(),
            name: "Living Room",
            ipv4: "192.168.1.20",
            ipv6: nil,
            services: ["_rtsp._tcp"],
            portMap: ["_rtsp._tcp": 554]
        )

        let classification = DeviceClassifier.classifyDevice(device)

        XCTAssertEqual(classification, .camera)
        XCTAssertFalse(classification.isConnectable)
    }

    func testOrdinaryHTTPServiceIsNotMisclassifiedAsCamera() {
        let device = DiscoveredDevice(
            id: UUID(),
            name: "Status Dashboard",
            ipv4: "192.168.1.21",
            ipv6: nil,
            services: ["_http._tcp"],
            portMap: ["_http._tcp": 8081]
        )

        XCTAssertNotEqual(DeviceClassifier.classifyDevice(device), .camera)
    }

    func testONVIFCapabilityIdentifiesCameraWithoutGuessingHTTP() {
        let device = DiscoveredDevice(
            id: UUID(),
            name: "Entrance",
            ipv4: "192.168.1.22",
            ipv6: nil,
            services: ["onvif-NetworkVideoTransmitter"],
            portMap: [:]
        )

        XCTAssertEqual(DeviceClassifier.classifyDevice(device), .camera)
    }

    func testCameraSessionSummaryIsExplicitlyReadOnly() {
        let summary = RemoteSessionSummary(
            id: UUID(),
            targetName: "Entrance",
            protocolDescription: "RTSP / H.264",
            kind: .readOnlyCamera,
            bandwidthMbps: 2.5,
            frameLatencyMilliseconds: 18,
            status: .connected
        )

        XCTAssertFalse(summary.kind.supportsRemoteInput)
    }
}
