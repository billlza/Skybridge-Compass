import CryptoKit
import Foundation
import SkyBridgeProtocolCore
import XCTest

final class ClassicTransferApprovalVectorTests: XCTestCase {
    func testExtendedMetadataAndDecisionsMatchIndependentWireVectors() throws {
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let bytes = try ClassicTransferCanonicalTranscript.metadata(
            transferID: "t", fileName: "f", fileSize: 0, fileHash: String(repeating: "a", count: 64), chunkSize: 65536,
            securityVersion: 2, compression: nil, senderDeviceID: nil, senderDeviceName: nil, senderPlatform: nil,
            senderOSVersion: nil, senderModelName: nil, senderChip: nil, approvalProtocol: "metadata-bound-v1")
        let request = try ClassicTransferApprovalRequest(transferID: "t", authenticatedMetadataTranscript: bytes)
        XCTAssertEqual(request.metadataDigest, "79fe81f7847c8e51a276141af4d2269d1bb0b6e2eb088cc280268e150917f17d")
        XCTAssertEqual(Self.hex(Data(HMAC<SHA256>.authenticationCode(for: bytes, using: key))), "4161c9e87976df430d2a7231cfbc014f013b1a52ecb12b54a1d37845b1142173")
        let expected: [(ClassicTransferApprovalRefusal?, String)] = [
            (nil, "26108f405d37a73ba8e1416f10cbf38430da76367ae0548a495a99ad67cca83a"), (.denied, "d7c4128567c1e9c6862fbd9821b36df5de2d03c718173b931b44da82e94ee9ce"), (.unavailable, "182ac62ae216942dd4be1912f9e6692e58060165d72ff929846e16f95a3e593e")
        ]
        for (reason, tag) in expected {
            let response = try ClassicTransferApprovalContract.makeResponse(for: request, refusal: reason, using: key)
            XCTAssertEqual(Self.hex(response.authTag), tag)
        }
    }

    func testNonAsciiLookalikesDoNotNegotiateTheAsciiCapability() {
        for token in ["CLASSİC_APPROVAL_V1", "classıc_approval_v1"] {
            XCTAssertFalse(ClassicTransferApprovalContract.isSupported(by: [token]))
        }
    }

    private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
