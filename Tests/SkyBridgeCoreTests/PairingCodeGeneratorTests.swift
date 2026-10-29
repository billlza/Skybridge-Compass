import XCTest
import CryptoKit
@testable import SkyBridgeCore

/// Verifies the `skybridge-pair:v1` generator emits the exact shape the Windows
/// `PairingMaterialClient` parses, and that it preserves the load-bearing invariant
/// `SHA-256(base64url-decode(pubKey)) == pubKeyFP`.
final class PairingCodeGeneratorTests: XCTestCase {
    func testFormatAndWindowsInvariant() throws {
        // A P-256-x963-shaped 65-byte public key + its real SHA-256 fingerprint.
        let publicKey = Data((0..<65).map { UInt8($0 & 0xff) })
        let pubKeyFP = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()

        let code = PairingCodeGenerator.makePairCode(
            deviceId: "9F1C-UUID",
            publicKey: publicKey,
            pubKeyFP: pubKeyFP,
            deviceName: "Bill's Mac")

        XCTAssertTrue(code.hasPrefix("skybridge-pair:v1;"))
        XCTAssertTrue(code.contains("deviceId=9F1C-UUID"))
        XCTAssertTrue(code.contains("pubKeyFP=\(pubKeyFP)"))
        XCTAssertTrue(code.contains("platform=macos"))
        XCTAssertEqual(pubKeyFP.count, 64)
        // Spaces / apostrophes in the name must be percent-encoded, not raw.
        XCTAssertFalse(code.contains("Bill's Mac"))

        // The Windows-side invariant the proof binding depends on.
        let pubField = try XCTUnwrap(
            code.split(separator: ";").first { $0.hasPrefix("pubKey=") }).dropFirst("pubKey=".count)
        let decoded = try XCTUnwrap(Self.base64urlDecode(String(pubField)))
        let reFp = SHA256.hash(data: decoded).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(reFp, pubKeyFP, "SHA-256(base64url-decode(pubKey)) must equal pubKeyFP")
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }
}
