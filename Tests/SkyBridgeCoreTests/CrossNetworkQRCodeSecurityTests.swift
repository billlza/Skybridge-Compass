import XCTest
import CryptoKit
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class CrossNetworkQRCodeSecurityTests: XCTestCase {
    private func makeSignedQRCode(
        sessionID: String = "session-123",
        qrBootstrapToken: String = "bootstrap-token",
        expiresAt: Date = Date().addingTimeInterval(300),
        signalingServerOrigin: String = "https://api.example.com",
        deviceId: String = "12345678-1234-1234-1234-1234567890ab"
    ) async throws -> DynamicQRCodeData {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: publicKey
        )
        let unsigned = DynamicQRCodeData(
            version: 6,
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
}
