import XCTest

@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
@MainActor
final class RemoteDesktopTransportSelectionPolicyTests: XCTestCase {
    func testDirectLANIntentNeverReusesMatchingCrossNetworkIdentity() {
        let lanDevice = device(
            id: "peer-device",
            services: [DiscoveredDevice.remoteControlServiceType]
        )

        let decision = RemoteDesktopTransportSelectionPolicy.decision(
            for: lanDevice,
            routeIntent: .directLAN,
            crossNetworkState: .connected(sessionId: "session-a"),
            remoteDeviceIDs: [lanDevice.id]
        )

        XCTAssertEqual(decision, .directLAN)
    }

    func testCrossNetworkIntentRequiresCurrentMatchingSessionTarget() {
        let crossNetworkDevice = device(
            id: "webrtc-session-a",
            capabilities: [RemoteDesktopManager.crossNetworkDeviceCapability]
        )

        XCTAssertEqual(
            RemoteDesktopTransportSelectionPolicy.decision(
                for: crossNetworkDevice,
                routeIntent: .crossNetwork(sessionID: "session-a"),
                crossNetworkState: .connected(sessionId: "session-a"),
                remoteDeviceIDs: ["peer-device"]
            ),
            .crossNetwork(sessionID: "session-a")
        )
        XCTAssertEqual(
            RemoteDesktopTransportSelectionPolicy.decision(
                for: crossNetworkDevice,
                routeIntent: .crossNetwork(sessionID: "session-a"),
                crossNetworkState: .idle,
                remoteDeviceIDs: ["peer-device"]
            ),
            .rejectUnavailableCrossNetworkTarget
        )
    }

    func testCrossNetworkIntentRejectsReplacementSessionForSameRemoteIdentity() {
        let remoteDevice = device(id: "peer-device")

        XCTAssertEqual(
            RemoteDesktopTransportSelectionPolicy.decision(
                for: remoteDevice,
                routeIntent: .crossNetwork(sessionID: "session-a"),
                crossNetworkState: .connected(sessionId: "session-b"),
                remoteDeviceIDs: [remoteDevice.id]
            ),
            .rejectUnavailableCrossNetworkTarget
        )
    }

    func testCrossNetworkIntentRejectsDifferentTargetInCurrentSession() {
        let staleDevice = device(id: "peer-a")

        XCTAssertEqual(
            RemoteDesktopTransportSelectionPolicy.decision(
                for: staleDevice,
                routeIntent: .crossNetwork(sessionID: "session-a"),
                crossNetworkState: .connected(sessionId: "session-a"),
                remoteDeviceIDs: ["peer-b"]
            ),
            .rejectUnavailableCrossNetworkTarget
        )
    }

    private func device(
        id: String,
        services: [String] = [],
        capabilities: [String] = []
    ) -> DiscoveredDevice {
        DiscoveredDevice(
            id: id,
            name: "Peer Mac",
            modelName: "Mac",
            platform: .macOS,
            osVersion: "",
            services: services,
            advertisedCapabilities: capabilities,
            capabilities: capabilities
        )
    }
}
