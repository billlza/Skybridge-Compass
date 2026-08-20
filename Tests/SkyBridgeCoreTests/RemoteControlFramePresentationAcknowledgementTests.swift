import XCTest
@testable import SkyBridgeCore
@testable import SkyBridgeProtocolCore

final class RemoteControlFramePresentationAcknowledgementTests: XCTestCase {
    func testTrackerAcceptsOnlyExactNegotiatedTransactionAndSequence() {
        let transaction = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        )
        let replacement = RemoteDesktopStreamConfigurationTransaction(
            id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        )
        var tracker = RemoteControlFramePresentationAcknowledgementTracker()
        tracker.begin(
            transaction: transaction,
            negotiatedVersion: RemoteDesktopFramePresentationAcknowledgement.currentVersion
        )
        _ = tracker.recordSentFrame(
            metadata(sequence: 9, transaction: transaction)
        )

        XCTAssertNil(
            tracker.matchingFrame(
                for: .init(sequenceNumber: 8, streamTransaction: transaction)
            )
        )
        XCTAssertNil(
            tracker.matchingFrame(
                for: .init(sequenceNumber: 9, streamTransaction: replacement)
            )
        )
        XCTAssertEqual(
            tracker.matchingFrame(
                for: .init(sequenceNumber: 9, streamTransaction: transaction)
            )?.bytes,
            4_096
        )
    }

    func testTrackerIsBoundedAndReplacementClearsStaleFrames() {
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        let replacement = RemoteDesktopStreamConfigurationTransaction()
        var tracker = RemoteControlFramePresentationAcknowledgementTracker()
        tracker.begin(
            transaction: transaction,
            negotiatedVersion: RemoteDesktopFramePresentationAcknowledgement.currentVersion
        )
        XCTAssertNil(
            tracker.recordAcknowledgement(
                for: .init(
                    version: 2,
                    sequenceNumber: 1,
                    streamTransaction: transaction
                )
            )
        )
        XCTAssertNil(
            tracker.recordAcknowledgement(
                for: .init(
                    sequenceNumber: 1,
                    streamTransaction: .init()
                )
            )
        )
        XCTAssertEqual(tracker.earlyAcknowledgementCount, 0)
        let newestSequence =
            RemoteControlFramePresentationAcknowledgementTracker.maximumPendingFrameCount + 4
        for sequence in 1...newestSequence {
            _ = tracker.recordSentFrame(
                metadata(sequence: UInt64(sequence), transaction: transaction)
            )
        }

        XCTAssertEqual(
            tracker.pendingFrameCount,
            RemoteControlFramePresentationAcknowledgementTracker.maximumPendingFrameCount
        )
        XCTAssertNil(
            tracker.matchingFrame(
                for: .init(sequenceNumber: 1, streamTransaction: transaction)
            )
        )
        XCTAssertNotNil(
            tracker.matchingFrame(
                for: .init(
                    sequenceNumber: UInt64(newestSequence),
                    streamTransaction: transaction
                )
            )
        )

        tracker.begin(
            transaction: replacement,
            negotiatedVersion: RemoteDesktopFramePresentationAcknowledgement.currentVersion
        )
        XCTAssertEqual(tracker.pendingFrameCount, 0)
        XCTAssertNil(
            tracker.matchingFrame(
                for: .init(
                    sequenceNumber: UInt64(newestSequence),
                    streamTransaction: transaction
                )
            )
        )
    }

    func testLegacyNegotiationDoesNotRetainPresentationState() {
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        var tracker = RemoteControlFramePresentationAcknowledgementTracker()
        tracker.begin(transaction: transaction, negotiatedVersion: nil)
        _ = tracker.recordSentFrame(metadata(sequence: 1, transaction: transaction))

        XCTAssertEqual(tracker.pendingFrameCount, 0)
        XCTAssertEqual(tracker.earlyAcknowledgementCount, 0)
    }

    func testCompletionIsSingleUse() {
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        let acknowledgement = RemoteDesktopFramePresentationAcknowledgement(
            sequenceNumber: 1,
            streamTransaction: transaction
        )
        var tracker = RemoteControlFramePresentationAcknowledgementTracker()
        tracker.begin(
            transaction: transaction,
            negotiatedVersion: RemoteDesktopFramePresentationAcknowledgement.currentVersion
        )
        _ = tracker.recordSentFrame(metadata(sequence: 1, transaction: transaction))

        XCTAssertTrue(tracker.complete(acknowledgement: acknowledgement))
        XCTAssertFalse(tracker.complete(acknowledgement: acknowledgement))
        XCTAssertEqual(tracker.pendingFrameCount, 0)
    }

    func testEarlyAcknowledgementJoinsLaterContentProcessedFrameWithoutTimingAssumptions() {
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        let acknowledgement = RemoteDesktopFramePresentationAcknowledgement(
            sequenceNumber: 7,
            streamTransaction: transaction
        )
        var tracker = RemoteControlFramePresentationAcknowledgementTracker()
        tracker.begin(
            transaction: transaction,
            negotiatedVersion: RemoteDesktopFramePresentationAcknowledgement.currentVersion
        )

        XCTAssertNil(tracker.recordAcknowledgement(for: acknowledgement))
        XCTAssertEqual(tracker.earlyAcknowledgementCount, 1)
        XCTAssertEqual(
            tracker.recordSentFrame(metadata(sequence: 7, transaction: transaction)),
            acknowledgement
        )
        XCTAssertEqual(tracker.earlyAcknowledgementCount, 0)
        XCTAssertTrue(tracker.complete(acknowledgement: acknowledgement))
    }

    func testEarlyAcknowledgementsAreBoundedAndResetWithOwnerTransaction() {
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        var tracker = RemoteControlFramePresentationAcknowledgementTracker()
        tracker.begin(
            transaction: transaction,
            negotiatedVersion: RemoteDesktopFramePresentationAcknowledgement.currentVersion
        )
        let newestSequence =
            RemoteControlFramePresentationAcknowledgementTracker.maximumPendingFrameCount + 4
        for sequence in 1...newestSequence {
            XCTAssertNil(
                tracker.recordAcknowledgement(
                    for: .init(
                        sequenceNumber: UInt64(sequence),
                        streamTransaction: transaction
                    )
                )
            )
        }

        XCTAssertEqual(
            tracker.earlyAcknowledgementCount,
            RemoteControlFramePresentationAcknowledgementTracker.maximumPendingFrameCount
        )
        tracker.reset()
        XCTAssertEqual(tracker.earlyAcknowledgementCount, 0)
        XCTAssertNil(
            tracker.recordSentFrame(
                metadata(
                    sequence: UInt64(newestSequence),
                    transaction: transaction
                )
            )
        )
    }

    private func metadata(
        sequence: UInt64,
        transaction: RemoteDesktopStreamConfigurationTransaction
    ) -> RemoteControlSentFrameMetadata {
        RemoteControlSentFrameMetadata(
            sequenceNumber: sequence,
            streamTransaction: transaction,
            bytes: 4_096,
            width: 1_280,
            height: 720
        )
    }
}
