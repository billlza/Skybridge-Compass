import XCTest
import CryptoKit
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PSessionTests: XCTestCase {
    func testDynamicQRCodeDataRoundTrip() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: publicKey
        )
        let original = DynamicQRCodeData(
            version: 6,
            sessionID: UUID().uuidString,
            qrBootstrapToken: "bootstrap-token",
            signalingServerOrigin: "https://api.example.com",
            deviceID: "12345678-1234-1234-1234-1234567890ab",
            deviceName: "Test Device",
            deviceType: P2PDeviceType.macOS.rawValue,
            osVersion: "macOS-test",
            capabilities: ["cross-network", "p2p"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: fingerprint,
            signature: nil,
            signatureTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            expiresAt: Date().addingTimeInterval(300)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DynamicQRCodeData.self, from: data)

        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.sessionID, original.sessionID)
        XCTAssertEqual(decoded.qrBootstrapToken, original.qrBootstrapToken)
        XCTAssertEqual(decoded.signalingServerOrigin, original.signalingServerOrigin)
        XCTAssertEqual(decoded.deviceID, original.deviceID)
        XCTAssertEqual(decoded.deviceName, original.deviceName)
        XCTAssertEqual(decoded.deviceType, original.deviceType)
        XCTAssertEqual(decoded.osVersion, original.osVersion)
        XCTAssertEqual(decoded.protocolSigningAlgorithm, original.protocolSigningAlgorithm)
        XCTAssertEqual(decoded.protocolPublicKeyBytes, original.protocolPublicKeyBytes)
        XCTAssertEqual(decoded.protocolPublicKeyFingerprint, original.protocolPublicKeyFingerprint)
        XCTAssertEqual(decoded.signature, original.signature)
        XCTAssertEqual(decoded.signatureTimestampMs, original.signatureTimestampMs)
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, original.expiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDynamicQRCodeDataExpirationField() {
        let publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let expired = DynamicQRCodeData(
            version: 6,
            sessionID: UUID().uuidString,
            qrBootstrapToken: "bootstrap-token",
            signalingServerOrigin: "https://api.example.com",
            deviceID: "12345678-1234-1234-1234-1234567890ab",
            deviceName: "Expired Device",
            deviceType: P2PDeviceType.iOS.rawValue,
            osVersion: "iOS-test",
            capabilities: ["cross-network"],
            protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: publicKey,
            protocolPublicKeyFingerprint: ProtocolIdentityBinding.computeFingerprint(
                algorithm: .ed25519,
                publicKeyBytes: publicKey
            ),
            signature: nil,
            signatureTimestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            expiresAt: Date().addingTimeInterval(-1)
        )

        XCTAssertLessThan(expired.expiresAt, Date())
    }
}
