import CryptoKit
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PIdentityCertificateIssuerTests: XCTestCase {
    @MainActor
    func testPairingConfirmedCertificateRequiresActiveSignerTrust() async throws {
        let signerId = "certificate-signer-\(UUID().uuidString)"
        let signerPrivateKey = P256.Signing.PrivateKey()
        let signerPublicKey = signerPrivateKey.publicKey.x963Representation
        let subjectPublicKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let createdAt = Date()
        let expiresAt = createdAt.addingTimeInterval(3_600)
        let unsigned = P2PIdentityCertificate(
            deviceId: "certificate-subject",
            publicKey: subjectPublicKey,
            pubKeyFP: SHA256.hash(data: subjectPublicKey).map { String(format: "%02x", $0) }.joined(),
            attestationLevel: .none,
            capabilities: [],
            signerType: .pairingConfirmed,
            signerId: signerId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            signature: Data()
        )
        let signature = try signerPrivateKey.signature(for: unsigned.dataToSign()).derRepresentation
        let certificate = P2PIdentityCertificate(
            deviceId: unsigned.deviceId,
            publicKey: unsigned.publicKey,
            pubKeyFP: unsigned.pubKeyFP,
            attestationLevel: unsigned.attestationLevel,
            capabilities: unsigned.capabilities,
            signerType: unsigned.signerType,
            signerId: unsigned.signerId,
            version: unsigned.version,
            createdAt: unsigned.createdAt,
            expiresAt: unsigned.expiresAt,
            signature: signature
        )

        let trust = TrustSyncService.shared
        trust.setInMemoryPersistenceForTesting(true)
        try await trust.removeRecordsForTesting(deviceIds: [signerId])
        addTeardownBlock { @MainActor [trust] in
            try await trust.removeRecordsForTesting(deviceIds: [signerId])
            trust.setInMemoryPersistenceForTesting(false)
        }

        for lifecycleState in [
            TrustLifecycleState.quarantined,
            .reverificationRequired,
            .revoked
        ] {
            try await trust.removeRecordsForTesting(deviceIds: [signerId])
            _ = try await trust.addTrustRecord(
                makeSignerRecord(
                    signerId: signerId,
                    publicKey: signerPublicKey,
                    lifecycleState: lifecycleState
                )
            )
            do {
                _ = try await P2PIdentityCertificateIssuer.shared.verifyCertificate(certificate)
                XCTFail("\(lifecycleState.rawValue) signer trust must not validate certificates")
            } catch let error as CertificateError {
                guard case .untrusted = error else {
                    XCTFail("Expected untrusted, got \(error)")
                    continue
                }
            }
        }

        try await trust.removeRecordsForTesting(deviceIds: [signerId])
        _ = try await trust.addTrustRecord(
            makeSignerRecord(
                signerId: signerId,
                publicKey: signerPublicKey,
                lifecycleState: .active
            )
        )
        let verifiedAfterReactivation = try await P2PIdentityCertificateIssuer.shared
            .verifyCertificate(certificate)
        XCTAssertTrue(verifiedAfterReactivation)
    }

    private func makeSignerRecord(
        signerId: String,
        publicKey: Data,
        lifecycleState: TrustLifecycleState
    ) -> TrustRecord {
        TrustRecord(
            deviceId: signerId,
            pubKeyFP: SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined(),
            publicKey: publicKey,
            signature: Data(),
            lifecycleState: lifecycleState
        )
    }
}
