import CryptoKit
import XCTest
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
final class CrossNetworkQRCodeVerificationPolicyTests: XCTestCase {
    func testAcceptsSignedV7QRCodeWithValidKEMKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(now: now)

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertTrue(result.ok)
        XCTAssertNil(result.reason)
    }

    func testRejectsV7QRCodeWithoutKEMKeyBeforeSignatureWork() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(now: now, kemPublicKeys: [])

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码缺少 PQC KEM 公钥")
    }

    func testRejectsLegacyQRCodeThatCarriesKEMKey() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(version: 6, now: now)

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码 KEM 公钥需要 v7 协议")
    }

    func testRejectsProtocolFingerprintMismatch() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(
            now: now,
            protocolPublicKeyFingerprintOverride: String(repeating: "0", count: 64)
        )

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码长期协议公钥指纹不匹配")
    }

    func testRejectsExpiredQRCodeOutsideClockSkew() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let qr = try signedQRCode(
            now: now,
            expiresAt: now.addingTimeInterval(-121)
        )

        let result = try await CrossNetworkQRCodeVerificationPolicy.verify(qr, now: now)

        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.reason, "二维码已过期")
    }

    private func signedQRCode(
        version: Int = 7,
        now: Date,
        expiresAt: Date? = nil,
        kemPublicKeys: [KEMPublicKeyInfo]? = nil,
        protocolPublicKeyFingerprintOverride: String? = nil
    ) throws -> DynamicQRCodeData {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation
        let fingerprint = CurrentPathSecurityCompat.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: publicKey
        )
        let timestampMs = Int64(now.timeIntervalSince1970 * 1000)
        let unsigned = DynamicQRCodeData(
            version: version,
            sessionID: "session-qr-policy-0001",
            qrBootstrapToken: "bootstrap-token-qr-policy",
            signalingServerOrigin: "https://signal.example.com",
            deviceID: "id:qr-policy-device-0001",
            deviceName: "Policy Mac",
            deviceType: "mac",
            osVersion: "macOS 26.5",
            capabilities: ["cross-network"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: protocolPublicKeyFingerprintOverride ?? fingerprint,
            kemPublicKeys: kemPublicKeys ?? [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.xwing.wireId,
                    publicKey: Data(repeating: 0x42, count: 1_216)
                )
            ],
            signature: nil,
            signatureTimestampMs: timestampMs,
            expiresAt: expiresAt ?? now.addingTimeInterval(300)
        )
        let signature = try signingKey.signature(for: unsigned.canonicalSignaturePayload)
        return DynamicQRCodeData(
            version: unsigned.version,
            sessionID: unsigned.sessionID,
            qrBootstrapToken: unsigned.qrBootstrapToken,
            signalingServerOrigin: unsigned.signalingServerOrigin,
            deviceID: unsigned.deviceID,
            deviceName: unsigned.deviceName,
            deviceType: unsigned.deviceType,
            osVersion: unsigned.osVersion,
            capabilities: unsigned.capabilities,
            protocolSigningAlgorithm: unsigned.protocolSigningAlgorithm,
            protocolPublicKeyBytes: unsigned.protocolPublicKeyBytes,
            protocolPublicKeyFingerprint: unsigned.protocolPublicKeyFingerprint,
            kemPublicKeys: unsigned.kemPublicKeys,
            signature: signature,
            signatureTimestampMs: unsigned.signatureTimestampMs,
            expiresAt: unsigned.expiresAt
        )
    }
}
