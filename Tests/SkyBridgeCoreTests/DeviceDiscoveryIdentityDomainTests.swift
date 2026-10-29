import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

#if HAS_APPLE_PQC_SDK
import CryptoKit

@available(macOS 26.0, *)
@MainActor
final class DeviceDiscoveryIdentityDomainTests: XCTestCase {
    private struct LocalIdentities {
        let deviceAuthority: SelfIdentitySnapshot
        let advertisement: ProtocolIdentityBinding
        let discoveryAuthority: CanonicalBonjourAdvertisementIdentity
    }

    private func makeLocalIdentities() throws -> LocalIdentities {
        let deviceID = "9A770257-EE43-4D15-9031-D39B7A4AE045"
        let deviceKey = P256.Signing.PrivateKey()
        let protocolKey = try MLDSA65.PrivateKey()
        let deviceAuthority = SelfIdentitySnapshot(
            deviceId: deviceID,
            pubKeyFP: DeviceIdentityAuthorityRecord.fingerprint(for: deviceKey.publicKey.x963Representation),
            macSet: []
        )
        let protocolAuthority = CommittedLocalProtocolIdentitySnapshot(
            algorithm: .mlDSA65,
            protection: .softwareKeychain,
            publicKey: protocolKey.publicKey.rawRepresentation,
            keyHandle: .softwareKey(protocolKey.integrityCheckedRepresentation)
        )
        let advertisement = try ProtocolIdentityBinding(
            deviceId: deviceID,
            protocolSigningAlgorithm: protocolAuthority.algorithm,
            protocolPublicKeyBytes: protocolAuthority.publicKey
        )
        let discoveryAuthority = try CanonicalBonjourAdvertisementIdentityProvider.makeIdentity(
            deviceIdentity: deviceAuthority, protocolIdentity: protocolAuthority)
        XCTAssertEqual(discoveryAuthority.deviceId, advertisement.deviceId)
        XCTAssertEqual(discoveryAuthority.protocolPublicKeyFingerprint, advertisement.protocolPublicKeyFingerprint)
        XCTAssertEqual(deviceKey.publicKey.x963Representation.count, 65)
        XCTAssertEqual(protocolAuthority.publicKey.count, 1_952)
        XCTAssertNotEqual(deviceAuthority.pubKeyFP, advertisement.protocolPublicKeyFingerprint,
            "The P-256 device authority and ML-DSA protocol authority have different public keys and fingerprint domains.")
        return LocalIdentities(deviceAuthority: deviceAuthority, advertisement: advertisement, discoveryAuthority: discoveryAuthority)
    }

    private func device(id: String?, fingerprint: String) -> DiscoveredDevice {
        DiscoveredDevice(
            id: UUID(), name: "Workstation", ipv4: "192.0.2.10", ipv6: nil,
            services: [BonjourInteropContract.remoteControlServiceType],
            portMap: [BonjourInteropContract.remoteControlServiceType: 5901],
            routeIdentifiers: ["bonjour:Workstation@local."],
            source: .skybridgeBonjour, deviceId: id, pubKeyFP: fingerprint
        )
    }

    func testLocalMLDSAAdvertisementIsExcludedWhenP256DeviceFingerprintDiffers() throws {
        let identities = try makeLocalIdentities()
        let local = device(id: identities.advertisement.deviceId.lowercased(),
                           fingerprint: identities.advertisement.protocolPublicKeyFingerprint)
        let manager = DeviceDiscoveryManagerOptimized()
        manager.applyDiscoveryUpdates([local], fingerprints: [:], localIdentity: identities.discoveryAuthority)

        XCTAssertEqual(manager.discoveredDevices.count, 1)
        XCTAssertTrue(manager.discoveredDevices[0].isLocalDevice)
        XCTAssertFalse(manager.supportsRemoteControl(manager.discoveredDevices[0]))
        XCTAssertEqual(manager.discoveredDevices[0].pubKeyFP, identities.advertisement.protocolPublicKeyFingerprint)
        XCTAssertTrue(IdentityResolver.resolveIsLocalSynchronously(device: local, selfId: identities.deviceAuthority),
            "The existing P-256 snapshot entry point keeps device-ID recognition without treating the protocol key as its P-256 key.")
    }

    func testLocalProtocolFingerprintCanIdentifyIncompleteAdvertisement() throws {
        let identities = try makeLocalIdentities()
        let local = device(id: nil, fingerprint: identities.advertisement.protocolPublicKeyFingerprint)
        let manager = DeviceDiscoveryManagerOptimized()
        manager.applyDiscoveryUpdates([local], fingerprints: [:], localIdentity: identities.discoveryAuthority)

        XCTAssertTrue(manager.discoveredDevices[0].isLocalDevice)
        XCTAssertFalse(manager.supportsRemoteControl(manager.discoveredDevices[0]))
    }

    func testDifferentMLDSAKeyUnderSameDeviceIDRemainsAProtocolConflict() throws {
        let identities = try makeLocalIdentities()
        let otherProtocolKey = try MLDSA65.PrivateKey()
        let otherBinding = try ProtocolIdentityBinding(
            deviceId: identities.advertisement.deviceId,
            protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyBytes: otherProtocolKey.publicKey.rawRepresentation
        )
        let conflicting = device(id: otherBinding.deviceId, fingerprint: otherBinding.protocolPublicKeyFingerprint)
        let manager = DeviceDiscoveryManagerOptimized()
        manager.applyDiscoveryUpdates([conflicting], fingerprints: [:], localIdentity: identities.discoveryAuthority)

        XCTAssertFalse(manager.discoveredDevices[0].isLocalDevice)
        XCTAssertNotEqual(otherBinding.protocolPublicKeyFingerprint, identities.advertisement.protocolPublicKeyFingerprint)
    }

    func testMatchingMLDSAFingerprintDoesNotOverrideDifferentDeviceID() throws {
        let identities = try makeLocalIdentities()
        let conflicting = device(id: "22222222-2222-4222-8222-222222222222",
                                 fingerprint: identities.advertisement.protocolPublicKeyFingerprint)
        let manager = DeviceDiscoveryManagerOptimized()
        manager.applyDiscoveryUpdates([conflicting], fingerprints: [:], localIdentity: identities.discoveryAuthority)

        XCTAssertFalse(manager.discoveredDevices[0].isLocalDevice)
        XCTAssertEqual(manager.discoveredDevices[0].deviceId, conflicting.deviceId)
    }
}
#endif
