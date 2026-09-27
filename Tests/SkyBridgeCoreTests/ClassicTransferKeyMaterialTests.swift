import XCTest
import CryptoKit
@testable import SkyBridgeCore

final class ClassicTransferKeyMaterialTests: XCTestCase {
    private let transferID = "00000000-0000-0000-0000-000000000123"

    private func keys(
        role: HandshakeRole = .initiator,
        transcriptByte: UInt8 = 3,
        sendByte: UInt8 = 1,
        receiveByte: UInt8 = 2
    ) -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: sendByte, count: 32),
            receiveKey: Data(repeating: receiveByte, count: 32),
            negotiatedSuite: .qperiaptABI2PolicyBound,
            role: role,
            transcriptHash: Data(repeating: transcriptByte, count: 32)
        )
    }

    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    func testMaterialPreservesExistingWireKeyDerivation() {
        let material = ClassicTransferKeyMaterial(sessionKeys: keys(), transferId: transferID)
        // Independently computed RFC 5869 SHA-256 vector for the existing wire domain.
        XCTAssertEqual(hex(material.transferKey), "a7773a31e48bde134818a48abd0b6510fbd31418768106e2a9ad2b18f7443043")
        XCTAssertEqual(material.negotiatedSuite, .qperiaptABI2PolicyBound)
        XCTAssertEqual(material.role, .initiator)
    }

    func testOppositeEndpointsShareKeyAndReferenceWithoutSharingRoles() {
        let sender = ClassicTransferKeyMaterial(sessionKeys: keys(), transferId: transferID)
        let receiver = ClassicTransferKeyMaterial(
            sessionKeys: keys(role: .responder, sendByte: 2, receiveByte: 1), transferId: transferID
        )
        XCTAssertEqual(hex(sender.transferKey), hex(receiver.transferKey))
        XCTAssertEqual(sender.sessionReference, receiver.sessionReference)
        XCTAssertNotNil(sender.sessionReference)
        XCTAssertEqual(receiver.role, .responder)
    }

    func testTransferIdentitySeparatesKeysWithinOneAuthenticatedSession() {
        let first = ClassicTransferKeyMaterial(sessionKeys: keys(), transferId: transferID)
        let second = ClassicTransferKeyMaterial(
            sessionKeys: keys(), transferId: "00000000-0000-0000-0000-000000000124"
        )
        XCTAssertEqual(first.sessionReference, second.sessionReference)
        XCTAssertNotEqual(hex(first.transferKey), hex(second.transferKey))
    }

    func testRekeyReplacesReferenceAndKeyTogether() {
        let first = ClassicTransferKeyMaterial(sessionKeys: keys(), transferId: transferID)
        let replacement = ClassicTransferKeyMaterial(
            sessionKeys: keys(transcriptByte: 4, sendByte: 5, receiveByte: 6), transferId: transferID
        )
        XCTAssertNotEqual(first.sessionReference, replacement.sessionReference)
        XCTAssertNotEqual(hex(first.transferKey), hex(replacement.transferKey))
    }

    func testMissingTranscriptCannotProduceAnEvidenceReference() {
        let incomplete = SessionKeys(
            sendKey: Data(repeating: 1, count: 32), receiveKey: Data(repeating: 2, count: 32),
            negotiatedSuite: .qperiaptABI2PolicyBound, role: .initiator,
            transcriptHash: Data(), sessionId: "existing-session"
        )
        let material = ClassicTransferKeyMaterial(sessionKeys: incomplete, transferId: transferID)
        XCTAssertNil(material.sessionReference)
    }
}
