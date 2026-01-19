import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PSessionTests: XCTestCase {
    func testDynamicQRCodeDataRoundTrip() throws {
        let original = DynamicQRCodeData(
            version: 1,
            sessionID: UUID().uuidString,
            deviceName: "Test Device",
            deviceFingerprint: "1234567890ABCDEF",
            publicKey: Data([0x01, 0x02, 0x03]),
            signingPublicKey: nil,
            signature: nil,
            signatureTimestamp: nil,
            iceServers: ["stun:stun.l.google.com:19302"],
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
        XCTAssertEqual(decoded.deviceName, original.deviceName)
        XCTAssertEqual(decoded.deviceFingerprint, original.deviceFingerprint)
        XCTAssertEqual(decoded.publicKey, original.publicKey)
        XCTAssertEqual(decoded.signingPublicKey, original.signingPublicKey)
        XCTAssertEqual(decoded.signature, original.signature)
        XCTAssertEqual(decoded.signatureTimestamp, original.signatureTimestamp)
        XCTAssertEqual(decoded.iceServers, original.iceServers)
        XCTAssertEqual(decoded.expiresAt.timeIntervalSince1970, original.expiresAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDynamicQRCodeDataExpirationField() {
        let expired = DynamicQRCodeData(
            version: 1,
            sessionID: UUID().uuidString,
            deviceName: "Expired Device",
            deviceFingerprint: "1234567890ABCDEF",
            publicKey: Data(),
            signingPublicKey: nil,
            signature: nil,
            signatureTimestamp: nil,
            iceServers: [],
            expiresAt: Date().addingTimeInterval(-1)
        )

        XCTAssertLessThan(expired.expiresAt, Date())
    }
}
