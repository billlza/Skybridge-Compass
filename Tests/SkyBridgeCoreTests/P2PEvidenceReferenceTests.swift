import XCTest
import SkyBridgeProtocolCore

final class P2PEvidenceReferenceTests: XCTestCase {
    func testReferencesAreStableDomainSeparatedAndRedacted() throws {
        let transactionID = try XCTUnwrap(UUID(uuidString: "7f167607-8d3f-4e30-89ee-98822242e810"))
        let hash = String(repeating: "ab", count: 32)

        let transaction = P2PEvidenceReference.transaction(transactionID)
        XCTAssertEqual(transaction, P2PEvidenceReference.transaction(transactionID))
        XCTAssertEqual(transaction, "ev1:b276fe81299ce0535f8a8e1dd49796c4")
        XCTAssertTrue(transaction.hasPrefix("ev1:"))
        XCTAssertEqual(transaction.count, 36)
        XCTAssertFalse(transaction.contains(transactionID.uuidString.lowercased()))

        let request = try XCTUnwrap(P2PEvidenceReference.requestHash(hash))
        let payload = try XCTUnwrap(P2PEvidenceReference.payloadHash(hash))
        let session = try XCTUnwrap(P2PEvidenceReference.session("session-123"))
        let incarnation = try XCTUnwrap(
            P2PEvidenceReference.sessionIncarnation(
                sessionID: "session-123",
                transcriptHash: Data(repeating: 0x44, count: 32)
            )
        )
        XCTAssertEqual(request, "ev1:b2fa4aac84ccf9081c12854a4f1efdd2")
        XCTAssertEqual(payload, "ev1:fe58abae130e9cb3c1a7e013f459bac2")
        XCTAssertNotEqual(request, payload)
        XCTAssertFalse(request.contains(hash))
        XCTAssertFalse(payload.contains(hash))
        XCTAssertTrue(session.hasPrefix("ev1:"))
        XCTAssertFalse(session.contains("session-123"))
        XCTAssertEqual(incarnation, "ev1:304c00d3fa7d41277c07ebcd5e64586c")
        XCTAssertNotEqual(session, incarnation)
        XCTAssertTrue(P2PEvidenceReference.isValid(incarnation))
        XCTAssertFalse(P2PEvidenceReference.isValid("ev1:NOT-CANONICAL"))
    }

    func testHashReferencesRejectMalformedInput() {
        XCTAssertNil(P2PEvidenceReference.requestHash(""))
        XCTAssertNil(P2PEvidenceReference.requestHash(String(repeating: "a", count: 63)))
        XCTAssertNil(P2PEvidenceReference.requestHash(String(repeating: "g", count: 64)))
        XCTAssertNil(P2PEvidenceReference.payloadHash("not-a-hash"))
        XCTAssertNil(P2PEvidenceReference.session("   "))
        XCTAssertNil(P2PEvidenceReference.session(String(repeating: "x", count: 1_025)))
        XCTAssertNil(
            P2PEvidenceReference.sessionIncarnation(
                sessionID: "session-123",
                transcriptHash: Data(repeating: 0x44, count: 31)
            )
        )
        XCTAssertNotEqual(
            P2PEvidenceReference.sessionIncarnation(
                sessionID: "session-123",
                transcriptHash: Data(repeating: 0x44, count: 32)
            ),
            P2PEvidenceReference.sessionIncarnation(
                sessionID: "session-123",
                transcriptHash: Data(repeating: 0x45, count: 32)
            )
        )
    }
}
