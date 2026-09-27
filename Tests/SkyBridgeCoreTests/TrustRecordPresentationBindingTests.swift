import CryptoKit
import XCTest
@testable import SkyBridgeCore

final class TrustRecordPresentationBindingTests: XCTestCase {
    func testDisplayProjectionPreservesCurrentProtocolBindingAndSignatureVersion() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(algorithm: .ed25519, publicKeyBytes: key)
        let binding = ProtocolIdentityBindingV2(
            algorithm: .ed25519, publicKey: key, fingerprint: fingerprint,
            source: .authenticatedHandshake, generation: 1
        )
        let record = TrustRecord(
            deviceId: "id:current-ipad", pubKeyFP: "", publicKey: Data(),
            protocolIdentityBindingsV2: [binding], capabilities: ["trusted"],
            signaturePayloadVersion: TrustRecord.currentSignaturePayloadVersion,
            signature: Data([1]), deviceName: "iPad",
            currentDeviceId: "id:current-ipad", knownDeviceIds: ["id:prior-ipad"]
        )
        XCTAssertEqual(record.currentPathAuthorityFingerprints, [fingerprint])
        let projected = try XCTUnwrap(TrustSyncService.buildDisplayGroups(from: [record]).first).displayRecord
        XCTAssertEqual(projected.protocolIdentityBindingsV2, record.protocolIdentityBindingsV2)
        XCTAssertEqual(projected.currentPathAuthorityFingerprints, record.currentPathAuthorityFingerprints,
            "A current identity must not become an unbound placeholder during display projection")
        XCTAssertEqual(projected.signaturePayloadVersion, record.signaturePayloadVersion)
        XCTAssertFalse(projected.requiresIdentityVerificationForPresentation)
    }

    func testSavedTrustedFlagAndAliasesDoNotSubstituteForAnIdentityBinding() {
        let record = TrustRecord(
            deviceId: "11111111-1111-4111-8111-111111111111", pubKeyFP: "", publicKey: Data(),
            capabilities: ["trusted", "file_transfer", "peerEndpoint=bonjour:iPad@local."],
            signature: Data(), deviceName: "iPad",
            currentDeviceId: "id:old-ipad", knownDeviceIds: ["id:old-ipad", "peer:192.0.2.10"]
        )
        XCTAssertTrue(record.requiresIdentityVerificationForPresentation)
        XCTAssertTrue(TrustSyncService.buildDisplayGroups(from: [record])[0].displayRecord.requiresIdentityVerificationForPresentation)
    }

    func testSuspendedIdentityRequiresVerificationEvenWhenKeyMaterialRemains() {
        for state: TrustLifecycleState in [.reverificationRequired, .quarantined, .revoked] {
            let record = TrustRecord(
                deviceId: "id:ipad", pubKeyFP: String(repeating: "a", count: 64),
                publicKey: Data(repeating: 1, count: 32), capabilities: ["trusted"],
                signature: Data(), lifecycleState: state
            )
            XCTAssertTrue(record.requiresIdentityVerificationForPresentation)
        }
    }

    func testDisplayProjectionPreservesLegacyProtocolPins() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(algorithm: .ed25519, publicKeyBytes: key)
        let pins = [ProtocolIdentityPin(algorithm: .ed25519, fingerprint: fingerprint, source: .manualPairingImport)]
        let record = TrustRecord(
            deviceId: "id:current-ipad", pubKeyFP: "", publicKey: Data(),
            protocolPublicKey: key, protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyFingerprint: fingerprint, protocolIdentityPins: pins,
            capabilities: ["trusted"], signature: Data(), deviceName: "iPad"
        )
        let projected = try XCTUnwrap(TrustSyncService.buildDisplayGroups(from: [record]).first).displayRecord
        XCTAssertEqual(projected.protocolIdentityPins, record.protocolIdentityPins)
        XCTAssertFalse(projected.requiresIdentityVerificationForPresentation)
    }

    func testOldUnboundPairingRemainsSeparateFromAnotherCurrentIdentity() throws {
        let old = TrustRecord(
            deviceId: "11111111-1111-4111-8111-111111111111", pubKeyFP: "", publicKey: Data(),
            capabilities: ["trusted", "platform=iPadOS", "modelName=iPad16,3"],
            signature: Data(), deviceName: "iPad"
        )
        let current = TrustRecord(
            deviceId: "id:22222222-2222-4222-8222-222222222222", pubKeyFP: String(repeating: "a", count: 64),
            publicKey: Data(repeating: 1, count: 32),
            capabilities: ["trusted", "platform=iPadOS", "modelName=iPad16,3"],
            signature: Data(), deviceName: "Ziang的iPad"
        )
        let groups = TrustSyncService.buildPresentationDisplayGroups(from: [old, current])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.filter { $0.displayRecord.requiresIdentityVerificationForPresentation }.map(\.primaryRecord.deviceId), [old.deviceId])
        XCTAssertEqual(groups.filter { !$0.displayRecord.requiresIdentityVerificationForPresentation }.map(\.primaryRecord.deviceId), [current.deviceId])
    }
}
