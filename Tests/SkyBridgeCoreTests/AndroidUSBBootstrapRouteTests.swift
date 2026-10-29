#if os(macOS)
import Foundation
import Network
import XCTest
import SkyBridgeAppleTransport
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class AndroidUSBBootstrapRouteTests: XCTestCase {
    private func idleRoute() throws -> (USBHostMultiplexConnection, USBHostBootstrapChannel) {
        // Never start or acquire an OS device. These tests exercise Core route
        // admission and actual owner's shutdown, not native USB availability.
        let physical = try USBHostMultiplexConnection(deviceRegistryID: .max, requireAttachmentCurrent: {})
        return (physical, try USBHostBootstrapChannel(connection: physical, attachmentNonce: UUID(), requireAttachmentCurrent: {}))
    }
    func testNativeRouteRejectsMixedNetworkCandidatesBeforeAcquisition() async throws {
        let (physical, channel) = try idleRoute()
        let service = P2PDiscoveryService()
        do {
            _ = try await service.exchangeBootstrapControlMessage(.ping(.init(id: 1)),
                endpoints: [.hostPort(host: "192.0.2.1", port: 9527)], timeoutSeconds: 1,
                targetHasStrongAuthority: false, usbRoute: .android(channel))
            XCTFail("Native USB accepted a network candidate")
        } catch let error as P2PDiscoveryError {
            guard case .noConnectableEndpoint = error else { XCTFail("Wrong route failure: \(error)"); throw error }
        }
        try await physical.closeAndAwait()
        XCTAssertTrue(physical.shutdownState.referencesReleased)
    }
    func testRetiredNativeRoutePreservesFailureInsteadOfTryingAnotherCarrier() async throws {
        let (physical, channel) = try idleRoute()
        try await physical.closeAndAwait()
        let service = P2PDiscoveryService()
        do {
            _ = try await service.exchangeBootstrapControlMessage(.ping(.init(id: 1)),
                endpoints: [], timeoutSeconds: 1, targetHasStrongAuthority: false, usbRoute: .android(channel))
            XCTFail("Retired route produced a bootstrap response")
        } catch let error as USBHostMultiplexError { XCTAssertEqual(error, .closed) }
        XCTAssertFalse(channel.cleanupRequired)
        XCTAssertTrue(physical.shutdownState.referencesReleased)
    }
    func testUSBRouteDigestSeparatesAttachmentAndPeerWhilePreservingAppleContract() async throws {
        let (physical, channel) = try idleRoute()
        let second = try USBHostBootstrapChannel(connection: physical, attachmentNonce: UUID(), requireAttachmentCurrent: {})
        let a = P2PUSBControlRoute.android(channel), b = P2PUSBControlRoute.android(second)
        XCTAssertNil(a.appleUDID)
        XCTAssertNotEqual(a.digestMaterial(peerID: "peer-a"), b.digestMaterial(peerID: "peer-a"))
        XCTAssertNotEqual(a.digestMaterial(peerID: "peer-a"), a.digestMaterial(peerID: "peer-b"))
        XCTAssertEqual(a.digestMaterial(peerID: "peer-a"),
            "SkyBridge-Android-USB|\(channel.attachmentNonce.uuidString.lowercased())|MAIN|peer-a")
        XCTAssertEqual(P2PUSBControlRoute.apple(udid: "test-udid").digestMaterial(peerID: "peer-a"),
            "SkyBridge-USB|test-udid|9527|peer-a")
        try await physical.closeAndAwait()
    }
}
#endif
