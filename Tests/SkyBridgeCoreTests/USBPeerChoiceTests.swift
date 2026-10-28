import CryptoKit
import XCTest
@testable import SkyBridgeCore

@MainActor
final class USBPeerChoiceTests: XCTestCase {
    func testPairedIdentityIsSelectableWithoutAnyDiscoveryRecord() async throws {
        let peerID = UUID().uuidString
        let record = makeRecord(id: "id:\(peerID)")
        let choices = await TrustSyncService.usbPeerChoices(from: [record])
        XCTAssertEqual(choices.count, 1)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertEqual(choice.peer_id, peerID)
        XCTAssertEqual(choice.expected_fingerprint, record.protocolPublicKeyFingerprint)
        XCTAssertNil(choice.unavailable_reason)
    }

    func testConflictingPinsStayVisibleButCannotBeSelected() async throws {
        let peerID = UUID().uuidString
        let first = makeRecord(id: "id:\(peerID)")
        let other = makeRecord(id: peerID)
        let choices = await TrustSyncService.usbPeerChoices(from: [first, other])
        XCTAssertEqual(choices.count, 1)
        let choice = try XCTUnwrap(choices.first)
        XCTAssertNil(choice.expected_fingerprint)
        XCTAssertEqual(choice.unavailable_reason, "pairing_identity_needs_verification")
    }

    func testDisplayAliasCannotCreateASelectableProtocolIdentity() async {
        let claimed = UUID().uuidString
        let record = makeRecord(id: "account:display-only", alias: claimed)
        let choices = await TrustSyncService.usbPeerChoices(from: [record])
        XCTAssertTrue(choices.isEmpty)
    }

    func testRevokedAndQuarantinedRecordsAreNotConnectionChoices() async {
        let revoked = makeRecord(id: UUID().uuidString, lifecycle: .revoked)
        let quarantined = makeRecord(id: UUID().uuidString, lifecycle: .quarantined)
        let choices = await TrustSyncService.usbPeerChoices(from: [revoked, quarantined])
        XCTAssertTrue(choices.isEmpty)
    }

    private func makeRecord(id: String, alias: String? = nil,
                            lifecycle: TrustLifecycleState = .active) -> TrustRecord {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(algorithm: .ed25519, publicKeyBytes: key)
        return TrustRecord(
            deviceId: id, pubKeyFP: fingerprint, publicKey: key,
            protocolPublicKey: key, protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fingerprint, signature: Data(),
            deviceName: "Paired device", currentDeviceId: alias, knownDeviceIds: alias.map { [$0] },
            lifecycleState: lifecycle
        )
    }
}

@MainActor
final class USBReconnectRouteTests: XCTestCase {
    private let peer = "12345678-1234-4234-8234-123456789ABC"
    private let fingerprint = String(repeating: "a", count: 64)
    private func target(id: String? = nil, pin: String? = nil) -> DiscoveredDevice {
        DiscoveredDevice(id: UUID(), name: "iPad", ipv4: "192.168.0.104", ipv6: nil,
            platformName: "ios", services: ["_skybridge._tcp"], portMap: [:],
            connectionTypes: [.usb, .wifi], uniqueIdentifier: "bonjour:old-ipad@local.",
            deviceId: id ?? peer, pubKeyFP: pin ?? fingerprint)
    }
    private func attached(_ udid: String, type: String = "USB") -> USBMultiplexDevice {
        USBMultiplexDevice(deviceID: 10, udid: udid, productID: 4779, connectionType: type)
    }
    func testDisconnectedKnownPeerCanReconnectWithoutNetworkEndpoint() throws {
        let selected = try XCTUnwrap(P2PDiscoveryService.resolveUSBReconnectRoute(
            peerID: "id:" + peer.lowercased(), expectedFingerprint: fingerprint,
            knownTargets: ["cable-a": target()], attached: [attached("cable-a")]))
        XCTAssertEqual(selected.udid, "cable-a")
        XCTAssertEqual(selected.device.deviceId, peer)
        XCTAssertEqual(selected.device.pubKeyFP, fingerprint)
        XCTAssertNil(selected.device.ipv4)
        XCTAssertNil(selected.device.ipv6)
        XCTAssertTrue(selected.device.portMap.isEmpty)
        XCTAssertEqual(selected.device.uniqueIdentifier, "usb:cable-a")
        XCTAssertEqual(selected.device.connectionTypes, [.usb])
    }
    func testDetachedAndNetworkOnlyTwinsDoNotSupplyCableRoutes() throws {
        for devices in [[], [attached("cable-a", type: "Network")], [attached("other-cable")]] {
            XCTAssertNil(try P2PDiscoveryService.resolveUSBReconnectRoute(peerID: peer,
                expectedFingerprint: fingerprint, knownTargets: ["cable-a": target()], attached: devices))
        }
    }
    func testMatchingDisplayNameCannotSelectAnotherProtocolIdentity() throws {
        XCTAssertNil(try P2PDiscoveryService.resolveUSBReconnectRoute(peerID: peer,
            expectedFingerprint: fingerprint, knownTargets: ["cable-a": target(id: UUID().uuidString)],
            attached: [attached("cable-a")]))
        XCTAssertNil(try P2PDiscoveryService.resolveUSBReconnectRoute(peerID: peer,
            expectedFingerprint: fingerprint, knownTargets: [:], attached: [attached("cable-a")]))
    }
    func testChangedPinFailsInsteadOfFallingThroughToANetworkRoute() {
        XCTAssertThrowsError(try P2PDiscoveryService.resolveUSBReconnectRoute(peerID: peer,
            expectedFingerprint: String(repeating: "b", count: 64),
            knownTargets: ["cable-a": target()], attached: [attached("cable-a")]))
    }
    func testAmbiguousAttachedBindingsAndDuplicateEnumerationFail() {
        for devices in [[attached("cable-a"), attached("cable-b")], [attached("cable-a"), attached("cable-a")]] {
            XCTAssertThrowsError(try P2PDiscoveryService.resolveUSBReconnectRoute(peerID: peer,
                expectedFingerprint: fingerprint, knownTargets: ["cable-a": target(), "cable-b": target()],
                attached: devices)) { XCTAssertEqual($0 as? USBMultiplexError, .ambiguousDevice) }
        }
    }
}
