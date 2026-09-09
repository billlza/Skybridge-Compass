import CBoundSession
import CryptoKit
import Foundation
import SkyBridgeProtocolCore
import SkyBridgeQPeriaptRuntime
import XCTest

@testable import SkyBridgeCore

#if canImport(CQPeriapt)
    @available(macOS 14.0, iOS 17.0, *)
    final class BoundSessionFFIActorTests: XCTestCase {
        private struct SignedPolicyVector: Decodable {
            let policyTOML: String
            let verificationKey: String
            let signature: String

            private enum CodingKeys: String, CodingKey {
                case policyTOML = "policy_toml"
                case verificationKey = "verification_key"
                case signature
            }
        }

        private struct EndpointFixture {
            let recipientPublicKey: Data
            let recipientPrivateKey: SecureBytes
            let identity: CommittedLocalProtocolIdentitySnapshot
        }

        private struct HandshakeResult {
            let initiatorSession: BoundSessionSessionHandle
            let responderSession: BoundSessionSessionHandle
            let messageA: BoundSessionOutboundRecord
            let messageB: BoundSessionOutboundRecord
            let initiatorFinished: BoundSessionOutboundRecord
            let responderFinished: BoundSessionOutboundRecord
            let establishedInfo: BoundSessionEstablishedInfo
        }

        private enum HarnessError: Error {
            case expectedFailure(String)
            case noSuccessfulConcurrentTake
        }

        private actor MemoryTrustedStateStore: QPeriaptTrustedStateStore {
            enum Failure: Error {
                case load
                case compareAndSwap
            }

            private var states: [String: Data] = [:]
            private let loadFailure: Bool
            private let compareAndSwapFailure: Bool

            init(loadFailure: Bool = false, compareAndSwapFailure: Bool = false) {
                self.loadFailure = loadFailure
                self.compareAndSwapFailure = compareAndSwapFailure
            }

            func loadTrustedState(trustRootIdentifier: String) async throws -> Data? {
                guard !loadFailure else { throw Failure.load }
                return states[trustRootIdentifier]
            }

            func compareAndSwapTrustedState(
                expectedPreviousState: Data?,
                newState: Data,
                trustRootIdentifier: String
            ) async throws -> Bool {
                guard !compareAndSwapFailure else { throw Failure.compareAndSwap }
                guard states[trustRootIdentifier] == expectedPreviousState else { return false }
                states[trustRootIdentifier] = newState
                return true
            }
        }

        private actor DelayedIdentitySigner: SigningCallback {
            private let privateKey: Data
            private var entered = false
            private var released = false
            private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
            private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

            init(privateKey: Data) {
                self.privateKey = privateKey
            }

            func sign(data: Data) async throws -> Data {
                entered = true
                let waiters = enteredWaiters
                enteredWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters {
                    waiter.resume()
                }
                if !released {
                    await withCheckedContinuation { continuation in
                        releaseWaiters.append(continuation)
                    }
                }
                return try await PQCSignatureProvider(
                    algorithm: .mlDSA65,
                    backend: .oqs
                ).sign(data, key: .softwareKey(privateKey))
            }

            func waitUntilEntered() async {
                guard !entered else { return }
                await withCheckedContinuation { continuation in
                    enteredWaiters.append(continuation)
                }
            }

            func release() {
                guard !released else { return }
                released = true
                let waiters = releaseWaiters
                releaseWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }

        func testFrozenHeaderAndDynamicXCFrameworkSlicesAreFresh() throws {
            XCTAssertEqual(bs_ffi_abi_version_v1(), UInt32(BS_FFI_ABI_VERSION_V1))
            XCTAssertEqual(bs_ffi_capabilities_v2(), 0x0f)
            let compiledCapabilities =
                UInt64(BS_FFI_CAPABILITY_GRANT_EVIDENCE_V2)
                | UInt64(BS_FFI_CAPABILITY_GRANT_OUTBOUND_PEEK_V2)
                | UInt64(BS_FFI_CAPABILITY_TRUSTED_DELIVERY_CONFIRMATION_V2)
                | UInt64(BS_FFI_CAPABILITY_DERIVED_FILE_GRANT_INSTALL_V2)
            XCTAssertEqual(compiledCapabilities, 0x0f)

            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let headerPaths = [
                "Sources/CBoundSession/include/bound_session_ffi.h",
                "Sources/Vendor/boundsession.xcframework/macos-arm64/BoundSessionFFI.framework/Headers/bound_session_ffi.h",
                "Sources/Vendor/boundsession.xcframework/ios-arm64/BoundSessionFFI.framework/Headers/bound_session_ffi.h",
                "Sources/Vendor/boundsession.xcframework/ios-arm64-simulator/BoundSessionFFI.framework/Headers/bound_session_ffi.h",
            ]
            let expectedHeaderSHA256 = "45deb5e3e05798d6120c866b1fbddc66b26c37b55547f6630e6e94311f5bf4a0"

            for path in headerPaths {
                let bytes = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
                XCTAssertEqual(Data(SHA256.hash(data: bytes)).hexString, expectedHeaderSHA256, path)
            }
        }

        func testABIV2CStructLayoutsMatchTheAuthoritativeHeader() {
            XCTAssertEqual(MemoryLayout<BsFfiDerivedFileGrantAuthorizationV2>.size, 104)
            XCTAssertEqual(MemoryLayout<BsFfiDerivedFileGrantAuthorizationV2>.stride, 104)
            XCTAssertEqual(MemoryLayout<BsFfiDerivedFileGrantAuthorizationV2>.alignment, 8)
            XCTAssertEqual(
                MemoryLayout<BsFfiDerivedFileGrantAuthorizationV2>.offset(
                    of: \BsFfiDerivedFileGrantAuthorizationV2.authorization_lifetime_ticks
                ),
                16
            )
            XCTAssertEqual(MemoryLayout<BsFfiFileGrantInstallResultV2>.size, 72)
            XCTAssertEqual(MemoryLayout<BsFfiFileGrantInstallResultV2>.stride, 72)
            XCTAssertEqual(MemoryLayout<BsFfiFileGrantInstallResultV2>.alignment, 4)
            XCTAssertEqual(
                MemoryLayout<BsFfiFileGrantInstallResultV2>.offset(
                    of: \BsFfiFileGrantInstallResultV2.peer_session_id
                ),
                32
            )
            XCTAssertEqual(MemoryLayout<BsFfiFileGrantEvidenceV2>.size, 824)
            XCTAssertEqual(MemoryLayout<BsFfiFileGrantEvidenceV2>.stride, 824)
            XCTAssertEqual(MemoryLayout<BsFfiFileGrantEvidenceV2>.alignment, 8)
            XCTAssertEqual(
                MemoryLayout<BsFfiFileGrantEvidenceV2>.offset(
                    of: \BsFfiFileGrantEvidenceV2.durable_file_committer_identity_digest
                ),
                792
            )
            XCTAssertEqual(MemoryLayout<BsFfiGrantOutboundMetadataV2>.size, 160)
            XCTAssertEqual(MemoryLayout<BsFfiGrantOutboundMetadataV2>.stride, 160)
            XCTAssertEqual(MemoryLayout<BsFfiGrantOutboundMetadataV2>.alignment, 8)
            XCTAssertEqual(
                MemoryLayout<BsFfiGrantOutboundMetadataV2>.offset(
                    of: \BsFfiGrantOutboundMetadataV2.record_id
                ),
                32
            )
            XCTAssertEqual(MemoryLayout<BsFfiTrustedDeliveryConfirmationInputV2>.size, 88)
            XCTAssertEqual(MemoryLayout<BsFfiTrustedDeliveryConfirmationInputV2>.stride, 88)
            XCTAssertEqual(MemoryLayout<BsFfiTrustedDeliveryConfirmationInputV2>.alignment, 4)
            XCTAssertEqual(
                MemoryLayout<BsFfiTrustedDeliveryConfirmationInputV2>.offset(
                    of: \BsFfiTrustedDeliveryConfirmationInputV2.record_sha256
                ),
                40
            )
            XCTAssertEqual(MemoryLayout<BsFfiTrustedDeliveryConfirmationResultV2>.size, 16)
            XCTAssertEqual(MemoryLayout<BsFfiTrustedDeliveryConfirmationResultV2>.stride, 16)
            XCTAssertEqual(MemoryLayout<BsFfiTrustedDeliveryConfirmationResultV2>.alignment, 4)
            XCTAssertEqual(
                MemoryLayout<BsFfiTrustedDeliveryConfirmationResultV2>.offset(
                    of: \BsFfiTrustedDeliveryConfirmationResultV2.outcome
                ),
                8
            )
        }

        func testRealTwoEndpointBidirectionalHandshakeAndFileEffectLifecycle() async throws {
            let material = try loadPolicyMaterial()
            let (endpointA, endpointB) = try await makeEndpointPair(material: material)
            let outboxA = try makePrivateTestDirectory(label: "a")
            let outboxB = try makePrivateTestDirectory(label: "b")
            let actorA = try await BoundSessionFFIActor.create(
                configuration: try makeConfiguration(
                    material: material,
                    endpoint: endpointA,
                    peer: endpointB,
                    outbox: outboxA,
                    store: MemoryTrustedStateStore()
                )
            )
            let actorB = try await BoundSessionFFIActor.create(
                configuration: try makeConfiguration(
                    material: material,
                    endpoint: endpointB,
                    peer: endpointA,
                    outbox: outboxB,
                    store: MemoryTrustedStateStore()
                )
            )
            let ownerA = try await actorA.issueOwner(ownerBinding(seed: 0x11))
            let ownerB = try await actorB.issueOwner(ownerBinding(seed: 0x21))

            let forward = try await driveHandshake(
                initiator: actorA,
                initiatorOwner: ownerA,
                responder: actorB,
                responderOwner: ownerB,
                seed: 0x31,
                outboundProbe: .shortBuffer
            )
            let reverse = try await driveHandshake(
                initiator: actorB,
                initiatorOwner: ownerB,
                responder: actorA,
                responderOwner: ownerA,
                seed: 0x51,
                outboundProbe: .concurrentDoubleTake
            )

            XCTAssertNotEqual(forward.establishedInfo.peerSessionID, reverse.establishedInfo.peerSessionID)
            XCTAssertNotEqual(forward.establishedInfo.contextDigest, reverse.establishedInfo.contextDigest)
            XCTAssertNotEqual(forward.messageA.exactBytes, reverse.messageA.exactBytes)
            XCTAssertNotEqual(endpointA.recipientPublicKey, endpointB.recipientPublicKey)
            XCTAssertEqual(actorA.metadata.peerRecipientKeyDigest, actorB.metadata.localRecipientKeyDigest)
            XCTAssertEqual(actorB.metadata.peerRecipientKeyDigest, actorA.metadata.localRecipientKeyDigest)
            XCTAssertEqual(actorA.metadata.peerIdentityFingerprint, actorB.metadata.localIdentityFingerprint)
            XCTAssertEqual(actorB.metadata.peerIdentityFingerprint, actorA.metadata.localIdentityFingerprint)

            let secondOwnerA = try await actorA.issueOwner(ownerBinding(seed: 0x61))
            await assertBoundSessionError(.crossOwnerHandle) {
                _ = try await actorA.sessionState(owner: secondOwnerA, session: forward.initiatorSession)
            }
            await assertStaleHandle {
                _ = try await actorB.sessionState(owner: ownerB, session: forward.initiatorSession)
            }
            await assertStaleHandle {
                _ = try await actorA.sessionState(
                    owner: ownerA,
                    session: BoundSessionSessionHandle(identifier: UUID())
                )
            }
            try await actorA.destroyOwner(secondOwnerA)

            let senderGrant = try await actorA.installFileGrant(
                owner: ownerA,
                session: forward.initiatorSession,
                authorization: fileAuthorization(
                    seed: 0x71,
                    receiverScope: nil
                )
            )
            let receiverGrant = try await actorB.installFileGrant(
                owner: ownerB,
                session: forward.responderSession,
                authorization: fileAuthorization(
                    seed: 0x73,
                    receiverScope: Data(repeating: 0x74, count: 32)
                )
            )
            XCTAssertFalse(senderGrant.localReceivesFile)
            XCTAssertTrue(receiverGrant.localReceivesFile)
            XCTAssertEqual(senderGrant.peerSessionID, receiverGrant.peerSessionID)

            for endpoint in [
                (actorA, ownerA, senderGrant.grant),
                (actorB, ownerB, receiverGrant.grant),
            ] {
                try await endpoint.0.commitGrantAuthorization(owner: endpoint.1, grant: endpoint.2)
                try await endpoint.0.prepareLocalReady(owner: endpoint.1, grant: endpoint.2)
            }
            do {
                _ = try await actorA.fileGrantEvidenceProjectionV2(
                    owner: ownerA,
                    grant: senderGrant.grant
                )
                XCTFail("grant evidence must remain unavailable before bilateral enable")
            } catch BoundSessionFFIError.native(
                status: Int32(BS_FFI_ERR_PROTOCOL_V1),
                name: _
            ) {
                // Expected enabled-only Rust projection boundary.
            }
            let senderReady = try await takeGrantWithShortBufferProbe(
                actor: actorA,
                owner: ownerA,
                grant: senderGrant.grant
            )
            let senderReadyReplay = try await actorA.peekGrantOutbound(
                owner: ownerA,
                grant: senderGrant.grant
            )
            XCTAssertEqual(senderReadyReplay, senderReady)
            let receiverReady = try await actorB.peekGrantOutbound(
                owner: ownerB,
                grant: receiverGrant.grant
            )
            XCTAssertEqual(senderReady.kind, .grantReady)
            XCTAssertEqual(receiverReady.kind, .grantReady)
            let senderEnable = try await actorA.acceptPeerReadyAndEnable(
                owner: ownerA,
                grant: senderGrant.grant,
                ready: receiverReady
            )
            do {
                _ = try await actorA.confirmGrantOutboundDelivery(
                    owner: ownerA,
                    grant: senderGrant.grant,
                    remoteAcceptance: senderEnable.remoteAcceptance
                )
                XCTFail("acceptance for the peer's other Ready must not confirm this outbox")
            } catch BoundSessionFFIError.native(
                status: Int32(BS_FFI_ERR_PROTOCOL_V1),
                name: _
            ) {
                // Expected. Native mismatch does not consume the pending sender Ready.
            }
            let senderReadyAfterWrongConfirmation = try await actorA.peekGrantOutbound(
                owner: ownerA,
                grant: senderGrant.grant
            )
            XCTAssertEqual(senderReadyAfterWrongConfirmation, senderReady)
            let receiverEnable = try await actorB.acceptPeerReadyAndEnable(
                owner: ownerB,
                grant: receiverGrant.grant,
                ready: senderReady
            )
            XCTAssertEqual(senderEnable.outcome, .first)
            XCTAssertEqual(receiverEnable.outcome, .first)
            XCTAssertEqual(senderEnable.bilateralReadyDigest, receiverEnable.bilateralReadyDigest)
            let senderReadyConfirmation = try await actorA.confirmGrantOutboundDelivery(
                owner: ownerA,
                grant: senderGrant.grant,
                remoteAcceptance: receiverEnable.remoteAcceptance
            )
            XCTAssertEqual(senderReadyConfirmation, .firstConfirmed)
            let receiverReadyConfirmation = try await actorB.confirmGrantOutboundDelivery(
                owner: ownerB,
                grant: receiverGrant.grant,
                remoteAcceptance: senderEnable.remoteAcceptance
            )
            XCTAssertEqual(receiverReadyConfirmation, .firstConfirmed)
            let replayEnable = try await actorA.acceptPeerReadyAndEnable(
                owner: ownerA,
                grant: senderGrant.grant,
                ready: receiverReady
            )
            XCTAssertEqual(replayEnable.outcome, .exactReplay)
            XCTAssertEqual(replayEnable.remoteAcceptance.remoteOutcome, .exactReplay)
            let receiverReadyReplayConfirmation =
                try await actorB.confirmGrantOutboundDelivery(
                    owner: ownerB,
                    grant: receiverGrant.grant,
                    remoteAcceptance: replayEnable.remoteAcceptance
                )
            XCTAssertEqual(
                receiverReadyReplayConfirmation,
                .exactReplay
            )

            let senderProjection = try await actorA.fileGrantEvidenceProjectionV2(
                owner: ownerA,
                grant: senderGrant.grant
            )
            let receiverProjection = try await actorB.fileGrantEvidenceProjectionV2(
                owner: ownerB,
                grant: receiverGrant.grant
            )
            XCTAssertEqual(senderProjection.state, .enabled)
            XCTAssertEqual(receiverProjection.state, .enabled)
            XCTAssertFalse(senderProjection.localReceivesFile)
            XCTAssertNil(senderProjection.localDurableFileTargetScope)
            XCTAssertTrue(receiverProjection.localReceivesFile)
            XCTAssertEqual(
                receiverProjection.localDurableFileTargetScope,
                Data(repeating: 0x74, count: 32)
            )
            XCTAssertEqual(
                senderProjection.platformAuthorizationEvidenceDigest,
                Data(repeating: 0x71, count: 32)
            )
            XCTAssertEqual(
                receiverProjection.platformAuthorizationEvidenceDigest,
                Data(repeating: 0x73, count: 32)
            )

            let requestDigest = Data(repeating: 0x81, count: 32)
            let descriptor = try await actorA.createOutboundFileDescriptor(
                owner: ownerA,
                grant: senderGrant.grant,
                requestDigest: requestDigest
            )
            let operation = try await actorB.reserveInboundFileOperation(
                owner: ownerB,
                grant: receiverGrant.grant,
                descriptor: descriptor
            )
            await assertPendingResource {
                try await actorB.revokeGrant(owner: ownerB, grant: receiverGrant.grant)
            }
            await assertPendingResource {
                try await actorB.shutdown()
            }
            let permit = try await actorB.markFileMayHaveStarted(
                owner: ownerB,
                grant: receiverGrant.grant,
                operation: operation
            )
            await assertPendingResource {
                try await actorB.revokeGrant(owner: ownerB, grant: receiverGrant.grant)
            }
            let durableCommit = try await makeDurableFileCommit(seed: 0x82)
            let finalization = try await actorB.finalizeCommittedFileOperation(
                owner: ownerB,
                grant: receiverGrant.grant,
                permit: permit,
                durableCommit: durableCommit
            )
            guard case .receiptQueued = finalization else {
                throw HarnessError.expectedFailure("committed effect must durably queue its receipt")
            }
            let receipt = try await takeGrantWithShortBufferProbe(
                actor: actorB,
                owner: ownerB,
                grant: receiverGrant.grant
            )
            XCTAssertEqual(receipt.kind, .effectReceipt)
            let receiptReplay = try await actorB.peekGrantOutbound(
                owner: ownerB,
                grant: receiverGrant.grant
            )
            XCTAssertEqual(receiptReplay, receipt)
            let firstReceipt = try await actorA.acceptPeerReceipt(
                owner: ownerA,
                grant: senderGrant.grant,
                receipt: receipt
            )
            XCTAssertEqual(firstReceipt.outcome, .first)
            XCTAssertEqual(firstReceipt.remoteAcceptance.remoteOutcome, .first)
            let firstReceiptConfirmation = try await actorB.confirmGrantOutboundDelivery(
                owner: ownerB,
                grant: receiverGrant.grant,
                remoteAcceptance: firstReceipt.remoteAcceptance
            )
            XCTAssertEqual(firstReceiptConfirmation, .firstConfirmed)
            let replayReceipt = try await actorA.acceptPeerReceipt(
                owner: ownerA,
                grant: senderGrant.grant,
                receipt: receipt
            )
            XCTAssertEqual(replayReceipt.outcome, .exactReplay)
            let replayReceiptConfirmation = try await actorB.confirmGrantOutboundDelivery(
                owner: ownerB,
                grant: receiverGrant.grant,
                remoteAcceptance: replayReceipt.remoteAcceptance
            )
            XCTAssertEqual(replayReceiptConfirmation, .exactReplay)

            let journalA = try await actorA.evidenceJournalSnapshotV2()
            let journalB = try await actorB.evidenceJournalSnapshotV2()
            XCTAssertEqual(journalA.events.count, 6)
            XCTAssertEqual(journalB.events.count, 7)
            XCTAssertEqual(
                journalA.events.filter { $0.eventType == .receiptVerified }.count,
                1
            )
            XCTAssertEqual(
                journalB.events.filter { $0.eventType == .durableCommit }.count,
                1
            )
            XCTAssertEqual(
                journalB.events.filter { $0.eventType == .receiptIssued }.count,
                1
            )
            XCTAssertEqual(
                Set(journalA.events.map(\.direction)).count,
                2
            )
            XCTAssertEqual(
                Set(journalB.events.map(\.direction)).count,
                2
            )

            try await actorA.revokeGrant(owner: ownerA, grant: senderGrant.grant)
            try await actorB.revokeGrant(owner: ownerB, grant: receiverGrant.grant)
            try await actorB.abortSession(owner: ownerB, session: reverse.initiatorSession)
            try await actorA.abortSession(owner: ownerA, session: reverse.responderSession)

            let exportReadiness = await actorA.experimentEvidenceExportReadinessV2()
            XCTAssertEqual(
                exportReadiness,
                .blocked(
                    missingAuthoritativeProducers: BoundSessionExperimentEvidenceV2Gap.allCases
                )
            )
            try await actorA.destroyOwner(ownerA)
            try await actorB.destroyOwner(ownerB)
            try await actorA.shutdown()
            try await actorB.shutdown()

            XCTAssertEqual(try regularFileCount(in: outboxA), 1)
            XCTAssertEqual(try regularFileCount(in: outboxB), 1)
        }

        func testLateSignatureCompletionAfterCancellationAbortsNativeSession() async throws {
            let material = try loadPolicyMaterial()
            let (endpointA, endpointB) = try await makeEndpointPair(material: material)
            guard case .softwareKey(let privateIdentityKey) = endpointA.identity.keyHandle else {
                throw HarnessError.expectedFailure("test identity must use the OQS software slot")
            }
            let delayedSigner = DelayedIdentitySigner(privateKey: privateIdentityKey)
            let delayedIdentity = CommittedLocalProtocolIdentitySnapshot(
                algorithm: .mlDSA65,
                protection: .softwareKeychain,
                publicKey: endpointA.identity.publicKey,
                keyHandle: .callback(delayedSigner)
            )
            let delayedEndpoint = EndpointFixture(
                recipientPublicKey: endpointA.recipientPublicKey,
                recipientPrivateKey: endpointA.recipientPrivateKey,
                identity: delayedIdentity
            )
            let actor = try await BoundSessionFFIActor.create(
                configuration: try makeConfiguration(
                    material: material,
                    endpoint: delayedEndpoint,
                    peer: endpointB,
                    outbox: try makePrivateTestDirectory(label: "cancel"),
                    store: MemoryTrustedStateStore()
                )
            )
            let owner = try await actor.issueOwner(ownerBinding(seed: 0x41))
            let context = try makeContext(metadata: actor.metadata, seed: 0x42)
            let handshake = Task {
                try await actor.beginInitiator(owner: owner, canonicalContext: context)
            }
            await delayedSigner.waitUntilEntered()
            await assertPendingResource {
                try await actor.destroyOwner(owner)
            }
            handshake.cancel()
            await delayedSigner.release()
            do {
                _ = try await handshake.value
                XCTFail("cancelled signature completion must not publish a session")
            } catch is CancellationError {
                // Exact expected outcome: the wrapper aborts the paused native session.
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }

            try await actor.destroyOwner(owner)
            try await actor.shutdown()
        }

        func testIdentitySlotMismatchAndTrustedStateCommitFailureRemainFailClosed() async throws {
            let material = try loadPolicyMaterial()
            let (endpointA, endpointB) = try await makeEndpointPair(material: material)
            let reflectedPeer = EndpointFixture(
                recipientPublicKey: endpointB.recipientPublicKey,
                recipientPrivateKey: endpointB.recipientPrivateKey,
                identity: endpointA.identity
            )
            do {
                _ = try await BoundSessionFFIActor.create(
                    configuration: try makeConfiguration(
                        material: material,
                        endpoint: endpointA,
                        peer: reflectedPeer,
                        outbox: try makePrivateTestDirectory(label: "identity-mismatch"),
                        store: MemoryTrustedStateStore()
                    )
                )
                XCTFail("reflected identity slots must fail before native publication")
            } catch BoundSessionFFIError.identitySlotMismatch {
                // Expected.
            }

            let (retryA, retryB) = try await makeEndpointPair(material: material)
            do {
                _ = try await BoundSessionFFIActor.create(
                    configuration: try makeConfiguration(
                        material: material,
                        endpoint: retryA,
                        peer: retryB,
                        outbox: try makePrivateTestDirectory(label: "cas-failure"),
                        store: MemoryTrustedStateStore(compareAndSwapFailure: true)
                    )
                )
                XCTFail("trusted-state commit failure must not publish a service")
            } catch BoundSessionFFIError.trustedStatePersistenceFailed {
                // Expected; the wrapper synchronously destroys the unpublished service.
            }
        }

        private enum OutboundProbe {
            case shortBuffer
            case concurrentDoubleTake
        }

        private func driveHandshake(
            initiator: BoundSessionFFIActor,
            initiatorOwner: BoundSessionOwnerHandle,
            responder: BoundSessionFFIActor,
            responderOwner: BoundSessionOwnerHandle,
            seed: UInt8,
            outboundProbe: OutboundProbe
        ) async throws -> HandshakeResult {
            let context = try makeContext(metadata: initiator.metadata, seed: seed)
            let initiatorSession = try await initiator.beginInitiator(
                owner: initiatorOwner,
                canonicalContext: context
            )
            let messageA: BoundSessionOutboundRecord
            switch outboundProbe {
            case .shortBuffer:
                messageA = try await takeSessionWithShortBufferProbe(
                    actor: initiator,
                    owner: initiatorOwner,
                    session: initiatorSession
                )
            case .concurrentDoubleTake:
                messageA = try await takeSessionConcurrentlyOnce(
                    actor: initiator,
                    owner: initiatorOwner,
                    session: initiatorSession
                )
            }
            XCTAssertEqual(messageA.kind, .messageA)

            let responderSession = try await responder.acceptMessageA(
                owner: responderOwner,
                canonicalContext: context,
                messageA: messageA.exactBytes,
                responderNonce: Data(repeating: seed &+ 4, count: 32)
            )
            let messageB = try await responder.takeSessionOutbound(
                owner: responderOwner,
                session: responderSession
            )
            XCTAssertEqual(messageB.kind, .messageB)
            try await initiator.acceptMessageB(
                owner: initiatorOwner,
                session: initiatorSession,
                messageB: messageB.exactBytes
            )
            let initiatorFinished = try await initiator.takeSessionOutbound(
                owner: initiatorOwner,
                session: initiatorSession
            )
            XCTAssertEqual(initiatorFinished.kind, .finished)
            try await responder.acceptInitiatorFinished(
                owner: responderOwner,
                session: responderSession,
                finished: initiatorFinished.exactBytes
            )
            let responderFinished = try await responder.takeSessionOutbound(
                owner: responderOwner,
                session: responderSession
            )
            XCTAssertEqual(responderFinished.kind, .finished)
            try await initiator.acceptResponderFinished(
                owner: initiatorOwner,
                session: initiatorSession,
                finished: responderFinished.exactBytes
            )
            let initiatorState = try await initiator.sessionState(
                owner: initiatorOwner,
                session: initiatorSession
            )
            let responderState = try await responder.sessionState(
                owner: responderOwner,
                session: responderSession
            )
            XCTAssertEqual(initiatorState, .established)
            XCTAssertEqual(responderState, .established)
            let initiatorInfo = try await initiator.establishedInfo(
                owner: initiatorOwner,
                session: initiatorSession
            )
            let responderInfo = try await responder.establishedInfo(
                owner: responderOwner,
                session: responderSession
            )
            XCTAssertEqual(initiatorInfo, responderInfo)
            return HandshakeResult(
                initiatorSession: initiatorSession,
                responderSession: responderSession,
                messageA: messageA,
                messageB: messageB,
                initiatorFinished: initiatorFinished,
                responderFinished: responderFinished,
                establishedInfo: initiatorInfo
            )
        }

        private func takeSessionWithShortBufferProbe(
            actor: BoundSessionFFIActor,
            owner: BoundSessionOwnerHandle,
            session: BoundSessionSessionHandle
        ) async throws -> BoundSessionOutboundRecord {
            let required: Int
            do {
                _ = try await actor.takeSessionOutbound(owner: owner, session: session, capacity: 1)
                throw HarnessError.expectedFailure("one-byte session buffer unexpectedly consumed output")
            } catch BoundSessionFFIError.bufferTooSmall(let reported, _) {
                required = reported
            }
            return try await actor.takeSessionOutbound(
                owner: owner,
                session: session,
                capacity: required
            )
        }

        private func takeGrantWithShortBufferProbe(
            actor: BoundSessionFFIActor,
            owner: BoundSessionOwnerHandle,
            grant: BoundSessionGrantHandle
        ) async throws -> BoundSessionGrantOutboundRecordV2 {
            let required: Int
            do {
                _ = try await actor.peekGrantOutbound(owner: owner, grant: grant, capacity: 1)
                throw HarnessError.expectedFailure("one-byte grant buffer unexpectedly consumed output")
            } catch BoundSessionFFIError.bufferTooSmall(let reported, _) {
                required = reported
            }
            return try await actor.peekGrantOutbound(
                owner: owner,
                grant: grant,
                capacity: required
            )
        }

        private func takeSessionConcurrentlyOnce(
            actor: BoundSessionFFIActor,
            owner: BoundSessionOwnerHandle,
            session: BoundSessionSessionHandle
        ) async throws -> BoundSessionOutboundRecord {
            let first = Task {
                try await actor.takeSessionOutbound(owner: owner, session: session)
            }
            let second = Task {
                try await actor.takeSessionOutbound(owner: owner, session: session)
            }
            let results = [await first.result, await second.result]
            let successes = results.compactMap { result -> BoundSessionOutboundRecord? in
                guard case .success(let record) = result else { return nil }
                return record
            }
            XCTAssertEqual(successes.count, 1)
            guard let record = successes.first else { throw HarnessError.noSuccessfulConcurrentTake }
            let failures = results.compactMap { result -> BoundSessionFFIError? in
                guard case .failure(let error as BoundSessionFFIError) = result else { return nil }
                return error
            }
            XCTAssertEqual(failures.count, 1)
            return record
        }

        private func makeEndpointPair(
            material: QPeriaptSignedPolicyMaterial
        ) async throws -> (EndpointFixture, EndpointFixture) {
            let session = try await QPeriaptPolicyRuntime().resolveSession(
                material: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: MemoryTrustedStateStore()
            )
            let adapter = QPeriaptNativeAdapter(session: session)
            let recipientA = try await adapter.generateKeyPair()
            let recipientB = try await adapter.generateKeyPair()
            let signatureProvider = OQSPQCCryptoProvider()
            let identityA = try await signatureProvider.generateKeyPair(for: .signing)
            let identityB = try await signatureProvider.generateKeyPair(for: .signing)
            return (
                EndpointFixture(
                    recipientPublicKey: recipientA.publicKey,
                    recipientPrivateKey: recipientA.privateKey,
                    identity: CommittedLocalProtocolIdentitySnapshot(
                        algorithm: .mlDSA65,
                        protection: .softwareKeychain,
                        publicKey: identityA.publicKey.bytes,
                        keyHandle: .softwareKey(identityA.privateKey.bytes)
                    )
                ),
                EndpointFixture(
                    recipientPublicKey: recipientB.publicKey,
                    recipientPrivateKey: recipientB.privateKey,
                    identity: CommittedLocalProtocolIdentitySnapshot(
                        algorithm: .mlDSA65,
                        protection: .softwareKeychain,
                        publicKey: identityB.publicKey.bytes,
                        keyHandle: .softwareKey(identityB.privateKey.bytes)
                    )
                )
            )
        }

        private func makeConfiguration(
            material: QPeriaptSignedPolicyMaterial,
            endpoint: EndpointFixture,
            peer: EndpointFixture,
            outbox: URL,
            store: any QPeriaptTrustedStateStore
        ) throws -> BoundSessionFFIServiceConfiguration {
            BoundSessionFFIServiceConfiguration(
                policyMaterial: material,
                enrollmentMode: .explicitlyAuthorizedFirstEnrollment,
                trustedStateStore: store,
                localRecipientPublicKey: endpoint.recipientPublicKey,
                localRecipientPrivateKey: endpoint.recipientPrivateKey,
                peerRecipientPublicKey: peer.recipientPublicKey,
                localIdentity: endpoint.identity,
                peerIdentityVerificationKey: peer.identity.publicKey,
                finishedOutboxRoot: outbox,
                evidenceJournalRoot: try makePrivateTestDirectory(label: "journal"),
                maximumInFlightSessions: 8,
                maximumOwnerCapabilities: 8,
                maximumHandshakeLifetimeMilliseconds: 120_000
            )
        }

        private func makeContext(
            metadata: BoundSessionServiceMetadata,
            seed: UInt8
        ) throws -> Data {
            guard metadata.trustedPolicyState.count == 36 else {
                throw HarnessError.expectedFailure("trusted state must contain version and digest")
            }
            let purpose = try envelope(
                kind: 0x0001,
                fields: [
                    (1, Data([0x02])),
                    (2, Data([0x01])),
                    (3, Data(repeating: seed, count: 32)),
                    (4, bigEndian(UInt64(17) + UInt64(seed))),
                    (5, Data(repeating: seed &+ 1, count: 32)),
                ]
            )
            let purposeDigest = domainHash("bound-session/purpose/v1", purpose)
            let policyVersion = UInt64(
                metadata.trustedPolicyState.prefix(4).reduce(UInt32(0)) { value, byte in
                    (value << 8) | UInt32(byte)
                }
            )
            let policyDigest = Data(metadata.trustedPolicyState.dropFirst(4))
            let wireDecision = try envelope(
                kind: 0x0002,
                fields: [
                    (1, bigEndian(UInt16(1))),
                    (2, bigEndian(UInt16(1))),
                    (3, bigEndian(UInt16(0x0012))),
                    (4, bigEndian(UInt16(2))),
                    (5, bigEndian(UInt16(3))),
                    (6, metadata.policyRootFingerprint),
                    (7, bigEndian(policyVersion)),
                    (8, policyDigest),
                    (9, purposeDigest),
                    (10, metadata.localIdentityFingerprint),
                    (11, Data([0x01])),
                    (12, metadata.peerIdentityFingerprint),
                    (13, Data([0x02])),
                ]
            )
            let wireDecisionDigest = domainHash("bound-session/wire-decision/v1", wireDecision)
            return try envelope(
                kind: 0x0003,
                fields: [
                    (1, Data("bound-session/context/v1".utf8)),
                    (2, bigEndian(UInt16(1))),
                    (3, Data([0x01])),
                    (4, Data([0x02])),
                    (5, metadata.localIdentityFingerprint),
                    (6, metadata.peerIdentityFingerprint),
                    (7, metadata.peerRecipientKeyDigest),
                    (8, wireDecision),
                    (9, wireDecisionDigest),
                    (10, purpose),
                    (11, purposeDigest),
                    (12, Data(repeating: seed &+ 2, count: 32)),
                    (13, Data(repeating: seed &+ 3, count: 32)),
                ]
            )
        }

        private func envelope(kind: UInt16, fields: [(UInt16, Data)]) throws -> Data {
            guard !fields.isEmpty else { throw HarnessError.expectedFailure("empty canonical envelope") }
            var previous = UInt16(0)
            var body = Data()
            for (fieldID, value) in fields {
                guard fieldID > previous, let length = UInt32(exactly: value.count) else {
                    throw HarnessError.expectedFailure("non-canonical test envelope")
                }
                previous = fieldID
                body.append(bigEndian(fieldID))
                body.append(0x01)
                body.append(bigEndian(length))
                body.append(value)
            }
            guard let bodyLength = UInt32(exactly: body.count) else {
                throw HarnessError.expectedFailure("test envelope exceeds UInt32")
            }
            var encoded = Data("BSV1".utf8)
            encoded.append(bigEndian(UInt16(1)))
            encoded.append(bigEndian(kind))
            encoded.append(bigEndian(bodyLength))
            encoded.append(body)
            return encoded
        }

        private func bigEndian<Integer: FixedWidthInteger>(_ value: Integer) -> Data {
            var encoded = value.bigEndian
            return withUnsafeBytes(of: &encoded) { Data($0) }
        }

        private func domainHash(_ domain: String, _ bytes: Data) -> Data {
            var input = Data(domain.utf8)
            input.append(bytes)
            return Data(SHA256.hash(data: input))
        }

        private func ownerBinding(seed: UInt8) -> BoundSessionOwnerBinding {
            BoundSessionOwnerBinding(
                callerPrincipalDigest: Data(repeating: seed, count: 32),
                connectionGeneration: UInt64(seed),
                operationToken: Data(repeating: seed &+ 1, count: 32),
                driverIdentityDigest: Data(repeating: seed &+ 2, count: 32),
                arbiterLease: Data(repeating: seed &+ 3, count: 32),
                decisionEpoch: 7
            )
        }

        private func fileAuthorization(
            seed: UInt8,
            receiverScope: Data?
        ) -> BoundSessionFileGrantAuthorization {
            BoundSessionFileGrantAuthorization(
                platformAuthorizationEvidenceDigest: Data(repeating: seed, count: 32),
                authorizationLifetimeMilliseconds: 60_000,
                receiverTargetScopeDigest: receiverScope
            )
        }

        private func repeated(_ byte: UInt8) -> Data {
            Data(repeating: byte, count: 32)
        }

        private func makeDurableFileCommit(
            seed: UInt8
        ) async throws -> InboundFileTransferDurableCommitObservation {
            let root = try makePrivateTestDirectory(label: "durable-effect")
            let temporaryURL = root
                .appendingPathComponent("staging", isDirectory: true)
                .appendingPathComponent("payload.partial")
            let destination = root.appendingPathComponent("destination", isDirectory: true)
            let payload = Data((0..<4096).map { seed &+ UInt8($0 % 31) })
            let ioActor = InboundFileTransferIOActor(maxOpenTransfers: 1)
            let handle = try await ioActor.createTemporaryFile(
                at: temporaryURL,
                declaredFileSize: Int64(payload.count)
            )
            _ = try await ioActor.write(payload, atOffset: 0, using: handle)
            _ = try await ioActor.closeAndDigest(using: handle)
            let observation = try await ioActor.commitWithDurabilityObservation(
                using: handle,
                destinationDirectory: destination,
                fileName: "payload.bin"
            )
            try await ioActor.releaseCommittedFile(using: handle)
            return observation
        }

        private func loadPolicyMaterial() throws -> QPeriaptSignedPolicyMaterial {
            let fixtureURL = try XCTUnwrap(
                Bundle.module.url(forResource: "signed-policy-vectors", withExtension: "json")
            )
            let vector = try JSONDecoder().decode(
                SignedPolicyVector.self,
                from: Data(contentsOf: fixtureURL, options: [.mappedIfSafe])
            )
            let verificationKey = try XCTUnwrap(Data(hexString: vector.verificationKey))
            return QPeriaptSignedPolicyMaterial(
                policyTOML: Data(vector.policyTOML.utf8),
                detachedSignature: try XCTUnwrap(Data(hexString: vector.signature)),
                verificationKey: verificationKey,
                verificationKeySHA256Pin: Data(SHA256.hash(data: verificationKey)),
                trustRootIdentifier: "test/bound-session/apple-ffi"
            )
        }

        private func makePrivateTestDirectory(label: String) throws -> URL {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let directory = repositoryRoot.appendingPathComponent(".build", isDirectory: true).appendingPathComponent(
                "bound-session-ffi-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directory.path, 0o700) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            addTeardownBlock {
                try FileManager.default.removeItem(at: directory)
            }
            return directory.resolvingSymlinksInPath()
        }

        private func regularFileCount(in directory: URL) throws -> Int {
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).reduce(into: 0) { count, url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                if values.isRegularFile == true {
                    count += 1
                }
            }
        }

        private func assertBoundSessionError(
            _ expected: BoundSessionFFIError,
            operation: () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("expected BoundSession error \(expected)", file: file, line: line)
            } catch let error as BoundSessionFFIError {
                XCTAssertEqual(error, expected, file: file, line: line)
            } catch {
                XCTFail("unexpected error: \(error)", file: file, line: line)
            }
        }

        private func assertStaleHandle(
            operation: () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("expected stale handle rejection", file: file, line: line)
            } catch BoundSessionFFIError.staleSwiftHandle {
                // Expected.
            } catch {
                XCTFail("unexpected stale-handle error: \(error)", file: file, line: line)
            }
        }

        private func assertPendingResource(
            operation: () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("expected pending-resource rejection", file: file, line: line)
            } catch BoundSessionFFIError.pendingResources {
                // Expected.
            } catch {
                XCTFail("unexpected pending-resource error: \(error)", file: file, line: line)
            }
        }
    }
#endif
