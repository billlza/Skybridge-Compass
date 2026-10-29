import Foundation
import SkyBridgeProtocolCore
import XCTest

final class ClassicTransferCapabilityEvidenceTests: XCTestCase {
    private let transcript = Data(repeating: 0x51, count: 32)

    func testAcceptedCurrentIdentityDistinguishesSupportedAndLegacy() throws {
        let supported = try ClassicTransferPeerCapabilities(acceptedCapabilities: ["file", "classic_approval_v1"], sessionID: "session-a", transcriptHash: transcript)
        XCTAssertEqual(supported.approvalSupport(sessionID: "session-a", transcriptHash: transcript), true)
        for capabilities: [String]? in [nil, [], ["file", "classic_resume"]] {
            let legacy = try ClassicTransferPeerCapabilities(acceptedCapabilities: capabilities, sessionID: "session-a", transcriptHash: transcript)
            XCTAssertEqual(legacy.approvalSupport(sessionID: "session-a", transcriptHash: transcript), false)
        }
    }

    func testStaleEvidenceIsUnknownForBothPositiveAndLegacyRecords() throws {
        for capabilities in [["classic_approval_v1"], [String]()] {
            let record = try ClassicTransferPeerCapabilities(acceptedCapabilities: capabilities, sessionID: "session-a", transcriptHash: transcript)
            XCTAssertNil(record.approvalSupport(sessionID: "session-b", transcriptHash: transcript))
            XCTAssertNil(record.approvalSupport(sessionID: "session-a", transcriptHash: Data(repeating: 0x52, count: 32)))
            XCTAssertNil(record.approvalSupport(sessionID: "session-a ", transcriptHash: transcript))
        }
        let missing: ClassicTransferPeerCapabilities? = nil
        XCTAssertNil(missing?.approvalSupport(sessionID: "session-a", transcriptHash: transcript))
    }

    func testInvalidIncarnationCannotCreateCapabilityEvidence() {
        for session in ["", "  ", String(repeating: "s", count: 1025)] {
            XCTAssertThrowsError(try ClassicTransferPeerCapabilities(acceptedCapabilities: ["classic_approval_v1"], sessionID: session, transcriptHash: transcript))
        }
        for length in [0, 31, 33] {
            XCTAssertThrowsError(try ClassicTransferPeerCapabilities(acceptedCapabilities: nil, sessionID: "session-a", transcriptHash: Data(repeating: 0, count: length)))
        }
    }
}
