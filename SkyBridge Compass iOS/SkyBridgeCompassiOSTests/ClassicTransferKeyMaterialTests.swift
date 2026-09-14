import XCTest
import CryptoKit
@testable import SkyBridgeCompass_iOS

@MainActor
final class ClassicTransferKeyMaterialTests: XCTestCase {
    private typealias Material = P2PConnectionManager.ClassicFileTransferKeyMaterial
    private let firstGeneration = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    private let secondGeneration = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
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
        let material = Material(sessionKeys: keys(), transferId: transferID, connectionGeneration: firstGeneration)
        // Independently computed RFC 5869 SHA-256 vector for the existing wire domain.
        XCTAssertEqual(hex(material.transferKey), "a7773a31e48bde134818a48abd0b6510fbd31418768106e2a9ad2b18f7443043")
        XCTAssertEqual(material.suite, .qperiaptABI2PolicyBound)
        XCTAssertEqual(material.role, .initiator)
    }

    func testOppositeEndpointsShareKeyAndReferenceWithoutSharingRoles() {
        let sender = Material(sessionKeys: keys(), transferId: transferID, connectionGeneration: firstGeneration)
        let receiver = Material(
            sessionKeys: keys(role: .responder, sendByte: 2, receiveByte: 1), transferId: transferID, connectionGeneration: firstGeneration
        )
        XCTAssertEqual(hex(sender.transferKey), hex(receiver.transferKey))
        XCTAssertEqual(sender.sessionReference, receiver.sessionReference)
        XCTAssertNotNil(sender.sessionReference)
        XCTAssertEqual(receiver.role, .responder)
    }

    func testTransferIdentitySeparatesKeysWithinOneAuthenticatedSession() {
        let first = Material(sessionKeys: keys(), transferId: transferID, connectionGeneration: firstGeneration)
        let second = Material(
            sessionKeys: keys(), transferId: "00000000-0000-0000-0000-000000000124", connectionGeneration: firstGeneration
        )
        XCTAssertEqual(first.sessionReference, second.sessionReference)
        XCTAssertNotEqual(hex(first.transferKey), hex(second.transferKey))
    }

    func testRekeyReplacesReferenceAndKeyTogether() {
        let first = Material(sessionKeys: keys(), transferId: transferID, connectionGeneration: firstGeneration)
        let replacement = Material(
            sessionKeys: keys(transcriptByte: 4, sendByte: 5, receiveByte: 6), transferId: transferID, connectionGeneration: firstGeneration
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
        let material = Material(sessionKeys: incomplete, transferId: transferID, connectionGeneration: firstGeneration)
        XCTAssertNil(material.sessionReference)
    }
    func testConsentCannotFollowAReplacementConnectionWithTheSameKeys() {
        let first = Material(sessionKeys: keys(), transferId: transferID, connectionGeneration: firstGeneration)
        let replacement = Material(sessionKeys: keys(), transferId: transferID, connectionGeneration: secondGeneration)
        XCTAssertFalse(first.matches(replacement))
        XCTAssertTrue(first.matches(first))
    }

    func testConsentCannotFollowARekeyOrDifferentTransfer() {
        let first = Material(sessionKeys: keys(), transferId: transferID, connectionGeneration: firstGeneration)
        let rekeyed = Material(
            sessionKeys: keys(transcriptByte: 4, sendByte: 5, receiveByte: 6),
            transferId: transferID, connectionGeneration: firstGeneration
        )
        let otherTransfer = Material(
            sessionKeys: keys(), transferId: "00000000-0000-0000-0000-000000000124",
            connectionGeneration: firstGeneration
        )
        XCTAssertFalse(first.matches(rekeyed))
        XCTAssertFalse(first.matches(otherTransfer))
    }

}
