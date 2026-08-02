import XCTest
import CryptoKit
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class CrossNetworkQRCodeSecurityTests: XCTestCase {
    private func makeSignedQRCode(
        version: Int = 6,
        sessionID: String = "session-123",
        qrBootstrapToken: String = "bootstrap-token",
        expiresAt: Date = Date().addingTimeInterval(300),
        signalingServerOrigin: String = "https://api.example.com",
        deviceId: String = "12345678-1234-1234-1234-1234567890ab",
        kemPublicKeys: [KEMPublicKeyInfo] = []
    ) async throws -> DynamicQRCodeData {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: publicKey
        )
        let unsigned = DynamicQRCodeData(
            version: version,
            sessionID: sessionID,
            qrBootstrapToken: qrBootstrapToken,
            signalingServerOrigin: signalingServerOrigin,
            deviceID: deviceId,
            deviceName: "Test Mac",
            deviceType: P2PDeviceType.macOS.rawValue,
            osVersion: "macOS-test-99.0",
            capabilities: ["p2p", "cross-network"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: fingerprint,
            kemPublicKeys: kemPublicKeys,
            signature: nil,
            signatureTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            expiresAt: expiresAt
        )
        let signature = try signingKey.signature(
            for: CrossNetworkConnectionManager.buildCanonicalQRCodePayload(for: unsigned)
        )
        return unsigned.withSignature(signature)
    }

    func testCrossNetworkQRCodeBindsSensitiveClaims() async throws {
        let qrData = try await makeSignedQRCode()
        let baseline = await CrossNetworkConnectionManager.verifyDynamicQRCode(qrData)
        XCTAssertTrue(baseline.ok, baseline.reason ?? "")

        let tamperedSession = DynamicQRCodeData(
            version: qrData.version,
            sessionID: "session-999",
            qrBootstrapToken: qrData.qrBootstrapToken,
            signalingServerOrigin: qrData.signalingServerOrigin,
            deviceID: qrData.deviceID,
            deviceName: qrData.deviceName,
            deviceType: qrData.deviceType,
            osVersion: qrData.osVersion,
            capabilities: qrData.capabilities,
            protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
            protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
            signature: qrData.signature,
            signatureTimestampMs: qrData.signatureTimestampMs,
            expiresAt: qrData.expiresAt
        )
        let tamperedSessionResult = await CrossNetworkConnectionManager.verifyDynamicQRCode(tamperedSession)
        XCTAssertFalse(tamperedSessionResult.ok)

        let tamperedToken = DynamicQRCodeData(
            version: qrData.version,
            sessionID: qrData.sessionID,
            qrBootstrapToken: "bootstrap-token-999",
            signalingServerOrigin: qrData.signalingServerOrigin,
            deviceID: qrData.deviceID,
            deviceName: qrData.deviceName,
            deviceType: qrData.deviceType,
            osVersion: qrData.osVersion,
            capabilities: qrData.capabilities,
            protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
            protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
            signature: qrData.signature,
            signatureTimestampMs: qrData.signatureTimestampMs,
            expiresAt: qrData.expiresAt
        )
        let tamperedTokenResult = await CrossNetworkConnectionManager.verifyDynamicQRCode(tamperedToken)
        XCTAssertFalse(tamperedTokenResult.ok)

        let tamperedExpiry = DynamicQRCodeData(
            version: qrData.version,
            sessionID: qrData.sessionID,
            qrBootstrapToken: qrData.qrBootstrapToken,
            signalingServerOrigin: qrData.signalingServerOrigin,
            deviceID: qrData.deviceID,
            deviceName: qrData.deviceName,
            deviceType: qrData.deviceType,
            osVersion: qrData.osVersion,
            capabilities: qrData.capabilities,
            protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
            protocolPublicKeyBytes: qrData.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
            signature: qrData.signature,
            signatureTimestampMs: qrData.signatureTimestampMs,
            expiresAt: qrData.expiresAt.addingTimeInterval(30)
        )
        let tamperedExpiryResult = await CrossNetworkConnectionManager.verifyDynamicQRCode(tamperedExpiry)
        XCTAssertFalse(tamperedExpiryResult.ok)
    }

    func testVersion7QRCodeRequiresSignedKEMPublicKey() async throws {
        let missingKEM = try await makeSignedQRCode(version: 7)
        let missingResult = await CrossNetworkConnectionManager.verifyDynamicQRCode(missingKEM)

        XCTAssertFalse(missingResult.ok)
        XCTAssertEqual(missingResult.reason, "二维码缺少 PQC KEM 公钥")

        let signedKEM = try await makeSignedQRCode(
            version: 7,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x41, count: 1216)
                )
            ]
        )
        let signedResult = await CrossNetworkConnectionManager.verifyDynamicQRCode(signedKEM)

        XCTAssertTrue(signedResult.ok, signedResult.reason ?? "")

        let tamperedKEM = DynamicQRCodeData(
            version: signedKEM.version,
            sessionID: signedKEM.sessionID,
            qrBootstrapToken: signedKEM.qrBootstrapToken,
            signalingServerOrigin: signedKEM.signalingServerOrigin,
            deviceID: signedKEM.deviceID,
            deviceName: signedKEM.deviceName,
            deviceType: signedKEM.deviceType,
            osVersion: signedKEM.osVersion,
            capabilities: signedKEM.capabilities,
            protocolSigningAlgorithm: signedKEM.protocolSigningAlgorithm,
            protocolPublicKeyBytes: signedKEM.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: signedKEM.protocolPublicKeyFingerprint,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x42, count: 1216)
                )
            ],
            signature: signedKEM.signature,
            signatureTimestampMs: signedKEM.signatureTimestampMs,
            expiresAt: signedKEM.expiresAt
        )
        let tamperedResult = await CrossNetworkConnectionManager.verifyDynamicQRCode(tamperedKEM)

        XCTAssertFalse(tamperedResult.ok)
        XCTAssertEqual(tamperedResult.reason, "二维码签名验证失败")
    }

    func testVerifiedQRCodeWithSignedKEMDoesNotPersistP2PKEMTrustMaterial() async throws {
        let store = PeerKEMBootstrapStore.shared
        let deviceId = "id:\(UUID().uuidString.lowercased())"
        await store.clearForTesting()
        defer {
            Task { await store.clearForTesting() }
        }

        let signedKEM = try await makeSignedQRCode(
            version: 7,
            deviceId: deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x41, count: 1216)
                )
            ]
        )
        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(signedKEM)

        XCTAssertTrue(result.ok, result.reason ?? "")
        let persisted = await store.mergedKEMPublicKeys(forCandidates: [deviceId])
        XCTAssertTrue(
            persisted.isEmpty,
            "Verified QR KEM material must remain diagnostic/connect-link content; SKR-1 is the only P2P KEM import path."
        )
    }

    func testLegacyQRCodeCannotSmuggleKEMPublicKey() async throws {
        let legacyWithKEM = try await makeSignedQRCode(
            version: 6,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwingMLDSA.wireId,
                    publicKey: Data(repeating: 0x51, count: 1216)
                )
            ]
        )

        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(legacyWithKEM)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码 KEM 公钥需要 v7 协议")
    }

    func testCrossNetworkQRCodeRejectsOriginMismatch() async throws {
        let qrData = try await makeSignedQRCode(signalingServerOrigin: "https://other.example.com")
        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(qrData)
        XCTAssertTrue(result.ok, "signature verification is content-only; origin mismatch is enforced at scan time")
    }

    func testCrossNetworkQRCodeRejectsLegacyContract() async throws {
        let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let legacy = DynamicQRCodeData(
            version: 5,
            sessionID: "legacy-session",
            qrBootstrapToken: "legacy-token",
            signalingServerOrigin: "https://api.example.com",
            deviceID: "12345678-1234-1234-1234-1234567890ab",
            deviceName: "Legacy",
            deviceType: P2PDeviceType.macOS.rawValue,
            osVersion: "macOS-old",
            capabilities: ["cross-network"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: ProtocolIdentityBinding.computeFingerprint(
                algorithm: .ed25519,
                publicKeyBytes: publicKey
            ),
            signature: nil,
            signatureTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            expiresAt: Date().addingTimeInterval(300)
        )
        let legacyResult = await CrossNetworkConnectionManager.verifyDynamicQRCode(legacy)
        XCTAssertFalse(legacyResult.ok)
    }

    func testAuthenticatedQRCodeRebindPolicyRejectsSilentCurrentPathConflicts() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedQRRebind(for: .revokedIdentity)
        )
    }

    func testAuthenticatedConnectionCodeRebindOnlyAllowsSameDeviceIdentityConflictHealing() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .identityConflict)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .deviceIdMigrationRequired)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .quarantinedIdentity)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldAllowAuthenticatedConnectionCodeRebind(for: .revokedIdentity)
        )
    }

    func testCrossNetworkQRCodeAllowsAuthenticatedAuthorityRekeyForExistingDeviceId() async throws {
        let trust = TrustSyncService.shared
        let qrData = try await makeSignedQRCode()
        let deviceId = qrData.deviceID

        trust.setInMemoryPersistenceForTesting(true)
        try await trust.removeRecordsForTesting(deviceIds: [deviceId])
        addTeardownBlock { @MainActor [trust] in
            try await trust.removeRecordsForTesting(deviceIds: [deviceId])
            trust.setInMemoryPersistenceForTesting(false)
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: deviceId,
                pubKeyFP: String(repeating: "1", count: 64),
                publicKey: Data([0x01]),
                protocolPublicKey: Data([0x02]),
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: String(repeating: "2", count: 64),
                signature: Data(),
                deviceName: "Existing Device",
                currentDeviceId: deviceId,
                knownDeviceIds: [deviceId]
            )
        )

        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(qrData)

        XCTAssertTrue(result.ok, result.reason ?? "")
        XCTAssertNil(result.reason)
    }

    func testCrossNetworkQRCodeTreatsAliasMatchedPinnedAuthorityAsTrustedDevice() async throws {
        let trust = TrustSyncService.shared
        let suffix = UUID().uuidString.lowercased()
        let aliasId = "bonjour:skybridge-\(suffix)@local."
        let stableId = "id:\(suffix)"
        let qrData = try await makeSignedQRCode(deviceId: stableId)

        trust.setInMemoryPersistenceForTesting(true)
        try await trust.removeRecordsForTesting(deviceIds: [aliasId, stableId])
        addTeardownBlock { @MainActor [trust] in
            try await trust.removeRecordsForTesting(deviceIds: [aliasId, stableId])
            trust.setInMemoryPersistenceForTesting(false)
        }

        _ = try await trust.addTrustRecord(
            TrustRecord(
                deviceId: aliasId,
                pubKeyFP: String(repeating: "3", count: 64),
                publicKey: qrData.protocolPublicKeyBytes,
                protocolPublicKey: qrData.protocolPublicKeyBytes,
                protocolSigningAlgorithm: qrData.protocolSigningAlgorithm,
                protocolPublicKeyFingerprint: qrData.protocolPublicKeyFingerprint,
                signature: Data(),
                deviceName: "Pinned Mac",
                currentDeviceId: stableId,
                knownDeviceIds: [aliasId, stableId]
            )
        )

        let result = await CrossNetworkConnectionManager.verifyDynamicQRCode(qrData)

        XCTAssertTrue(result.ok, result.reason ?? "")
        XCTAssertEqual(result.source, .trustedDevice)
    }
}
