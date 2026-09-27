import CryptoKit
import Foundation
import SkyBridgeProtocolCore
import XCTest

final class ClassicTransferApprovalTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    private func metadata(mode: String? = "metadata-bound-v1", fileName: String = "f") throws -> Data {
        try ClassicTransferCanonicalTranscript.metadata(
            transferID: "t", fileName: fileName, fileSize: 0,
            fileHash: String(repeating: "a", count: 64), chunkSize: 65_536,
            securityVersion: 2, compression: nil, senderDeviceID: nil,
            senderDeviceName: nil, senderPlatform: nil, senderOSVersion: nil,
            senderModelName: nil, senderChip: nil, approvalProtocol: mode
        )
    }

    private func request(fileName: String = "f") throws -> ClassicTransferApprovalRequest {
        try ClassicTransferApprovalRequest(transferID: "t", authenticatedMetadataTranscript: metadata(fileName: fileName))
    }

    private func altered(
        _ response: ClassicTransferApprovalResponse, changes: [String: Any]
    ) throws -> ClassicTransferApprovalResponse {
        let encoded = try JSONEncoder().encode(response)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (field, value) in changes { json[field] = value }
        return try JSONDecoder().decode(ClassicTransferApprovalResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testApprovalAndBothRefusalsAuthenticateExactRequest() throws {
        let request = try request()
        for reason: ClassicTransferApprovalRefusal? in [nil, .denied, .unavailable] {
            let response = try ClassicTransferApprovalContract.makeResponse(for: request, refusal: reason, using: key)
            let encoded = try JSONEncoder().encode(response)
            XCTAssertLessThan(encoded.count, ClassicTransferApprovalContract.maximumPayloadBytes)
            let decoded = try JSONDecoder().decode(ClassicTransferApprovalResponse.self, from: encoded)
            XCTAssertEqual(try ClassicTransferApprovalContract.validateResponse(decoded, for: request, using: key), reason)
        }
    }

    func testNoApprovalForOtherMetadataKeyOrTransfer() throws {
        let request = try request()
        let response = try ClassicTransferApprovalContract.makeResponse(for: request, refusal: nil, using: key)
        XCTAssertThrowsError(try ClassicTransferApprovalContract.validateResponse(response, for: self.request(fileName: "other"), using: key))
        XCTAssertThrowsError(try ClassicTransferApprovalContract.validateResponse(response, for: request, using: SymmetricKey(data: Data(repeating: 0x43, count: 32))))
        XCTAssertThrowsError(try ClassicTransferApprovalContract.validateResponse(try altered(response, changes: ["transferId": "other"]), for: request, using: key))
        for length in [0, 31, 33] {
            XCTAssertThrowsError(try ClassicTransferApprovalContract.validateResponse(
                try altered(response, changes: ["authTag": Data(repeating: 0, count: length).base64EncodedString()]),
                for: request, using: key))
        }
    }

    func testTamperedDecisionAndMalformedShapesAreRejected() throws {
        let request = try request()
        let response = try ClassicTransferApprovalContract.makeResponse(for: request, refusal: .denied, using: key)
        for changes: [String: Any] in [
            ["accepted": true], ["reason": NSNull()], ["reason": "unknown"],
            ["accepted": true, "reason": NSNull()], ["reason": "unavailable"],
            ["securityVersion": 1], ["securityVersion": 3], ["metadataDigest": String(repeating: "A", count: 64)]
        ] {
            XCTAssertThrowsError(try ClassicTransferApprovalContract.validateResponse(try altered(response, changes: changes), for: request, using: key))
        }
    }

    func testModeIsStrictAndAuthenticatedWithoutChangingAbsentMode() throws {
        XCTAssertNotEqual(try metadata(), try metadata(mode: nil))
        for invalid in ["", "legacy", "metadata-bound-v2", " metadata-bound-v1"] {
            XCTAssertThrowsError(try metadata(mode: invalid))
        }
        XCTAssertFalse(ClassicTransferApprovalContract.isSupported(by: []))
        XCTAssertFalse(ClassicTransferApprovalContract.isSupported(by: ["file", "classic_resume", "classic_approval_v10"]))
        XCTAssertTrue(ClassicTransferApprovalContract.isSupported(by: [" CLASSIC_APPROVAL_V1 "]))
    }

    func testReceiptAndResumeMacCannotApprove() throws {
        let request = try request()
        let response = try ClassicTransferApprovalContract.makeResponse(for: request, refusal: nil, using: key)
        let receipt = try ClassicTransferCanonicalTranscript.receipt(
            transferID: "t", success: true, receivedBytes: 0, fileHash: nil, error: nil, securityVersion: 2)
        let resume = try ClassicTransferCanonicalTranscript.resumeAcknowledgment(
            transferID: "t", accepted: true, resumeOffset: 0, error: nil, securityVersion: 2)
        for wrongPurpose in [receipt, resume, try metadata()] {
            let tag = Data(HMAC<SHA256>.authenticationCode(for: wrongPurpose, using: key))
            XCTAssertThrowsError(try ClassicTransferApprovalContract.validateResponse(
                try altered(response, changes: ["authTag": tag.base64EncodedString()]), for: request, using: key))
        }
    }
}
