import Foundation
import SQLite3
import XCTest
@testable import SkyBridgeMessagePersistence

final class SQLiteDeviceMessagingRepositoryTests: XCTestCase {
    private let retryPolicy = MessageDeliveryRetryPolicy(
        maximumRetryCount: 3,
        retryInterval: 1,
        backoffFactor: 2
    )

    func testOutgoingLifecycleCommitsMessageAndIntentTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        let pair = makeOutgoing()
        let staged = try await repository.stageOutgoing(
            message: pair.message,
            intent: pair.intent
        )
        XCTAssertEqual(staged.messages, [pair.message])
        XCTAssertEqual(staged.deliveryIntents, [pair.intent])

        let owner = UUID()
        let claim = try await repository.claim(
            messageID: pair.message.id,
            ownerToken: owner,
            now: pair.intent.createdAt
        )
        let claimIsCurrent = try await repository.isClaimCurrent(claim)
        XCTAssertTrue(claimIsCurrent)

        let submitted = try await repository.resolve(
            claim,
            disposition: .submitted(
                receiptDeadline: pair.intent.createdAt.addingTimeInterval(30)
            ),
            retryPolicy: retryPolicy,
            now: pair.intent.createdAt.addingTimeInterval(1)
        )
        XCTAssertEqual(submitted.messages.first?.deliveryState, .sent)
        XCTAssertEqual(submitted.deliveryIntents.first?.state, .awaitingReceipt)

        let delivered = try await repository.confirmAuthenticatedReceipt(
            AuthenticatedMessageReceipt(
                messageID: pair.message.id,
                deliveryAttemptID: owner,
                conversationFingerprint: pair.message.conversationFingerprint,
                receivedAt: pair.intent.createdAt.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(delivered.messages.first?.deliveryState, .delivered)
        XCTAssertTrue(delivered.deliveryIntents.isEmpty)
    }

    func testConversationFingerprintAcceptsExactly64LowercaseASCIIHexBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let fingerprint = String(repeating: "0123456789abcdef", count: 4)
        let pair = makeOutgoing(conversationFingerprint: fingerprint)

        let snapshot = try await repository.stageOutgoing(
            message: pair.message,
            intent: pair.intent
        )

        XCTAssertEqual(snapshot.messages.first?.conversationFingerprint, fingerprint)
    }

    func testConversationFingerprintRejectsUppercaseHexWithoutWriting() async throws {
        try await assertStageOutgoingRejectsFingerprint(
            String(repeating: "A", count: 64)
        )
    }

    func testConversationFingerprintRejectsNonHexWithoutWriting() async throws {
        try await assertStageOutgoingRejectsFingerprint(
            String(repeating: "g", count: 64)
        )
    }

    func testConversationFingerprintRejectsWrongByteLengthWithoutWriting() async throws {
        for fingerprint in [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
        ] {
            try await assertStageOutgoingRejectsFingerprint(fingerprint)
        }
    }

    func testInvalidConversationFingerprintCannotMutateReceiptOrClearState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let pair = makeOutgoing()
        _ = try await repository.stageOutgoing(message: pair.message, intent: pair.intent)
        let owner = UUID()
        _ = try await repository.claim(
            messageID: pair.message.id,
            ownerToken: owner,
            now: pair.intent.createdAt
        )
        let beforeInvalidWrites = try await repository.currentSnapshot()
        let invalidFingerprint = String(repeating: "B", count: 64)

        do {
            _ = try await repository.confirmAuthenticatedReceipt(
                AuthenticatedMessageReceipt(
                    messageID: pair.message.id,
                    deliveryAttemptID: owner,
                    conversationFingerprint: invalidFingerprint,
                    receivedAt: pair.intent.createdAt
                )
            )
            XCTFail("An invalid receipt fingerprint must not confirm delivery")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "invalid_receipt_conversation_fingerprint")
            )
        }

        do {
            _ = try await repository.clearConversation(invalidFingerprint)
            XCTFail("An invalid conversation fingerprint must not clear history")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "invalid_conversation_fingerprint")
            )
        }

        let afterInvalidWrites = try await repository.currentSnapshot()
        XCTAssertEqual(afterInvalidWrites, beforeInvalidWrites)
    }

    func testUppercaseQueueIDAliasFailsClosedWithoutChangingProjection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        let queueID = UUID()
        let canonical = makeOutgoing(queueID: queueID.uuidString.lowercased())
        let staged = try await repository.stageOutgoing(
            message: canonical.message,
            intent: canonical.intent
        )
        let alias = makeOutgoing(queueID: queueID.uuidString.uppercased())

        do {
            _ = try await repository.stageOutgoing(
                message: alias.message,
                intent: alias.intent
            )
            XCTFail("A case-only UUID alias must not become a second queue identity")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .invalidRecord(reasonCode: "noncanonical_queue_id"))
        }

        let snapshot = try await repository.currentSnapshot()
        XCTAssertEqual(snapshot, staged)
        XCTAssertFalse(snapshot.messages.contains { $0.id == alias.message.id })

        var projectedByCanonicalQueueID: [String: PersistedDeliveryIntent] = [:]
        for intent in snapshot.deliveryIntents {
            let parsedQueueID = try XCTUnwrap(UUID(uuidString: intent.queueID))
            let replaced = projectedByCanonicalQueueID.updateValue(
                intent,
                forKey: parsedQueueID.uuidString.lowercased()
            )
            XCTAssertNil(replaced, "Repository-valid intents must not alias in projections")
        }
        XCTAssertEqual(projectedByCanonicalQueueID, [canonical.intent.queueID: canonical.intent])
    }

    func testAuthenticatedReceiptCanWinRaceBeforeLocalSubmittedCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let pair = makeOutgoing()
        _ = try await repository.stageOutgoing(message: pair.message, intent: pair.intent)
        let owner = UUID()
        _ = try await repository.claim(
            messageID: pair.message.id,
            ownerToken: owner,
            now: pair.intent.createdAt
        )

        let receipt = AuthenticatedMessageReceipt(
            messageID: pair.message.id,
            deliveryAttemptID: owner,
            conversationFingerprint: pair.message.conversationFingerprint,
            receivedAt: pair.intent.createdAt.addingTimeInterval(1)
        )
        let delivered = try await repository.confirmAuthenticatedReceipt(receipt)
        XCTAssertEqual(delivered.messages.first?.deliveryState, .delivered)
        XCTAssertTrue(delivered.deliveryIntents.isEmpty)

        let duplicate = try await repository.confirmAuthenticatedReceipt(receipt)
        XCTAssertEqual(duplicate, delivered)

        do {
            _ = try await repository.confirmAuthenticatedReceipt(
                AuthenticatedMessageReceipt(
                    messageID: pair.message.id,
                    deliveryAttemptID: UUID(),
                    conversationFingerprint: pair.message.conversationFingerprint,
                    receivedAt: receipt.receivedAt
                )
            )
            XCTFail("A delivered row must not authenticate a different attempt owner")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .receiptBindingMismatch(pair.message.id))
        }
    }

    func testCompletedReceiptOwnerEvidenceSurvivesRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()
        let owner = UUID()
        let receipt = AuthenticatedMessageReceipt(
            messageID: pair.message.id,
            deliveryAttemptID: owner,
            conversationFingerprint: pair.message.conversationFingerprint,
            receivedAt: pair.intent.createdAt.addingTimeInterval(1)
        )

        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        _ = try await repository?.bootstrap()
        _ = try await repository?.stageOutgoing(message: pair.message, intent: pair.intent)
        _ = try await repository?.claim(
            messageID: pair.message.id,
            ownerToken: owner,
            now: pair.intent.createdAt
        )
        _ = try await repository?.confirmAuthenticatedReceipt(receipt)
        repository = nil

        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await reopened.bootstrap()
        let duplicate = try await reopened.confirmAuthenticatedReceipt(receipt)
        XCTAssertEqual(duplicate.messages.first?.deliveryState, .delivered)
        do {
            _ = try await reopened.confirmAuthenticatedReceipt(
                AuthenticatedMessageReceipt(
                    messageID: pair.message.id,
                    deliveryAttemptID: UUID(),
                    conversationFingerprint: pair.message.conversationFingerprint,
                    receivedAt: receipt.receivedAt
                )
            )
            XCTFail("Restart must not erase the completed attempt binding")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .receiptBindingMismatch(pair.message.id))
        }
    }

    func testAuthenticatedReceiptRejectsWrongAttemptAndFingerprint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let pair = makeOutgoing()
        _ = try await repository.stageOutgoing(message: pair.message, intent: pair.intent)
        let owner = UUID()
        let claim = try await repository.claim(
            messageID: pair.message.id,
            ownerToken: owner,
            now: pair.intent.createdAt
        )
        _ = try await repository.resolve(
            claim,
            disposition: .submitted(
                receiptDeadline: pair.intent.createdAt.addingTimeInterval(30)
            ),
            retryPolicy: retryPolicy,
            now: pair.intent.createdAt
        )

        for receipt in [
            AuthenticatedMessageReceipt(
                messageID: pair.message.id,
                deliveryAttemptID: UUID(),
                conversationFingerprint: pair.message.conversationFingerprint,
                receivedAt: pair.intent.createdAt
            ),
            AuthenticatedMessageReceipt(
                messageID: pair.message.id,
                deliveryAttemptID: owner,
                conversationFingerprint: String(repeating: "c", count: 64),
                receivedAt: pair.intent.createdAt
            )
        ] {
            do {
                _ = try await repository.confirmAuthenticatedReceipt(receipt)
                XCTFail("mismatched receipt must fail")
            } catch let error as DeviceMessagingRepositoryError {
                XCTAssertEqual(error, .receiptBindingMismatch(pair.message.id))
            }
        }
    }

    func testAwaitingReceiptSurvivesRestartAndRequeuesOnlyAfterDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 10_000)
        let pair = makeOutgoing(createdAt: createdAt)

        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        _ = try await repository?.bootstrap()
        _ = try await repository?.stageOutgoing(message: pair.message, intent: pair.intent)
        let optionalClaim = try await repository?.claim(
            messageID: pair.message.id,
            ownerToken: UUID(),
            now: createdAt
        )
        let claim = try XCTUnwrap(optionalClaim)
        let deadline = createdAt.addingTimeInterval(30)
        _ = try await repository?.resolve(
            claim,
            disposition: .submitted(receiptDeadline: deadline),
            retryPolicy: retryPolicy,
            now: createdAt
        )
        repository = nil

        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let snapshot = try await reopened.bootstrap()
        XCTAssertEqual(snapshot.deliveryIntents.first?.state, .awaitingReceipt)
        XCTAssertEqual(snapshot.messages.first?.deliveryState, .sent)

        let early = try await reopened.requeueExpiredReceipts(
            now: deadline.addingTimeInterval(-1),
            retryPolicy: retryPolicy
        )
        XCTAssertEqual(early.deliveryIntents.first?.state, .awaitingReceipt)

        let expired = try await reopened.requeueExpiredReceipts(
            now: deadline,
            retryPolicy: retryPolicy
        )
        XCTAssertEqual(expired.deliveryIntents.first?.state, .pending)
        XCTAssertEqual(expired.deliveryIntents.first?.retryCount, 1)
        XCTAssertEqual(expired.messages.first?.deliveryState, .pending)
    }

    func testInterruptedSendingClaimRecoversWithoutDroppingIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()

        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        _ = try await repository?.bootstrap()
        _ = try await repository?.stageOutgoing(message: pair.message, intent: pair.intent)
        _ = try await repository?.claim(
            messageID: pair.message.id,
            ownerToken: UUID(),
            now: pair.intent.createdAt
        )
        repository = nil

        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let recovered = try await reopened.bootstrap()
        XCTAssertEqual(recovered.deliveryIntents.first?.state, .pending)
        XCTAssertEqual(recovered.deliveryIntents.first?.claimGeneration, 1)

        let replacement = try await reopened.claimNextReady(
            targetDeviceID: pair.intent.targetDeviceID,
            ownerToken: UUID(),
            retryPolicy: retryPolicy,
            now: pair.intent.createdAt.addingTimeInterval(2)
        )
        XCTAssertEqual(replacement?.generation, 2)
    }

    func testSecondLiveRepositoryDoesNotRecoverFirstRepositoryClaim() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let second = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await first.bootstrap()
        let pair = makeOutgoing()
        _ = try await first.stageOutgoing(message: pair.message, intent: pair.intent)
        let claim = try await first.claim(
            messageID: pair.message.id,
            ownerToken: UUID(),
            now: pair.intent.createdAt
        )

        let secondSnapshot = try await second.bootstrap()
        XCTAssertEqual(secondSnapshot.deliveryIntents.first?.state, .sending)
        let claimIsCurrent = try await first.isClaimCurrent(claim)
        XCTAssertTrue(claimIsCurrent)
        do {
            _ = try await second.claim(
                messageID: pair.message.id,
                ownerToken: UUID(),
                now: pair.intent.createdAt
            )
            XCTFail("A second live repository must not steal an in-flight claim")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .staleClaim(pair.intent.queueID))
        }
    }

    func testExistingRepositoryRecoversClaimAfterOwningInstanceDeinitializes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var ownerRepository: SQLiteDeviceMessagingRepository? =
            SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let survivor = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await ownerRepository?.bootstrap()
        _ = try await survivor.bootstrap()
        let pair = makeOutgoing()
        _ = try await ownerRepository?.stageOutgoing(
            message: pair.message,
            intent: pair.intent
        )
        _ = try await ownerRepository?.claim(
            messageID: pair.message.id,
            ownerToken: UUID(),
            now: pair.intent.createdAt
        )
        ownerRepository = nil

        let replacement = try await survivor.claimNextReady(
            targetDeviceID: pair.intent.targetDeviceID,
            ownerToken: UUID(),
            retryPolicy: retryPolicy,
            now: pair.intent.createdAt.addingTimeInterval(1)
        )
        XCTAssertEqual(replacement?.intent.messageID, pair.message.id)
        XCTAssertEqual(replacement?.generation, 2)
    }

    func testSnapshotGenerationTracksWritesFromAnotherRepositoryInstance() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let writer = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let reader = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await writer.bootstrap()
        _ = try await reader.bootstrap()

        for offset in 1...20 {
            let incoming = PersistedMessageRecord(
                id: UUID(),
                conversationFingerprint: String(repeating: "b", count: 64),
                targetDeviceID: nil,
                direction: .incoming,
                text: "incoming-\(offset)",
                timestamp: Date(timeIntervalSince1970: Double(offset)),
                deliveryState: .delivered
            )
            _ = try await writer.recordIncoming(incoming)
            let snapshot = try await reader.currentSnapshot()
            XCTAssertEqual(snapshot.messages.count, offset)
            XCTAssertEqual(snapshot.generation, UInt64(offset))
        }
    }

    func testExpiredPendingIntentBecomesTerminalWithoutNetworkClaim() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 20_000)
        let pair = makeOutgoing(createdAt: createdAt, expiresAfter: 10)
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        _ = try await repository.stageOutgoing(message: pair.message, intent: pair.intent)

        let claim = try await repository.claimNextReady(
            targetDeviceID: pair.intent.targetDeviceID,
            ownerToken: UUID(),
            retryPolicy: retryPolicy,
            now: createdAt.addingTimeInterval(11)
        )
        XCTAssertNil(claim)

        let snapshot = try await repository.currentSnapshot()
        XCTAssertEqual(snapshot.messages.first?.deliveryState, .failed)
        XCTAssertEqual(snapshot.deliveryIntents.first?.state, .failed)
        XCTAssertEqual(snapshot.deliveryIntents.first?.failureCode, "message_expired")
    }

    func testReceiptTimeoutPastMessageLifetimeDoesNotReactivateIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 30_000)
        let pair = makeOutgoing(createdAt: createdAt, expiresAfter: 10)
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        _ = try await repository.stageOutgoing(message: pair.message, intent: pair.intent)
        let claim = try await repository.claim(
            messageID: pair.message.id,
            ownerToken: UUID(),
            now: createdAt
        )
        _ = try await repository.resolve(
            claim,
            disposition: .submitted(
                receiptDeadline: createdAt.addingTimeInterval(30)
            ),
            retryPolicy: retryPolicy,
            now: createdAt
        )

        let snapshot = try await repository.requeueExpiredReceipts(
            now: createdAt.addingTimeInterval(30),
            retryPolicy: retryPolicy
        )
        XCTAssertEqual(snapshot.messages.first?.deliveryState, .failed)
        XCTAssertEqual(snapshot.deliveryIntents.first?.state, .failed)
        XCTAssertEqual(snapshot.deliveryIntents.first?.failureCode, "message_expired")
    }

    func testCancellationKeepsHistoryTerminalAndRejectsInFlightDelivery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()

        let pending = makeOutgoing(
            targetDeviceID: "device-target-0001",
            queueID: UUID().uuidString.lowercased()
        )
        XCTAssertNotEqual(pending.intent.queueID, pending.message.id.uuidString.lowercased())
        _ = try await repository.stageOutgoing(message: pending.message, intent: pending.intent)
        let cancelled = try await repository.cancelDelivery(queueID: pending.intent.queueID)
        XCTAssertTrue(cancelled.messages.isEmpty)
        XCTAssertTrue(cancelled.deliveryIntents.isEmpty)

        let inFlight = makeOutgoing(targetDeviceID: "device-target-0002")
        _ = try await repository.stageOutgoing(message: inFlight.message, intent: inFlight.intent)
        let claim = try await repository.claim(
            messageID: inFlight.message.id,
            ownerToken: UUID(),
            now: inFlight.intent.createdAt
        )
        let beforeRejectedCancel = try await repository.currentSnapshot()
        do {
            _ = try await repository.cancelDelivery(queueID: inFlight.intent.queueID)
            XCTFail("An owner-bound delivery must not be erased")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "in_flight_delivery_prevents_cancel")
            )
        }
        let unchanged = try await repository.currentSnapshot()
        XCTAssertEqual(unchanged, beforeRejectedCancel)
        XCTAssertEqual(unchanged.deliveryIntents.first?.state, .sending)

        _ = try await repository.resolve(
            claim,
            disposition: .interrupted,
            retryPolicy: retryPolicy,
            now: inFlight.intent.createdAt
        )
        let finallyCancelled = try await repository.cancelDeliveries(
            targetDeviceID: inFlight.intent.targetDeviceID
        )
        XCTAssertTrue(finallyCancelled.deliveryIntents.isEmpty)
        XCTAssertTrue(finallyCancelled.messages.isEmpty)

        let awaiting = makeOutgoing(targetDeviceID: "device-target-0003")
        _ = try await repository.stageOutgoing(message: awaiting.message, intent: awaiting.intent)
        let receiptOwner = UUID()
        let awaitingClaim = try await repository.claim(
            messageID: awaiting.message.id,
            ownerToken: receiptOwner,
            now: awaiting.intent.createdAt
        )
        _ = try await repository.resolve(
            awaitingClaim,
            disposition: .submitted(
                receiptDeadline: awaiting.intent.createdAt.addingTimeInterval(30)
            ),
            retryPolicy: retryPolicy,
            now: awaiting.intent.createdAt
        )
        let beforeAwaitingCancel = try await repository.currentSnapshot()
        do {
            _ = try await repository.cancelDelivery(queueID: awaiting.intent.queueID)
            XCTFail("A receipt-waiting delivery must not be erased")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "in_flight_delivery_prevents_cancel")
            )
        }
        let afterAwaitingCancel = try await repository.currentSnapshot()
        XCTAssertEqual(afterAwaitingCancel, beforeAwaitingCancel)
        let delivered = try await repository.confirmAuthenticatedReceipt(
            AuthenticatedMessageReceipt(
                messageID: awaiting.message.id,
                deliveryAttemptID: receiptOwner,
                conversationFingerprint: awaiting.message.conversationFingerprint,
                receivedAt: awaiting.intent.createdAt.addingTimeInterval(2)
            )
        )
        XCTAssertEqual(delivered.messages, [
            PersistedMessageRecord(
                id: awaiting.message.id,
                conversationFingerprint: awaiting.message.conversationFingerprint,
                targetDeviceID: awaiting.message.targetDeviceID,
                direction: awaiting.message.direction,
                text: awaiting.message.text,
                timestamp: awaiting.message.timestamp,
                deliveryState: .delivered
            )
        ])
        XCTAssertTrue(delivered.deliveryIntents.isEmpty)
    }

    func testClearDeliveriesIsAtomicWhenAnyDeliveryIsInFlight() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let first = makeOutgoing(targetDeviceID: "device-target-0001")
        let second = makeOutgoing(targetDeviceID: "device-target-0002")
        let failed = makeOutgoing(targetDeviceID: "device-target-0003")
        _ = try await repository.stageOutgoing(message: first.message, intent: first.intent)
        _ = try await repository.stageOutgoing(message: second.message, intent: second.intent)
        _ = try await repository.stageOutgoing(message: failed.message, intent: failed.intent)
        let failedClaim = try await repository.claim(
            messageID: failed.message.id,
            ownerToken: UUID(),
            now: failed.intent.createdAt
        )
        _ = try await repository.resolve(
            failedClaim,
            disposition: .permanentFailure(failureCode: "transport_failure"),
            retryPolicy: retryPolicy,
            now: failed.intent.createdAt
        )
        let claim = try await repository.claim(
            messageID: second.message.id,
            ownerToken: UUID(),
            now: second.intent.createdAt
        )

        do {
            _ = try await repository.clearDeliveries()
            XCTFail("A bulk clear must fail before mutating any owner-bound delivery")
        } catch {
            XCTAssertEqual(
                error as? DeviceMessagingRepositoryError,
                .invalidRecord(reasonCode: "in_flight_delivery_prevents_cancel")
            )
        }
        let unchanged = try await repository.currentSnapshot()
        XCTAssertEqual(unchanged.deliveryIntents.count, 3)
        XCTAssertEqual(unchanged.messages.filter { $0.deliveryState == .pending }.count, 2)
        XCTAssertEqual(unchanged.messages.filter { $0.deliveryState == .failed }.count, 1)

        _ = try await repository.resolve(
            claim,
            disposition: .interrupted,
            retryPolicy: retryPolicy,
            now: second.intent.createdAt
        )
        let cleared = try await repository.clearDeliveries()
        XCTAssertTrue(cleared.deliveryIntents.isEmpty)
        XCTAssertEqual(cleared.messages, [
            PersistedMessageRecord(
                id: failed.message.id,
                conversationFingerprint: failed.message.conversationFingerprint,
                targetDeviceID: failed.message.targetDeviceID,
                direction: failed.message.direction,
                text: failed.message.text,
                timestamp: failed.message.timestamp,
                deliveryState: .failed
            )
        ])
    }

    func testClaimAndCancellationRaceHasExactlyOneWinner() async throws {
        enum RaceOutcome {
            case success
            case repositoryFailure(DeviceMessagingRepositoryError)
            case unexpectedFailure
        }

        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let pair = makeOutgoing(queueID: UUID().uuidString.lowercased())
        _ = try await repository.stageOutgoing(message: pair.message, intent: pair.intent)

        let claimTask = Task { () -> RaceOutcome in
            do {
                _ = try await repository.claim(
                    messageID: pair.message.id,
                    ownerToken: UUID(),
                    now: pair.intent.createdAt
                )
                return .success
            } catch let error as DeviceMessagingRepositoryError {
                return .repositoryFailure(error)
            } catch {
                return .unexpectedFailure
            }
        }
        let cancelTask = Task { () -> RaceOutcome in
            do {
                _ = try await repository.cancelDelivery(queueID: pair.intent.queueID)
                return .success
            } catch let error as DeviceMessagingRepositoryError {
                return .repositoryFailure(error)
            } catch {
                return .unexpectedFailure
            }
        }
        let claimOutcome = await claimTask.value
        let cancelOutcome = await cancelTask.value
        let successCount = [claimOutcome, cancelOutcome].filter {
            if case .success = $0 { return true }
            return false
        }.count
        XCTAssertEqual(successCount, 1)

        let snapshot = try await repository.currentSnapshot()
        switch (claimOutcome, cancelOutcome) {
        case (.success, .repositoryFailure(let error)):
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "in_flight_delivery_prevents_cancel")
            )
            XCTAssertEqual(snapshot.deliveryIntents.first?.state, .sending)
            XCTAssertEqual(snapshot.messages, [pair.message])
        case (.repositoryFailure(let error), .success):
            XCTAssertEqual(error, .messageNotFound(pair.message.id))
            XCTAssertTrue(snapshot.deliveryIntents.isEmpty)
            XCTAssertTrue(snapshot.messages.isEmpty)
        default:
            XCTFail("Race produced an unexpected outcome")
        }
    }

    func testRetryFailedDeliveriesDoesNotReviveExpiredIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let createdAt = Date(timeIntervalSince1970: 40_000)
        let retryable = makeOutgoing(
            createdAt: createdAt,
            expiresAfter: 100,
            targetDeviceID: "device-target-0001"
        )
        let expired = makeOutgoing(
            createdAt: createdAt,
            expiresAfter: 10,
            targetDeviceID: "device-target-0002"
        )
        var originalOwners: [UUID: UUID] = [:]
        for pair in [retryable, expired] {
            _ = try await repository.stageOutgoing(message: pair.message, intent: pair.intent)
            let owner = UUID()
            originalOwners[pair.message.id] = owner
            let claim = try await repository.claim(
                messageID: pair.message.id,
                ownerToken: owner,
                now: createdAt
            )
            _ = try await repository.resolve(
                claim,
                disposition: .permanentFailure(failureCode: "transport_failure"),
                retryPolicy: retryPolicy,
                now: createdAt
            )
        }

        let retried = try await repository.retryFailedDeliveries(
            now: createdAt.addingTimeInterval(20)
        )
        let intents = Dictionary(uniqueKeysWithValues: retried.deliveryIntents.map {
            ($0.messageID, $0)
        })
        XCTAssertEqual(intents[retryable.message.id]?.state, .pending)
        XCTAssertEqual(intents[retryable.message.id]?.retryCount, 0)
        XCTAssertNil(intents[retryable.message.id]?.failureCode)
        XCTAssertEqual(intents[retryable.message.id]?.claimGeneration, 1)
        XCTAssertEqual(intents[expired.message.id]?.state, .failed)
        XCTAssertEqual(intents[expired.message.id]?.failureCode, "transport_failure")
        let messages = Dictionary(uniqueKeysWithValues: retried.messages.map { ($0.id, $0) })
        XCTAssertEqual(messages[retryable.message.id]?.deliveryState, .pending)
        XCTAssertEqual(messages[expired.message.id]?.deliveryState, .failed)

        let replacementOwner = UUID()
        let replacementClaim = try await repository.claim(
            messageID: retryable.message.id,
            ownerToken: replacementOwner,
            now: createdAt.addingTimeInterval(21)
        )
        XCTAssertEqual(replacementClaim.generation, 2)
        do {
            _ = try await repository.confirmAuthenticatedReceipt(
                AuthenticatedMessageReceipt(
                    messageID: retryable.message.id,
                    deliveryAttemptID: try XCTUnwrap(originalOwners[retryable.message.id]),
                    conversationFingerprint: retryable.message.conversationFingerprint,
                    receivedAt: createdAt.addingTimeInterval(21)
                )
            )
            XCTFail("A receipt from the pre-retry owner must remain stale")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .receiptBindingMismatch(retryable.message.id))
        }
    }

    func testClearDeliveriesPreservesMigrationEvidenceAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()
        let source = LegacyMessageSource(
            sourceID: "legacy_queue",
            contentDigest: String(repeating: "d", count: 64)
        )
        let issue = MessageRepositoryMigrationIssue(
            sourceID: source.sourceID,
            messageID: pair.message.id,
            reasonCode: "migration_evidence"
        )
        let migration = LegacyMessageMigration(
            sources: [source],
            messages: [pair.message],
            deliveryIntents: [pair.intent],
            issues: [issue]
        )

        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        _ = try await repository?.bootstrap(legacyMigration: migration)
        let cleared = try await repository?.clearDeliveries()
        XCTAssertTrue(try XCTUnwrap(cleared).messages.isEmpty)
        XCTAssertEqual(cleared?.migrationIssues, [issue])
        repository = nil

        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let snapshot = try await reopened.bootstrap(legacyMigration: migration)
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.deliveryIntents.isEmpty)
        XCTAssertEqual(snapshot.migrationIssues, [issue])
    }

    func testInvalidMigrationRollsBackAndCanBeRetriedWithoutDeletingLegacyAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()
        let source = LegacyMessageSource(
            sourceID: "mac_conversations",
            contentDigest: String(repeating: "a", count: 64)
        )
        let conflictingIntent = PersistedDeliveryIntent(
            queueID: pair.intent.queueID,
            messageID: pair.intent.messageID,
            targetDeviceID: "different-device",
            messageType: pair.intent.messageType,
            priority: pair.intent.priority,
            payload: pair.intent.payload,
            createdAt: pair.intent.createdAt,
            expiresAt: pair.intent.expiresAt
        )

        let invalid = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        do {
            _ = try await invalid.bootstrap(legacyMigration: LegacyMessageMigration(
                sources: [source],
                messages: [pair.message],
                deliveryIntents: [conflictingIntent]
            ))
            XCTFail("conflicting migration must fail")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .legacySourceConflict(pair.intent.queueID))
        }

        let retry = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let imported = try await retry.bootstrap(legacyMigration: LegacyMessageMigration(
            sources: [source],
            messages: [pair.message],
            deliveryIntents: [pair.intent]
        ))
        XCTAssertEqual(imported.messages.count, 1)
        XCTAssertEqual(imported.deliveryIntents.count, 1)
    }

    func testMigrationRejectsMessageIntentStateMismatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()
        var deliveredMessage = pair.message
        deliveredMessage.deliveryState = .delivered
        let migration = LegacyMessageMigration(
            sources: [],
            messages: [deliveredMessage],
            deliveryIntents: [pair.intent]
        )

        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        do {
            _ = try await repository.bootstrap(legacyMigration: migration)
            XCTFail("A pending delivery intent must not reactivate delivered history")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .legacySourceConflict(pair.intent.queueID))
        }

        let retry = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let imported = try await retry.bootstrap(legacyMigration: LegacyMessageMigration(
            sources: [],
            messages: [pair.message],
            deliveryIntents: [pair.intent]
        ))
        XCTAssertEqual(imported.messages, [pair.message])
        XCTAssertEqual(imported.deliveryIntents, [pair.intent])
    }

    func testQuarantinedLegacySentHistorySurvivesMigrationAndRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let message = PersistedMessageRecord(
            id: UUID(),
            conversationFingerprint: String(repeating: "b", count: 64),
            targetDeviceID: nil,
            direction: .outgoing,
            text: "legacy-sent",
            timestamp: Date(timeIntervalSince1970: 55_000),
            deliveryState: .sent
        )
        let source = LegacyMessageSource(
            sourceID: "mac_conversations",
            contentDigest: String(repeating: "e", count: 64)
        )
        let issue = MessageRepositoryMigrationIssue(
            sourceID: source.sourceID,
            messageID: message.id,
            reasonCode: "legacy_sent_without_authenticated_receipt"
        )
        let migration = LegacyMessageMigration(
            sources: [source],
            messages: [message],
            deliveryIntents: [],
            issues: [issue]
        )

        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        let migrated = try await repository?.bootstrap(legacyMigration: migration)
        XCTAssertEqual(migrated?.messages, [message])
        XCTAssertTrue(migrated?.deliveryIntents.isEmpty == true)
        XCTAssertEqual(migrated?.migrationIssues, [issue])
        repository = nil

        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let restarted = try await reopened.bootstrap(legacyMigration: migration)
        XCTAssertEqual(restarted.messages, [message])
        XCTAssertTrue(restarted.deliveryIntents.isEmpty)
        XCTAssertEqual(restarted.migrationIssues, [issue])
    }

    func testTerminalLegacyHistoryWithoutTargetSurvivesRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let messages = [
            PersistedMessageRecord(
                id: UUID(),
                conversationFingerprint: String(repeating: "b", count: 64),
                targetDeviceID: nil,
                direction: .outgoing,
                text: "legacy-delivered",
                timestamp: Date(timeIntervalSince1970: 56_000),
                deliveryState: .delivered
            ),
            PersistedMessageRecord(
                id: UUID(),
                conversationFingerprint: String(repeating: "b", count: 64),
                targetDeviceID: nil,
                direction: .outgoing,
                text: "legacy-failed",
                timestamp: Date(timeIntervalSince1970: 56_001),
                deliveryState: .failed
            )
        ]
        let migration = LegacyMessageMigration(
            sources: [],
            messages: messages,
            deliveryIntents: []
        )

        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        let migrated = try await repository?.bootstrap(legacyMigration: migration)
        XCTAssertEqual(migrated?.messages, messages)
        XCTAssertTrue(migrated?.deliveryIntents.isEmpty == true)
        repository = nil

        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let restarted = try await reopened.bootstrap(legacyMigration: migration)
        XCTAssertEqual(restarted.messages, messages)
        XCTAssertTrue(restarted.deliveryIntents.isEmpty)
    }

    func testConcurrentRepositoryBootstrapsShareOneLegacyMigrationCommit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()
        let source = LegacyMessageSource(
            sourceID: "legacy_queue",
            contentDigest: String(repeating: "f", count: 64)
        )
        let migration = LegacyMessageMigration(
            sources: [source],
            messages: [pair.message],
            deliveryIntents: [pair.intent]
        )
        let first = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        let second = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)

        async let firstSnapshot = first.bootstrap(legacyMigration: migration)
        async let secondSnapshot = second.bootstrap(legacyMigration: migration)
        let snapshots = try await (firstSnapshot, secondSnapshot)

        XCTAssertEqual(snapshots.0.messages, [pair.message])
        XCTAssertEqual(snapshots.0.deliveryIntents, [pair.intent])
        XCTAssertEqual(snapshots.1, snapshots.0)
    }

    func testConversationRetentionNeverEvictsFailedRetryIntent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 60_000)
        let pair = makeOutgoing(createdAt: createdAt)
        var failedMessage = pair.message
        failedMessage.deliveryState = .failed
        var failedIntent = pair.intent
        failedIntent.state = .failed
        failedIntent.retryCount = 1
        failedIntent.lastAttemptAt = createdAt
        failedIntent.failureCode = "transport_failure"

        let retainedMessages = (1..<500).map { offset in
            PersistedMessageRecord(
                id: UUID(),
                conversationFingerprint: pair.message.conversationFingerprint,
                targetDeviceID: nil,
                direction: .incoming,
                text: "retained-\(offset)",
                timestamp: createdAt.addingTimeInterval(Double(offset)),
                deliveryState: .delivered
            )
        }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap(legacyMigration: LegacyMessageMigration(
            sources: [],
            messages: [failedMessage] + retainedMessages,
            deliveryIntents: [failedIntent]
        ))

        let newest = PersistedMessageRecord(
            id: UUID(),
            conversationFingerprint: pair.message.conversationFingerprint,
            targetDeviceID: nil,
            direction: .incoming,
            text: "newest",
            timestamp: createdAt.addingTimeInterval(500),
            deliveryState: .delivered
        )
        let snapshot = try await repository.recordIncoming(newest)

        XCTAssertEqual(snapshot.messages.count, 500)
        XCTAssertTrue(snapshot.messages.contains { $0.id == failedMessage.id })
        XCTAssertTrue(snapshot.messages.contains { $0.id == newest.id })
        XCTAssertEqual(snapshot.deliveryIntents, [failedIntent])
        XCTAssertFalse(snapshot.messages.contains { $0.id == retainedMessages[0].id })
    }

    func testAdmissionExpiresPendingRowsBeforeEnforcingActiveCapacity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let createdAt = Date(timeIntervalSince1970: 70_000)
        let expiredPairs = (0..<100).map { offset in
            makeOutgoing(
                createdAt: createdAt.addingTimeInterval(Double(offset) / 1_000),
                expiresAfter: 1,
                targetDeviceID: "capacity-device"
            )
        }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap(legacyMigration: LegacyMessageMigration(
            sources: [],
            messages: expiredPairs.map(\.message),
            deliveryIntents: expiredPairs.map(\.intent)
        ))

        let admitted = makeOutgoing(
            createdAt: createdAt.addingTimeInterval(2),
            targetDeviceID: "capacity-device"
        )
        let snapshot = try await repository.stageOutgoing(
            message: admitted.message,
            intent: admitted.intent
        )

        XCTAssertEqual(snapshot.deliveryIntents.filter { $0.state == .failed }.count, 100)
        XCTAssertEqual(snapshot.deliveryIntents.filter { $0.state == .pending }, [admitted.intent])
        XCTAssertEqual(snapshot.messages.filter { $0.deliveryState == .failed }.count, 100)
        XCTAssertEqual(snapshot.generation, 1)
    }

    func testBootstrapRejectsForeignKeyCorruption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()
        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        _ = try await repository?.bootstrap()
        _ = try await repository?.stageOutgoing(message: pair.message, intent: pair.intent)
        repository = nil

        try executeRawSQLite(
            at: fixture.databaseURL,
            sql: """
            PRAGMA foreign_keys = OFF;
            DELETE FROM messages
             WHERE message_id = '\(pair.message.id.uuidString.lowercased())';
            """
        )
        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        do {
            _ = try await reopened.bootstrap()
            XCTFail("An orphan delivery intent must fail closed")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(error, .invalidRecord(reasonCode: "foreign_key_violation"))
        }
    }

    func testBootstrapRejectsMessageIntentRelationshipCorruption() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pair = makeOutgoing()
        var repository: SQLiteDeviceMessagingRepository? = SQLiteDeviceMessagingRepository(
            databaseURL: fixture.databaseURL
        )
        _ = try await repository?.bootstrap()
        _ = try await repository?.stageOutgoing(message: pair.message, intent: pair.intent)
        repository = nil

        try executeRawSQLite(
            at: fixture.databaseURL,
            sql: """
            UPDATE messages
               SET delivery_state = 2
             WHERE message_id = '\(pair.message.id.uuidString.lowercased())';
            """
        )
        let reopened = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        do {
            _ = try await reopened.bootstrap()
            XCTFail("A delivered message must not retain a pending delivery intent")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "message_intent_relationship_violation")
            )
        }
    }

    func testLegacyReaderAcceptsOldPayloadAboveFourMiBWithoutRewritingIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacyURL = fixture.rootURL.appendingPathComponent("conversations.json")
        let value = [String(repeating: "x", count: 5 * 1_024 * 1_024)]
        let data = try JSONEncoder().encode(value)
        try data.write(to: legacyURL, options: .atomic)
        let original = try Data(contentsOf: legacyURL)

        let decoded: [String]? = try LegacyJSONMigrationReader.decode(
            from: legacyURL,
            containedIn: fixture.rootURL
        )
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(try Data(contentsOf: legacyURL), original)

        XCTAssertThrowsError(try LegacyJSONMigrationReader.decode(
            [String].self,
            from: legacyURL,
            containedIn: fixture.rootURL,
            maximumPayloadBytes: 4 * 1_024 * 1_024
        )) { error in
            guard case DeviceMessagingRepositoryError.legacyPayloadTooLarge = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLegacyReaderRejectsSymlinkAndHardlinkWithoutChangingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let targetURL = fixture.rootURL.appendingPathComponent("target.json")
        let symbolicLinkURL = fixture.rootURL.appendingPathComponent("symbolic.json")
        let hardLinkURL = fixture.rootURL.appendingPathComponent("hard.json")
        let canonicalBytes = try JSONEncoder().encode(["preserve-me"])
        try canonicalBytes.write(to: targetURL, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: symbolicLinkURL,
            withDestinationURL: targetURL
        )
        try FileManager.default.linkItem(at: targetURL, to: hardLinkURL)

        for unsafeURL in [symbolicLinkURL, hardLinkURL] {
            XCTAssertThrowsError(
                try LegacyJSONMigrationReader.decode(
                    [String].self,
                    from: unsafeURL,
                    containedIn: fixture.rootURL
                )
            ) { error in
                guard case DeviceMessagingRepositoryError.legacyPayloadUnreadable = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), canonicalBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: symbolicLinkURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardLinkURL.path))
    }

    func testLegacyArchiveRequiresSourceOrExactPriorArchive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceURL = fixture.rootURL.appendingPathComponent("legacy.json")
        let bytes = try JSONEncoder().encode(["preserve-me"])
        try bytes.write(to: sourceURL, options: .atomic)
        let digest = String(repeating: "a", count: 64)

        let archiveURL = try XCTUnwrap(LegacyJSONMigrationReader.archive(
            fileURL: sourceURL,
            containedIn: fixture.rootURL,
            contentDigest: digest,
            expectedData: bytes
        ))
        XCTAssertEqual(try Data(contentsOf: archiveURL), bytes)
        XCTAssertEqual(
            try LegacyJSONMigrationReader.archive(
                fileURL: sourceURL,
                containedIn: fixture.rootURL,
                contentDigest: digest,
                expectedData: bytes
            ),
            archiveURL
        )

        let vanishedURL = fixture.rootURL.appendingPathComponent("vanished.json")
        try bytes.write(to: vanishedURL, options: .atomic)
        try FileManager.default.removeItem(at: vanishedURL)
        XCTAssertThrowsError(try LegacyJSONMigrationReader.archive(
            fileURL: vanishedURL,
            containedIn: fixture.rootURL,
            contentDigest: String(repeating: "b", count: 64),
            expectedData: bytes
        )) { error in
            XCTAssertEqual(
                error as? DeviceMessagingRepositoryError,
                .legacySourceChanged(vanishedURL.lastPathComponent)
            )
        }
    }

    func testLegacyDataArchiveRejectsSymbolicLinkWithoutChangingExternalTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let externalRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-message-archive-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: externalRootURL) }
        try FileManager.default.createDirectory(
            at: externalRootURL,
            withIntermediateDirectories: false
        )
        let externalTargetURL = externalRootURL.appendingPathComponent("external.archive")
        let originalBytes = Data("external-target-must-not-change".utf8)
        try originalBytes.write(to: externalTargetURL)
        let archiveURL = fixture.rootURL.appendingPathComponent("legacy.archive")
        try FileManager.default.createSymbolicLink(
            at: archiveURL,
            withDestinationURL: externalTargetURL
        )

        XCTAssertThrowsError(try LegacyJSONMigrationReader.archive(
            data: Data("replacement".utf8),
            to: archiveURL,
            containedIn: fixture.rootURL,
            sourceLabel: "legacy"
        ))
        XCTAssertEqual(try Data(contentsOf: externalTargetURL), originalBytes)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: archiveURL.path),
            externalTargetURL.path
        )
    }

    func testLegacyDataArchiveRejectsSymbolicLinkParentWithoutExternalWrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let externalRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-message-archive-directory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: externalRootURL) }
        try FileManager.default.createDirectory(
            at: externalRootURL,
            withIntermediateDirectories: false
        )
        let symbolicParentURL = fixture.rootURL.appendingPathComponent("archive-directory")
        try FileManager.default.createSymbolicLink(
            at: symbolicParentURL,
            withDestinationURL: externalRootURL
        )
        let archiveURL = symbolicParentURL.appendingPathComponent("legacy.archive")
        let externalArchiveURL = externalRootURL.appendingPathComponent("legacy.archive")

        XCTAssertThrowsError(try LegacyJSONMigrationReader.archive(
            data: Data("must-not-escape-root".utf8),
            to: archiveURL,
            containedIn: fixture.rootURL,
            sourceLabel: "legacy"
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: externalArchiveURL.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: symbolicParentURL.path),
            externalRootURL.path
        )
    }

    func testLegacyDataArchiveRejectsOversizedExistingArchiveBeforeReadingIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archiveURL = fixture.rootURL.appendingPathComponent("legacy.archive")
        XCTAssertTrue(FileManager.default.createFile(atPath: archiveURL.path, contents: nil))
        let oversizedByteCount = LegacyJSONMigrationReader.maximumPayloadBytes + 1
        let archiveHandle = try FileHandle(forWritingTo: archiveURL)
        try archiveHandle.truncate(atOffset: UInt64(oversizedByteCount))
        try archiveHandle.close()

        XCTAssertThrowsError(try LegacyJSONMigrationReader.archive(
            data: Data("expected".utf8),
            to: archiveURL,
            containedIn: fixture.rootURL,
            sourceLabel: "legacy"
        )) { error in
            XCTAssertEqual(
                error as? DeviceMessagingRepositoryError,
                .legacyPayloadTooLarge(
                    actualBytes: oversizedByteCount,
                    maximumBytes: LegacyJSONMigrationReader.maximumPayloadBytes
                )
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: archiveURL.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, oversizedByteCount)
    }

    private func makeOutgoing(
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        expiresAfter: TimeInterval = 3_600,
        targetDeviceID: String = "device-target-0001",
        queueID: String? = nil,
        conversationFingerprint: String = String(repeating: "b", count: 64)
    ) -> (message: PersistedMessageRecord, intent: PersistedDeliveryIntent) {
        let id = UUID()
        let message = PersistedMessageRecord(
            id: id,
            conversationFingerprint: conversationFingerprint,
            targetDeviceID: targetDeviceID,
            direction: .outgoing,
            text: "hello",
            timestamp: createdAt,
            deliveryState: .pending
        )
        let intent = PersistedDeliveryIntent(
            queueID: queueID ?? id.uuidString.lowercased(),
            messageID: id,
            targetDeviceID: targetDeviceID,
            messageType: "text",
            priority: 1,
            payload: Data("payload".utf8),
            createdAt: createdAt,
            expiresAt: createdAt.addingTimeInterval(expiresAfter)
        )
        return (message, intent)
    }

    private func assertStageOutgoingRejectsFingerprint(
        _ fingerprint: String
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = SQLiteDeviceMessagingRepository(databaseURL: fixture.databaseURL)
        _ = try await repository.bootstrap()
        let pair = makeOutgoing(conversationFingerprint: fingerprint)

        do {
            _ = try await repository.stageOutgoing(
                message: pair.message,
                intent: pair.intent
            )
            XCTFail("Invalid conversation fingerprint must not be persisted")
        } catch let error as DeviceMessagingRepositoryError {
            XCTAssertEqual(
                error,
                .invalidRecord(reasonCode: "invalid_conversation_fingerprint")
            )
        }

        let snapshot = try await repository.currentSnapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
        XCTAssertTrue(snapshot.deliveryIntents.isEmpty)
        XCTAssertEqual(snapshot.generation, 0)
    }
}

private struct Fixture {
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-message-repository-\(UUID().uuidString)")
        databaseURL = rootURL.appendingPathComponent("messages.sqlite3")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private struct RawSQLiteTestFailure: Error {
    let operation: String
    let code: Int32
}

private func executeRawSQLite(at databaseURL: URL, sql: String) throws {
    var database: OpaquePointer?
    let openCode = sqlite3_open_v2(
        databaseURL.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    )
    guard openCode == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw RawSQLiteTestFailure(operation: "open", code: openCode)
    }
    defer { sqlite3_close_v2(database) }

    var errorMessage: UnsafeMutablePointer<CChar>?
    let executeCode = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    if let errorMessage { sqlite3_free(errorMessage) }
    guard executeCode == SQLITE_OK else {
        throw RawSQLiteTestFailure(operation: "execute", code: executeCode)
    }
}
