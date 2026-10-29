import XCTest
@testable import SkyBridgeProtocolCore

final class RemoteDesktopStreamConfigurationTransactionTests: XCTestCase {
    func testIngressDistinguishesApplyDuplicateConflictAndMissingCorrelation() {
        let first = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        XCTAssertEqual(
            RemoteDesktopStreamConfigurationTransactionPolicy.ingressDecision(
                incoming: first,
                lastAccepted: nil,
                payloadMatchesLastAccepted: false
            ),
            .apply
        )
        XCTAssertEqual(
            RemoteDesktopStreamConfigurationTransactionPolicy.ingressDecision(
                incoming: first,
                lastAccepted: first,
                payloadMatchesLastAccepted: true
            ),
            .acknowledgeDuplicate
        )
        XCTAssertEqual(
            RemoteDesktopStreamConfigurationTransactionPolicy.ingressDecision(
                incoming: first,
                lastAccepted: first,
                payloadMatchesLastAccepted: false
            ),
            .rejectConflictingDuplicate
        )
        XCTAssertEqual(
            RemoteDesktopStreamConfigurationTransactionPolicy.ingressDecision(
                incoming: second,
                lastAccepted: first,
                payloadMatchesLastAccepted: false
            ),
            .apply
        )
        XCTAssertEqual(
            RemoteDesktopStreamConfigurationTransactionPolicy.ingressDecision(
                incoming: nil,
                lastAccepted: first,
                payloadMatchesLastAccepted: false
            ),
            .rejectMissingTransaction
        )
    }

    func testAcknowledgementRoundTripPreservesExactTransaction() throws {
        let transaction = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let acknowledgement = RemoteDesktopStreamConfigurationAcknowledgement(
            acceptedAt: 1_770_000_000,
            transaction: transaction,
            streamRefreshToken: 9,
            audioEndpointPresent: true,
            screenFrameTransport: "webrtc-native-main"
        )

        let encoded = try JSONEncoder().encode(acknowledgement)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteDesktopStreamConfigurationAcknowledgement.self,
                from: encoded
            ),
            acknowledgement
        )
    }

    func testLegacyConfigurationAcknowledgementDecodesWithoutPresentationCapability() throws {
        let legacy = Data(
            #"{"acceptedAt":1,"transaction":{"id":"33333333-3333-3333-3333-333333333333"},"audioEndpointPresent":false}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            RemoteDesktopStreamConfigurationAcknowledgement.self,
            from: legacy
        )

        XCTAssertNil(decoded.framePresentationAckVersion)
    }

    func testFramePresentationAcknowledgementBindsSequenceAndStreamTransaction() throws {
        let transaction = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        )
        let acknowledgement = RemoteDesktopFramePresentationAcknowledgement(
            sequenceNumber: 42,
            streamTransaction: transaction
        )

        let encoded = try JSONEncoder().encode(acknowledgement)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteDesktopFramePresentationAcknowledgement.self,
                from: encoded
            ),
            acknowledgement
        )
        XCTAssertEqual(
            acknowledgement.version,
            RemoteDesktopFramePresentationAcknowledgement.currentVersion
        )
    }
}
