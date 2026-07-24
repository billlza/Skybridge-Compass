import XCTest
import Network
import CryptoKit
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class FileTransferManagerSecurityTests: XCTestCase {
    func testCleanupCancelsQueuedSlotWaitersWithoutCorruptingInFlightAccounting() async throws {
        let manager = FileTransferManager()
        manager.updateSettings(maxConcurrentTransfers: 1)
        let originalGeneration = try await manager.testingAcquireTransferSlot()
        XCTAssertEqual(manager.testingTransferSlotCounts.inFlight, 1)

        let waiter = Task { @MainActor () -> Error? in
            do {
                _ = try await manager.testingAcquireTransferSlot()
                return nil
            } catch {
                return error
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while manager.testingTransferSlotCounts.pending == 0,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertEqual(manager.testingTransferSlotCounts.pending, 1)

        manager.cleanup()

        guard let waiterError = await waiter.value as? FileTransferError,
              case .transferCancelled = waiterError else {
            return XCTFail("Queued waiter must finish with typed cancellation")
        }
        XCTAssertEqual(manager.testingTransferSlotCounts.inFlight, 1)
        XCTAssertEqual(manager.testingTransferSlotCounts.pending, 0)
        XCTAssertThrowsError(try manager.testingEnsureCurrentLifecycle(originalGeneration))

        manager.testingReleaseTransferSlot()
        XCTAssertEqual(manager.testingTransferSlotCounts.inFlight, 0)

        try await manager.start()
        let restartedGeneration = manager.testingLifecycleGeneration
        _ = try await manager.testingAcquireTransferSlot()
        manager.testingReleaseTransferSlot()

        try await manager.start()
        XCTAssertEqual(manager.testingLifecycleGeneration, restartedGeneration)
    }

    func testNetworkServiceDisconnectsOnlyTheExactOwnedConnection() throws {
        let service = FileTransferNetworkService()
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: 9))
        let first = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let second = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        service.activeConnections = ["first": first, "second": second]

        service.disconnect(first)

        XCTAssertEqual(service.activeConnections.count, 1)
        XCTAssertTrue(service.activeConnections["second"] === second)
        second.cancel()
    }

    func testStopWaitsForRegisteredClassicOperationsToFinish() async {
        let manager = FileTransferManager()
        let operationID = manager.testingBeginClassicOperation()
        let completion = FileTransferStopCompletionProbe()
        let stopTask = Task { @MainActor in
            await manager.stop()
            await completion.markCompleted()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while manager.testingAcceptsNewTransfers,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(manager.testingAcceptsNewTransfers)
        XCTAssertEqual(manager.testingActiveClassicOperationCount, 1)
        let completedBeforeDrain = await completion.isCompleted
        XCTAssertFalse(completedBeforeDrain)

        manager.testingEndClassicOperation(operationID)
        await stopTask.value

        let completedAfterDrain = await completion.isCompleted
        XCTAssertTrue(completedAfterDrain)
        XCTAssertEqual(manager.testingActiveClassicOperationCount, 0)
    }

    func testStartAfterCleanupWaitsForPreviousLifecycleOperationsToDrain() async throws {
        let manager = FileTransferManager()
        let operationID = manager.testingBeginClassicOperation()
        manager.cleanup()
        let completion = FileTransferStopCompletionProbe()
        let startTask = Task { @MainActor in
            try await manager.start()
            await completion.markCompleted()
        }

        await Task.yield()
        let completedBeforeDrain = await completion.isCompleted
        XCTAssertFalse(completedBeforeDrain)
        XCTAssertFalse(manager.testingAcceptsNewTransfers)

        manager.testingEndClassicOperation(operationID)
        try await startTask.value

        let completedAfterDrain = await completion.isCompleted
        XCTAssertTrue(completedAfterDrain)
        XCTAssertTrue(manager.testingAcceptsNewTransfers)
    }

    func testConcurrentStartsPerformOnlyOneLifecycleGenerationTransition() async throws {
        let manager = FileTransferManager()
        let operationID = manager.testingBeginClassicOperation()
        manager.cleanup()

        let firstStart = Task { @MainActor in try await manager.start() }
        let secondStart = Task { @MainActor in try await manager.start() }
        await Task.yield()
        XCTAssertFalse(manager.testingAcceptsNewTransfers)

        manager.testingEndClassicOperation(operationID)
        try await firstStart.value
        let generationAfterFirstCompletion = manager.testingLifecycleGeneration
        try await secondStart.value

        XCTAssertTrue(manager.testingAcceptsNewTransfers)
        XCTAssertEqual(manager.testingLifecycleGeneration, generationAfterFirstCompletion)
    }

    func testConcurrentStopThenStartIsSerializedAndEndsRunning() async throws {
        let manager = FileTransferManager()
        let operationID = manager.testingBeginClassicOperation()
        let stopTask = Task { @MainActor in await manager.stop() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while manager.testingAcceptsNewTransfers,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(manager.testingAcceptsNewTransfers)

        let startTask = Task { @MainActor in try await manager.start() }
        manager.testingEndClassicOperation(operationID)
        await stopTask.value
        try await startTask.value

        XCTAssertTrue(manager.testingAcceptsNewTransfers)
    }

    func testCleanupAfterQueuedStartWinsLifecycleOrdering() async {
        let manager = FileTransferManager()
        let operationID = manager.testingBeginClassicOperation()
        let stopTask = Task { @MainActor in await manager.stop() }
        while manager.testingAcceptsNewTransfers {
            await Task.yield()
        }

        let startTask = Task { @MainActor in try await manager.start() }
        while manager.testingLifecycleTransitionWaiterCount == 0 {
            await Task.yield()
        }
        manager.cleanup()
        manager.testingEndClassicOperation(operationID)

        await stopTask.value
        switch await startTask.result {
        case .success:
            XCTFail("A start ordered before cleanup must not restart the manager")
        case .failure(let error):
            guard let transferError = error as? FileTransferError,
                  case .transferCancelled = transferError else {
                return XCTFail("Expected typed lifecycle cancellation, got \(error)")
            }
        }
        XCTAssertFalse(manager.testingAcceptsNewTransfers)
        XCTAssertFalse(manager.isTransferring)
    }

    func testCancelledQueuedStartCannotRestartManager() async {
        let manager = FileTransferManager()
        let operationID = manager.testingBeginClassicOperation()
        let stopTask = Task { @MainActor in await manager.stop() }
        while manager.testingAcceptsNewTransfers {
            await Task.yield()
        }

        let startTask = Task { @MainActor in try await manager.start() }
        while manager.testingLifecycleTransitionWaiterCount == 0 {
            await Task.yield()
        }
        startTask.cancel()
        manager.testingEndClassicOperation(operationID)

        await stopTask.value
        switch await startTask.result {
        case .success:
            XCTFail("A cancelled queued start must not restart the manager")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(manager.testingAcceptsNewTransfers)
    }

    func testRemoteCapabilityNormalizationNeverInventsClassicResumeSupport() {
        let capabilities = ClassicTransferCapability.normalizedRemoteCapabilities(
            ["file_transfer"],
            fileTransferPort: 8080,
            remoteControlPort: nil
        )

        XCTAssertFalse(ClassicTransferCapability.supportsClassicResume(in: capabilities))
        XCTAssertEqual(capabilities, ["file_transfer", "fileTransferPort=8080"])
    }

    func testControlIntentNormalizationPreservesSecurityFailuresAndTypesCancellation() {
        let cancelledNetworkError = ClassicTransferControlIntentPolicy.normalized(
            NWError.posix(.ECONNRESET),
            status: .cancelled,
            controlFailure: FileTransferError.transferCancelled
        )
        guard let cancellation = cancelledNetworkError as? FileTransferError,
              case .transferCancelled = cancellation else {
            return XCTFail("Explicit cancellation must win over a transport reset")
        }

        let integrityError = ClassicTransferControlIntentPolicy.normalized(
            FileTransferError.integrityCheckFailed,
            status: .cancelled,
            controlFailure: FileTransferError.transferCancelled
        )
        guard let integrity = integrityError as? FileTransferError,
              case .integrityCheckFailed = integrity else {
            return XCTFail("Cancellation must not hide an integrity failure")
        }

        let persistenceError = ClassicTransferControlIntentPolicy.normalized(
            NWError.posix(.ECONNRESET),
            status: .failed,
            controlFailure: FileTransferError.resumeStatePersistenceFailed
        )
        guard let persistence = persistenceError as? FileTransferError,
              case .resumeStatePersistenceFailed = persistence else {
            return XCTFail("A typed control failure must survive transport teardown")
        }

        let integrityDuringPersistenceFailure = ClassicTransferControlIntentPolicy.normalized(
            FileTransferError.integrityCheckFailed,
            status: .failed,
            controlFailure: FileTransferError.resumeStatePersistenceFailed
        )
        guard let concurrentIntegrity = integrityDuringPersistenceFailure as? FileTransferError,
              case .integrityCheckFailed = concurrentIntegrity else {
            return XCTFail("A control failure must not hide a non-transport integrity failure")
        }
    }

    func testRemoteCapabilityNormalizationPreservesExplicitResumeAndPortAliases() {
        let capabilities = ClassicTransferCapability.normalizedRemoteCapabilities(
            [
                " CLASSIC_RESUME ",
                "file_transfer_port=9443",
                "remote-control-port=9444"
            ],
            fileTransferPort: 8080,
            remoteControlPort: 8081
        )

        XCTAssertTrue(ClassicTransferCapability.supportsClassicResume(in: capabilities))
        XCTAssertEqual(capabilities.count, 3)
        XCTAssertFalse(capabilities.contains(where: { $0.hasPrefix("fileTransferPort=") }))
        XCTAssertFalse(capabilities.contains(where: { $0.hasPrefix("remoteControlPort=") }))
    }

    func testResumeTransferRejectsPausedStateWithoutPersistedPauseRequest() async throws {
        let manager = FileTransferManager()
        let transfer = FileTransfer(
            id: UUID().uuidString,
            fileName: "report.txt",
            fileSize: 1024,
            deviceId: "peer-device",
            direction: .outgoing,
            status: .paused
        )
        manager.activeTransfers[transfer.id] = transfer

        await manager.resumeTransfer(try XCTUnwrap(UUID(uuidString: transfer.id)))

        XCTAssertEqual(manager.activeTransfers[transfer.id]?.status, .paused)
    }

    func testClassicTransferLoopControlPolicyFailsClosedForTerminalStates() {
        XCTAssertEqual(
            ClassicTransferLoopControlPolicy.decision(for: .transferring),
            .proceed
        )
        XCTAssertEqual(
            ClassicTransferLoopControlPolicy.decision(for: .paused),
            .waitForResume
        )
        XCTAssertEqual(
            ClassicTransferLoopControlPolicy.decision(for: .cancelled),
            .cancel
        )
        XCTAssertEqual(
            ClassicTransferLoopControlPolicy.decision(for: .failed),
            .failControlState
        )
        XCTAssertEqual(
            ClassicTransferLoopControlPolicy.decision(for: .completed),
            .failInvalidState
        )
        XCTAssertEqual(
            ClassicTransferLoopControlPolicy.decision(for: .preparing),
            .failInvalidState
        )
    }

    func testPausePersistenceFailureMarksTypedTerminalControlFailure() async throws {
        let fileManager = FileManager.default
        let invalidResumeBase = fileManager.temporaryDirectory
            .appendingPathComponent("resume-base-file-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: invalidResumeBase, options: .atomic)
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: invalidResumeBase)) }

        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(
                path: "FileTransferPauseTests/\(UUID().uuidString).json"
            ),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }
        let manager = FileTransferManager(
            historyStore: historyStore,
            resumeStore: ClassicTransferResumeStore(baseDirectory: invalidResumeBase)
        )
        await manager.awaitHistoryPersistence()
        let transfer = Self.makeManualPauseTransfer()
        manager.activeTransfers[transfer.id] = transfer
        let testPort = try XCTUnwrap(NWEndpoint.Port(rawValue: 9))
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: testPort,
            using: .tcp
        )
        manager.bindClassicConnection(connection, to: transfer.id)
        defer {
            manager.unbindClassicConnection(connection, from: transfer.id)
            connection.cancel()
        }

        let transferID = try XCTUnwrap(UUID(uuidString: transfer.id))
        let pauseTask = Task { @MainActor in
            await manager.pauseTransfer(transferID)
        }
        let didAcknowledgePause = try await Self.awaitPauseBoundaryAcknowledgment(
            manager: manager,
            transfer: transfer
        )
        XCTAssertTrue(didAcknowledgePause)
        await pauseTask.value

        XCTAssertEqual(transfer.status, .failed)
        guard case .resumeStatePersistenceFailed = transfer.classicControlFailure else {
            return XCTFail("Pause persistence failure must remain typed")
        }
        XCTAssertEqual(
            ClassicTransferLoopControlPolicy.decision(for: transfer.status),
            .failControlState
        )
        XCTAssertNil(transfer.resumeDataPath)
    }

    func testManualPauseResumeStateIsRemovedOnSuccessfulCompletionCleanup() async throws {
        let fileManager = FileManager.default
        let resumeBase = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: resumeBase)) }
        let resumeStore = ClassicTransferResumeStore(baseDirectory: resumeBase)
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(
                path: "FileTransferPauseTests/\(UUID().uuidString).json"
            ),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }
        let manager = FileTransferManager(
            historyStore: historyStore,
            resumeStore: resumeStore
        )
        await manager.awaitHistoryPersistence()
        let transfer = Self.makeManualPauseTransfer()
        manager.activeTransfers[transfer.id] = transfer
        let transferID = try XCTUnwrap(UUID(uuidString: transfer.id))
        let testPort = try XCTUnwrap(NWEndpoint.Port(rawValue: 9))
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: testPort,
            using: .tcp
        )
        manager.bindClassicConnection(connection, to: transfer.id)
        defer {
            manager.unbindClassicConnection(connection, from: transfer.id)
            connection.cancel()
        }

        let pauseTask = Task { @MainActor in
            await manager.pauseTransfer(transferID)
        }
        let didAcknowledgePause = try await Self.awaitPauseBoundaryAcknowledgment(
            manager: manager,
            transfer: transfer
        )
        XCTAssertTrue(didAcknowledgePause)
        XCTAssertEqual(transfer.status, .paused)

        await manager.resumeTransfer(transferID)
        XCTAssertEqual(
            transfer.status,
            .paused,
            "Resume must wait until the quiesced offset is durably persisted"
        )

        await pauseTask.value
        let recordURL = try XCTUnwrap(transfer.resumeDataPath)
        XCTAssertTrue(fileManager.fileExists(atPath: recordURL.path))

        await manager.resumeTransfer(transferID)
        XCTAssertEqual(transfer.status, .transferring)
        try await manager.cleanupResumeStateIfPresent(for: transfer)

        XCTAssertNil(transfer.resumeDataPath)
        XCTAssertFalse(fileManager.fileExists(atPath: recordURL.path))
        let persistedRecord = try await resumeStore.load(transferID: transfer.id)
        XCTAssertNil(persistedRecord)
    }

    func testCancellingPausedTransferWithoutConnectionWaitsForResumeRecordCleanup() async throws {
        let fileManager = FileManager.default
        let resumeBase = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: resumeBase)) }
        let resumeStore = ClassicTransferResumeStore(baseDirectory: resumeBase)
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(
                path: "FileTransferCancellationTests/\(UUID().uuidString).json"
            ),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }
        let manager = FileTransferManager(historyStore: historyStore, resumeStore: resumeStore)
        await manager.awaitHistoryPersistence()
        let transfer = Self.makeManualPauseTransfer()
        manager.activeTransfers[transfer.id] = transfer

        let testPort = try XCTUnwrap(NWEndpoint.Port(rawValue: 9))
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: testPort,
            using: .tcp
        )
        manager.bindClassicConnection(connection, to: transfer.id)
        let transferID = try XCTUnwrap(UUID(uuidString: transfer.id))
        let pauseTask = Task { @MainActor in
            await manager.pauseTransfer(transferID)
        }
        let didAcknowledgePause = try await Self.awaitPauseBoundaryAcknowledgment(
            manager: manager,
            transfer: transfer
        )
        XCTAssertTrue(didAcknowledgePause)
        await pauseTask.value
        let recordURL = try XCTUnwrap(transfer.resumeDataPath)
        XCTAssertTrue(fileManager.fileExists(atPath: recordURL.path))

        manager.unbindClassicConnection(connection, from: transfer.id)
        connection.cancel()
        manager.cancelTransfer(transfer.id)
        await manager.testingAwaitTerminalCleanupTasks()

        XCTAssertNil(manager.activeTransfers[transfer.id])
        let persistedRecord = try await resumeStore.load(transferID: transfer.id)
        XCTAssertNil(persistedRecord)
        XCTAssertFalse(fileManager.fileExists(atPath: recordURL.path))
        XCTAssertEqual(manager.transferHistory.last(where: { $0.id == transfer.id })?.status, .cancelled)
    }

    func testCancellationSurfacesResumeRecordCleanupFailure() async throws {
        let fileManager = FileManager.default
        let invalidResumeBase = fileManager.temporaryDirectory
            .appendingPathComponent("resume-cleanup-base-file-\(UUID().uuidString)")
        try Data("not-a-directory".utf8).write(to: invalidResumeBase, options: .atomic)
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: invalidResumeBase)) }
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(
                path: "FileTransferCancellationTests/\(UUID().uuidString).json"
            ),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }
        let manager = FileTransferManager(
            historyStore: historyStore,
            resumeStore: ClassicTransferResumeStore(baseDirectory: invalidResumeBase)
        )
        await manager.awaitHistoryPersistence()
        let transfer = Self.makeManualPauseTransfer()
        transfer.resumeDataPath = invalidResumeBase.appendingPathComponent("owned.resume")
        manager.activeTransfers[transfer.id] = transfer

        manager.cancelTransfer(transfer.id)
        await manager.testingAwaitTerminalCleanupTasks()

        let historicalTransfer = try XCTUnwrap(
            manager.transferHistory.last(where: { $0.id == transfer.id })
        )
        XCTAssertEqual(historicalTransfer.status, .failed)
        guard case .resumeStateCleanupFailed = historicalTransfer.classicControlFailure else {
            return XCTFail("Cleanup failure must remain typed")
        }
    }

    func testClassicTransferPeerResolutionPrefersDeclaredSenderDeviceId() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:trusted-peer",
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "MacBook Pro",
            transferId: "transfer-1"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:trusted-peer",
                resolvedPeerDeviceId: "id:trusted-peer",
                aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: [ClassicTransferCapability.classicResume]
            ),
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:other-peer",
                resolvedPeerDeviceId: "id:other-peer",
                aliases: ["id:other-peer", "other-peer"],
                endpointHostOrIP: "192.168.31.30",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertEqual(resolved?.matchDeviceId, "id:trusted-peer")
        XCTAssertEqual(resolved?.matchedBy, .declaredSenderDeviceId)
        XCTAssertTrue(resolved?.supportsClassicResume == true)
    }

    func testClassicTransferExactIdentityWinsAliasAndAmbiguousAliasFailsClosed() {
        let directPeer = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:canonical",
            resolvedPeerDeviceId: "id:canonical",
            aliases: ["id:canonical"],
            endpointHostOrIP: nil,
            capabilities: []
        )
        let aliasOnlyPeer = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:other",
            resolvedPeerDeviceId: "id:other",
            aliases: ["id:canonical", "shared-alias"],
            endpointHostOrIP: nil,
            capabilities: []
        )
        let exactContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:canonical",
            endpointHostOrIP: nil,
            peerLabel: nil,
            transferId: "exact-precedence"
        )
        for peers in [[aliasOnlyPeer, directPeer], [directPeer, aliasOnlyPeer]] {
            XCTAssertEqual(
                ClassicTransferPeerResolutionPolicy.resolvePeer(
                    peerContext: exactContext,
                    authenticatedPeers: peers
                )?.resolvedPeerDeviceId,
                "id:canonical"
            )
        }

        let secondAliasPeer = ClassicTransferAuthenticatedPeerCandidate(
            matchDeviceId: "id:second",
            resolvedPeerDeviceId: "id:second",
            aliases: ["shared-alias"],
            endpointHostOrIP: nil,
            capabilities: []
        )
        XCTAssertNil(
            ClassicTransferPeerResolutionPolicy.resolvePeer(
                peerContext: .init(
                    declaredSenderDeviceId: "shared-alias",
                    endpointHostOrIP: nil,
                    peerLabel: nil,
                    transferId: "ambiguous-alias"
                ),
                authenticatedPeers: [aliasOnlyPeer, secondAliasPeer]
            )
        )
    }

    func testClassicTransferPeerResolutionFallsBackToEndpointHostOrIP() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "host:stale-peer",
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "MacBook Pro",
            transferId: "transfer-2"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:trusted-peer",
                resolvedPeerDeviceId: "id:trusted-peer",
                aliases: ["id:trusted-peer", "trusted-peer", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertEqual(resolved?.matchDeviceId, "id:trusted-peer")
        XCTAssertEqual(resolved?.matchedBy, .endpointHostOrIP)
    }

    func testClassicTransferPeerResolutionDoesNotGuessWhenMultiplePeersMatchEndpoint() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: nil,
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "MacBook Pro",
            transferId: "transfer-3"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-a",
                resolvedPeerDeviceId: "id:peer-a",
                aliases: ["id:peer-a", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            ),
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:peer-b",
                resolvedPeerDeviceId: "id:peer-b",
                aliases: ["id:peer-b", "host:192.168.31.20", "192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(resolved)
    }

    func testClassicTransferPeerResolutionDoesNotUseSingleFallbackWhenHintsMismatch() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:offline-ios",
            endpointHostOrIP: "192.168.31.20",
            peerLabel: "iPhone",
            transferId: "transfer-mismatch"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:stale-mac",
                resolvedPeerDeviceId: "id:stale-mac",
                aliases: ["id:stale-mac", "host:10.0.0.44", "10.0.0.44"],
                endpointHostOrIP: "10.0.0.44",
                capabilities: []
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(
            resolved,
            "Outgoing file transfer must not reuse the only authenticated session when the selected device/id/address hints point elsewhere."
        )
    }

    func testClassicTransferPeerResolutionRequiresExplicitPeerEvidenceEvenWithSingleAuthenticatedPeer() {
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: nil,
            endpointHostOrIP: nil,
            peerLabel: "iPad",
            transferId: "transfer-no-hints"
        )
        let peers = [
            ClassicTransferAuthenticatedPeerCandidate(
                matchDeviceId: "id:only-peer",
                resolvedPeerDeviceId: "id:only-peer",
                aliases: ["id:only-peer", "only-peer", "host:192.168.31.20"],
                endpointHostOrIP: "192.168.31.20",
                capabilities: [ClassicTransferCapability.classicResume]
            )
        ]

        let resolved = ClassicTransferPeerResolutionPolicy.resolvePeer(
            peerContext: peerContext,
            authenticatedPeers: peers
        )

        XCTAssertNil(
            resolved,
            "Classic file transfer must fail closed when metadata provides no sender id or endpoint evidence; a single authenticated connection is not enough to guess the target."
        )
    }

    func testClassicTransferRegistryRemovesSessionSnapshotsByPeerKeys() async {
        let sessionId = "registry-session-\(UUID().uuidString)"
        let registry = ClassicTransferSessionRegistry.shared
        await registry.remove(sessionId: sessionId)
        defer {
            Task {
                await registry.remove(sessionId: sessionId)
            }
        }

        let snapshot = ClassicTransferSessionSnapshot(
            sessionId: sessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: [],
            sessionKeys: Self.mockSessionKeys(sessionId: sessionId)
        )

        await registry.upsert(session: snapshot)
        var sessions = await registry.activeSessions()
        XCTAssertTrue(sessions.contains(where: { $0.sessionId == sessionId }))

        await registry.remove(peerKeys: ["id:ios-peer"])

        sessions = await registry.activeSessions()
        XCTAssertFalse(
            sessions.contains(where: { $0.sessionId == sessionId }),
            "Disconnect cleanup must remove detached classic session snapshots as well as live P2PConnection indexes."
        )
    }

    func testClassicTransferRegistryReturnsNewestLiveSnapshotAndPrunesStaleOnes() async {
        let oldSessionId = "registry-old-\(UUID().uuidString)"
        let freshSessionId = "registry-fresh-\(UUID().uuidString)"
        let staleSessionId = "registry-stale-\(UUID().uuidString)"
        let registry = ClassicTransferSessionRegistry.shared
        await registry.remove(sessionId: oldSessionId)
        await registry.remove(sessionId: freshSessionId)
        await registry.remove(sessionId: staleSessionId)
        defer {
            Task {
                await registry.remove(sessionId: oldSessionId)
                await registry.remove(sessionId: freshSessionId)
                await registry.remove(sessionId: staleSessionId)
            }
        }

        let now = Date()
        let oldSnapshot = ClassicTransferSessionSnapshot(
            sessionId: oldSessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: ["fileTransferPort=8080"],
            sessionKeys: Self.mockSessionKeys(sessionId: oldSessionId),
            lastSeenAt: now.addingTimeInterval(-30)
        )
        let freshSnapshot = ClassicTransferSessionSnapshot(
            sessionId: freshSessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: ["fileTransferPort=8080"],
            sessionKeys: Self.mockSessionKeys(sessionId: freshSessionId),
            lastSeenAt: now
        )
        let staleSnapshot = ClassicTransferSessionSnapshot(
            sessionId: staleSessionId,
            matchDeviceId: "id:ios-peer",
            resolvedPeerDeviceId: "id:ios-peer",
            aliases: ["id:ios-peer", "host:192.168.31.20", "192.168.31.20"],
            endpointHostOrIP: "192.168.31.20",
            capabilities: ["fileTransferPort=8080"],
            sessionKeys: Self.mockSessionKeys(sessionId: staleSessionId),
            lastSeenAt: now.addingTimeInterval(-(ClassicTransferSessionRegistry.sessionSnapshotTimeToLive + 1))
        )

        await registry.upsert(session: oldSnapshot)
        await registry.upsert(session: freshSnapshot)
        await registry.upsert(session: staleSnapshot)

        let sessions = await registry.activeSessions(now: now)

        XCTAssertEqual(sessions.first?.sessionId, freshSessionId)
        XCTAssertTrue(sessions.contains(where: { $0.sessionId == oldSessionId }))
        XCTAssertFalse(sessions.contains(where: { $0.sessionId == staleSessionId }))
    }

    func testClassicTransferSessionSourceResolutionPrefersFreshLiveConnectionOverOlderSnapshot() {
        let transferId = "transfer-\(UUID().uuidString)"
        let peerContext = FileTransferPeerContext(
            declaredSenderDeviceId: "id:ios-peer",
            endpointHostOrIP: "fe80::bc:dca9:7759:5a45%en0",
            peerLabel: "iPhone",
            transferId: transferId
        )
        let now = Date()
        let staleSourceIdentifier = UUID()
        let freshSourceIdentifier = UUID()
        let aliases = [
            "id:ios-peer",
            "ios-peer",
            "host:fe80::bc:dca9:7759:5a45%en0",
            "fe80::bc:dca9:7759:5a45%en0"
        ]
        let staleSnapshot = ClassicTransferAuthenticatedSessionSource(
            sourceIdentifier: staleSourceIdentifier,
            candidate: .init(
                matchDeviceId: "id:ios-peer",
                resolvedPeerDeviceId: "id:ios-peer",
                aliases: aliases,
                endpointHostOrIP: "fe80::bc:dca9:7759:5a45%en0",
                capabilities: ["fileTransferPort=8080"]
            ),
            lastSeenAt: now.addingTimeInterval(-30),
            sourceKind: .sessionSnapshot
        )
        let freshLiveConnection = ClassicTransferAuthenticatedSessionSource(
            sourceIdentifier: freshSourceIdentifier,
            candidate: .init(
                matchDeviceId: "id:ios-peer",
                resolvedPeerDeviceId: "id:ios-peer",
                aliases: aliases,
                endpointHostOrIP: "fe80::bc:dca9:7759:5a45%en0",
                capabilities: ["fileTransferPort=8080"]
            ),
            lastSeenAt: now,
            sourceKind: .liveConnection
        )

        let resolved = ClassicTransferPeerResolutionPolicy.resolveSessionSource(
            peerContext: peerContext,
            authenticatedSources: [staleSnapshot, freshLiveConnection]
        )

        XCTAssertEqual(resolved?.source.sourceKind, .liveConnection)
        XCTAssertEqual(resolved?.source.sourceIdentifier, freshSourceIdentifier)
        XCTAssertEqual(resolved?.resolution.matchedBy, .declaredSenderDeviceId)
    }

    func testClassicTransferCandidateForReconnectConnectionCarriesStableIdentityAndResolvedEndpoint() {
        let device = P2PDevice(
            id: "bonjour:iPhone@local.",
            name: "iPhone",
            type: .iOS,
            address: "iPhone.local.",
            port: 50873,
            osVersion: "iOS 26.5",
            capabilities: ["_skybridge._tcp"],
            publicKey: Data(),
            lastSeen: Date(),
            endpoints: ["iPhone._skybridge._tcp.local."]
        )
        let connection = P2PConnection(
            device: device,
            connection: NWConnection(
                host: NWEndpoint.Host("fe80::bc:dca9:7759:5a45%en0"),
                port: 50873,
                using: .tcp
            )
        )
        connection.testingSetHandshakePeerDeviceId("id:31bb9d78-11f6-4843-91ee-0a0c4c003632")
        connection.testingSetClassicTransferRemoteIdentity(
            deviceId: "31BB9D78-11F6-4843-91EE-0A0C4C003632",
            fileTransferPort: 8080,
            capabilities: [ClassicTransferCapability.classicResume]
        )
        defer { connection.disconnect() }

        let candidate = FileTransferManager.classicTransferAuthenticatedPeerCandidate(for: connection)
        let aliases = Set(candidate.aliases.map { $0.lowercased() })

        XCTAssertEqual(candidate.matchDeviceId.lowercased(), "31bb9d78-11f6-4843-91ee-0a0c4c003632")
        XCTAssertEqual(candidate.resolvedPeerDeviceId, "id:31bb9d78-11f6-4843-91ee-0a0c4c003632")
        XCTAssertTrue(aliases.contains("id:31bb9d78-11f6-4843-91ee-0a0c4c003632"))
        XCTAssertTrue(aliases.contains("bonjour:iphone@local."))
        XCTAssertTrue(aliases.contains("fe80::bc:dca9:7759:5a45%en0"))
        XCTAssertTrue(aliases.contains("host:fe80::bc:dca9:7759:5a45"))
        XCTAssertEqual(candidate.endpointHostOrIP, "fe80::bc:dca9:7759:5a45%en0")
        XCTAssertTrue(candidate.capabilities.contains("fileTransferPort=8080"))
    }

    func testResolvedReceiveDirectoryFallsBackWhenPreferredDirectoryIsNotWritable() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let readOnly = parent.appendingPathComponent("read-only", isDirectory: true)
        let fallback = parent.appendingPathComponent("fallback", isDirectory: true)

        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        defer {
            XCTAssertNoThrow(
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: readOnly.path
                )
            )
            XCTAssertNoThrow(try FileManager.default.removeItem(at: parent))
        }

        let resolution = await FileTransferSettingsBridge.resolveReceiveDirectory(
            preferredPath: readOnly.path,
            fallbackURL: fallback
        )
        guard case .success(
            let resolved,
            let usedFallback,
            let preferredFailure
        ) = resolution else {
            return XCTFail("Expected descriptor-validated fallback, got \(resolution)")
        }
        XCTAssertTrue(usedFallback)
        XCTAssertNotNil(preferredFailure)
        XCTAssertEqual(resolved.standardizedFileURL, fallback.standardizedFileURL)
    }

    func testClassicTransferSecurityContextCountsDiscoveryAuthenticatedConnections() async {
        let manager = FileTransferManager()
        let discovery = P2PDiscoveryService.shared
        let peer = P2PDevice(
            id: "discovery-peer",
            name: "Discovery Peer",
            type: .macOS,
            address: "10.0.0.9",
            port: 9527,
            osVersion: "26.4.1",
            capabilities: ["file_transfer"],
            publicKey: Data(),
            lastSeen: Date(),
            persistentDeviceId: "id:550E8400-E29B-41D4-A716-446655440010"
        )
        let connection = NWConnection(
            host: "127.0.0.1",
            port: 9,
            using: .tcp
        )
        let authenticated = P2PConnection(device: peer, connection: connection)
        authenticated.testingSetStatus(P2PConnectionStatus.authenticated)
        discovery.testingReplaceAuthenticatedConnections([peer.deviceId: authenticated])
        defer {
            discovery.testingReplaceAuthenticatedConnections([:])
            connection.cancel()
        }

        let count = await manager.testingAuthenticatedClassicTransferSourceCount()

        XCTAssertEqual(count, 1)
    }

    func testInboundPreMetadataDisconnectClassifierOnlyMatchesTransportClosure() {
        XCTAssertTrue(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.connectionClosed))
        XCTAssertTrue(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(NWError.posix(.ENOTCONN)))
        XCTAssertTrue(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(NWError.posix(.ECONNRESET)))
        XCTAssertFalse(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.invalidHeader))
        XCTAssertFalse(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.inboundInvalidInitialHeader))
        XCTAssertFalse(ClassicTransferPeerResolutionPolicy.isInboundPreMetadataDisconnect(FileTransferError.secureSessionRequired))
    }

    func testInboundPartialRetentionOnlyAcceptsExplicitRecoverableDisconnects() {
        let recoverablePOSIXCodes: [POSIXErrorCode] = [
            .ECONNABORTED, .ECONNRESET, .EHOSTUNREACH, .ENETDOWN,
            .ENETRESET, .ENETUNREACH, .ENOTCONN, .EPIPE, .ETIMEDOUT
        ]
        for code in recoverablePOSIXCodes {
            XCTAssertTrue(
                ClassicTransferRecoverableDisconnectPolicy.shouldPreserveInboundPartial(
                    receivedBytes: 1,
                    after: NWError.posix(code)
                ),
                "Expected recoverable POSIX disconnect: \(code)"
            )
        }
        XCTAssertTrue(
            ClassicTransferRecoverableDisconnectPolicy.shouldPreserveInboundPartial(
                receivedBytes: 1,
                after: FileTransferError.connectionClosed
            )
        )
        XCTAssertTrue(
            ClassicTransferRecoverableDisconnectPolicy.shouldPreserveInboundPartial(
                receivedBytes: 1,
                after: FileTransferError.timeout
            )
        )

        let nonRecoverableErrors: [Error] = [
            CancellationError(),
            NWError.posix(.ECANCELED),
            NWError.posix(.EACCES),
            FileTransferError.transferCancelled,
            FileTransferError.invalidHeader,
            FileTransferError.integrityCheckFailed,
            FileTransferError.secureSessionRequired,
            FileTransferError.receiverRejected
        ]
        for error in nonRecoverableErrors {
            XCTAssertFalse(
                ClassicTransferRecoverableDisconnectPolicy.shouldPreserveInboundPartial(
                    receivedBytes: 1,
                    after: error
                ),
                "Must not preserve an inbound partial for \(error)"
            )
        }
        XCTAssertFalse(
            ClassicTransferRecoverableDisconnectPolicy.shouldPreserveInboundPartial(
                receivedBytes: 0,
                after: FileTransferError.connectionClosed
            )
        )
    }

    func testInboundPreMetadataRejectsAreNonFatalSmokeDiagnostics() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift"),
            encoding: .utf8
        )
        let listenerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(managerSource.contains("zeroByteDisconnectError: .inboundConnectionClosedBeforeMetadata"))
        XCTAssertTrue(managerSource.contains("throw FileTransferError.inboundInvalidInitialHeader"))
        XCTAssertTrue(managerSource.contains("operation.receivedByteCount == 0"))
        XCTAssertTrue(managerSource.contains("return zeroByteDisconnectError"))
        XCTAssertFalse(
            managerSource.contains(
                "let payload = try await receiveData(length: header.length, from: connection, zeroByteDisconnectError: .inboundConnectionClosedBeforeMetadata)"
            ),
            "Only a zero-byte close before the initial header is non-fatal; metadata payload closes must stay fatal."
        )
        XCTAssertTrue(listenerSource.contains("catch FileTransferError.inboundConnectionClosedBeforeMetadata"))
        XCTAssertTrue(listenerSource.contains("file-transfer inbound-pre-metadata-disconnect"))
        XCTAssertTrue(listenerSource.contains("fatal=0 phase=initial_header bytesRead=0"))
        XCTAssertTrue(listenerSource.contains("catch FileTransferError.inboundInvalidInitialHeader"))
        XCTAssertTrue(listenerSource.contains("file-transfer inbound-rejected"))
        XCTAssertTrue(listenerSource.contains("fatal=0 phase=initial_header reason=invalid_header"))
        XCTAssertTrue(listenerSource.contains("failed stage=file-transfer phase=\\(phase)"))
        XCTAssertTrue(listenerSource.contains("mac_receive_file_connection_closed"))
        XCTAssertTrue(listenerSource.contains("inboundAdmission.reserve(connectionID: connectionId)"))
        XCTAssertTrue(listenerSource.contains("inboundAdmission.release(connectionID: connectionId)"))
        XCTAssertTrue(managerSource.contains("ClassicTransferInboundPolicy.initialHeaderTimeoutSeconds"))
        XCTAssertTrue(managerSource.contains("ClassicTransferInboundPolicy.metadataPayloadTimeoutSeconds"))
        let benignCatch = try XCTUnwrap(
            listenerSource.range(of: "catch FileTransferError.inboundConnectionClosedBeforeMetadata")
        )
        let fatalLog = try XCTUnwrap(
            listenerSource.range(of: "failed stage=file-transfer phase=\\(phase)")
        )
        XCTAssertLessThan(
            benignCatch.lowerBound,
            fatalLog.lowerBound,
            "The listener must classify metadata-free connection aborts before the generic fatal mac_receive_file failure path."
        )
        let invalidHeaderCatch = try XCTUnwrap(
            listenerSource.range(of: "catch FileTransferError.inboundInvalidInitialHeader")
        )
        XCTAssertLessThan(
            invalidHeaderCatch.lowerBound,
            fatalLog.lowerBound,
            "The listener must classify invalid initial headers as non-fatal inbound rejects before the generic fatal file-transfer path."
        )
    }

    func testHotPathSourceDoesNotHideMainThreadOrCompressionFailures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iosModelsSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Models.swift"),
            encoding: .utf8
        )
        let localPresentationSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/Utilities/LocalDevicePresentation.swift"),
            encoding: .utf8
        )
        let managerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift"),
            encoding: .utf8
        )
        let engineSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/FileTransfer/FileTransferEngine.swift"),
            encoding: .utf8
        )
        let remoteDesktopManagerSource = try String(
            contentsOf: root.appendingPathComponent("SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/RemoteDesktopManager.swift"),
            encoding: .utf8
        )
        let remoteControlManagerSource = try String(
            contentsOf: root.appendingPathComponent("Sources/SkyBridgeCore/RemoteControl/RemoteControlManager.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(iosModelsSource.contains("DispatchQueue.main.sync"))
        XCTAssertFalse(localPresentationSource.contains("DispatchQueue.main.sync"))
        XCTAssertFalse(managerSource.contains("(try? compressData(chunkData)) ?? chunkData"))
        XCTAssertFalse(managerSource.contains(".decompressed(using: .zlib)"))
        XCTAssertTrue(managerSource.contains("ClassicTransferZlibCompressionWorker.shared.compress"))
        XCTAssertTrue(managerSource.contains("ClassicTransferZlibDecompressionWorker.shared.decompress"))
        XCTAssertTrue(managerSource.contains("ClassicTransferChunkContract.decompressedOutputLimit"))
        XCTAssertTrue(managerSource.contains("ClassicTransferChunkContract.validateDecodedChunkSize"))
        XCTAssertTrue(managerSource.contains("ClassicTransferChunkContract.validateCompletion"))
        XCTAssertTrue(engineSource.contains("compressDataIfBeneficial"))
        XCTAssertTrue(engineSource.contains("isEncrypted: isEncrypted"))
        XCTAssertFalse(remoteDesktopManagerSource.contains("CMSampleBufferGetImageBuffer(frame.sampleBuffer)!"))
        XCTAssertTrue(remoteControlManagerSource.contains("failStrictMediaCapture"))
        XCTAssertTrue(remoteControlManagerSource.contains("strict-media-failed"))
    }

    func testClassicManagersAdoptSharedTerminalContractsAndPublishAfterRelease() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/FileTransfer/FileTransferManager.swift"
            ),
            encoding: .utf8
        )
        let iosSource = try String(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift"
            ),
            encoding: .utf8
        )
        let listenerSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/FileTransfer/FileTransferListenerService.swift"
            ),
            encoding: .utf8
        )

        for source in [macSource, iosSource] {
            XCTAssertTrue(source.contains("ClassicTransferSendOperation()"))
            XCTAssertTrue(source.contains("withTaskCancellationHandler"))
            XCTAssertTrue(source.contains("defer { timeoutTask.cancel() }"))
            XCTAssertTrue(source.contains("timeoutTask?.cancel()"))
            XCTAssertTrue(source.contains("ClassicTransferAuthenticationContract.isValidHMACSHA256"))
            XCTAssertTrue(source.contains("ClassicTransferReceiptContract.validateSuccessfulFileHash"))
        }
        XCTAssertTrue(macSource.contains("ClassicTransferResumeAcknowledgmentContract.validate"))
        XCTAssertTrue(macSource.contains("ClassicTransferPeerResolutionPolicy.resolveSessionSource"))
        XCTAssertTrue(macSource.contains("classicConnectionsByTransferID[transferId]"))
        XCTAssertTrue(macSource.contains("connection?.cancel()"))
        XCTAssertTrue(macSource.contains("guard activeTransfers[transfer.id] === transfer else { return }"))
        XCTAssertTrue(macSource.contains("negotiatedChunkSize: negotiatedChunkSize"))
        XCTAssertTrue(macSource.contains("negotiatedCompression: negotiatedCompression"))
        XCTAssertTrue(iosSource.contains("compression: state.metadata!.compression"))
        XCTAssertTrue(iosSource.contains("sendSuccessfulReceiptAfterCommit("))
        XCTAssertTrue(iosSource.contains("if let committedURL"))
        XCTAssertFalse(iosSource.contains("catch path rolls the committed file back"))

        // The committed URL and receipt outcome are retained before releasing the
        // actor handle so a release failure does not erase durable-file evidence.
        // User-visible terminal success must still be published only after release.
        let macReceipt = try XCTUnwrap(
            macSource.range(of: "sendSuccessfulTransferReceiptAfterCommit(")
        )
        let macRelease = try XCTUnwrap(
            macSource.range(
                of: "releaseCommittedFile(using: ioHandle)",
                range: macReceipt.upperBound..<macSource.endIndex
            )
        )
        let macPublication = try XCTUnwrap(
            macSource.range(
                of: "transfer.status = .completed",
                range: macRelease.upperBound..<macSource.endIndex
            )
        )
        XCTAssertLessThan(macRelease.lowerBound, macPublication.lowerBound)

        let iosReceipt = try XCTUnwrap(
            iosSource.range(of: "sendSuccessfulReceiptAfterCommit(")
        )
        let iosRelease = try XCTUnwrap(
            iosSource.range(
                of: "releaseCommittedFile(using: ioHandle)",
                range: iosReceipt.upperBound..<iosSource.endIndex
            )
        )
        let iosPublication = try XCTUnwrap(
            iosSource.range(
                of: "await completeTransfer(transfer.id, success: true)",
                range: iosRelease.upperBound..<iosSource.endIndex
            )
        )
        XCTAssertLessThan(iosRelease.lowerBound, iosPublication.lowerBound)

        XCTAssertTrue(listenerSource.contains("Self.cancelListener(listener)"))
        XCTAssertTrue(listenerSource.contains("connection.viabilityUpdateHandler = nil"))
        XCTAssertTrue(listenerSource.contains("connection.betterPathUpdateHandler = nil"))
        XCTAssertTrue(listenerSource.contains("inboundTasks.removeAll()"))
    }

    func testClassicInboundAdmissionReleasesCapacityDeterministically() {
        var admission = ClassicTransferInboundAdmission(limit: 2)

        XCTAssertTrue(admission.reserve(connectionID: "connection-a"))
        XCTAssertTrue(admission.reserve(connectionID: "connection-b"))
        XCTAssertFalse(admission.reserve(connectionID: "connection-c"))
        XCTAssertFalse(admission.reserve(connectionID: "connection-a"))
        XCTAssertEqual(admission.count, 2)

        admission.release(connectionID: "connection-a")

        XCTAssertTrue(admission.reserve(connectionID: "connection-c"))
        XCTAssertEqual(admission.count, 2)
    }

    func testClassicChunkContractRejectsOversizedRemainingChunkAndInexactCompletion() throws {
        XCTAssertEqual(
            try ClassicTransferChunkContract.decompressedOutputLimit(
                declaredChunkSize: 4,
                receivedBytes: 6,
                declaredFileSize: 10,
                negotiatedChunkSize: 8,
                maximumChunkSize: 8
            ),
            4
        )
        XCTAssertThrowsError(
            try ClassicTransferChunkContract.decompressedOutputLimit(
                declaredChunkSize: 5,
                receivedBytes: 6,
                declaredFileSize: 10,
                negotiatedChunkSize: 8,
                maximumChunkSize: 8
            )
        ) { error in
            XCTAssertEqual(
                error as? ClassicTransferChunkContractError,
                .chunkExceedsRemainingFileSize
            )
        }
        XCTAssertThrowsError(
            try ClassicTransferChunkContract.validateDecodedChunkSize(3, declaredChunkSize: 4)
        ) { error in
            XCTAssertEqual(
                error as? ClassicTransferChunkContractError,
                .decodedChunkSizeMismatch
            )
        }
        XCTAssertThrowsError(
            try ClassicTransferChunkContract.validateCompletion(
                receivedBytes: 9,
                declaredFileSize: 10
            )
        ) { error in
            XCTAssertEqual(
                error as? ClassicTransferChunkContractError,
                .completedFileSizeMismatch
            )
        }
    }

    func testClassicZlibWorkersEnforceInputAndOutputBounds() async throws {
        let original = Data(repeating: 0x41, count: 4_096)
        let compressed = try await ClassicTransferZlibCompressionWorker.shared.compress(
            original,
            maximumInputSize: original.count
        )
        let decoded = try await ClassicTransferZlibDecompressionWorker.shared.decompress(
            compressed,
            maximumOutputSize: original.count
        )
        XCTAssertEqual(decoded, original)

        do {
            _ = try await ClassicTransferZlibCompressionWorker.shared.compress(
                original,
                maximumInputSize: original.count - 1
            )
            XCTFail("Compression must reject inputs above the negotiated chunk bound")
        } catch let error as ClassicTransferZlibCompressionError {
            XCTAssertEqual(error, .inputLimitExceeded)
        }

        do {
            _ = try await ClassicTransferZlibDecompressionWorker.shared.decompress(
                compressed,
                maximumOutputSize: original.count - 1
            )
            XCTFail("Decompression must reject output above the declared chunk size")
        } catch let error as ClassicTransferZlibDecompressionError {
            XCTAssertEqual(error, .outputLimitExceeded)
        }
    }

    func testClassicResumeStoreRoundTripsPrivateRegularRecord() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: false)
        defer {
            XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory))
        }

        let record = Self.makeResumeRecord(transferID: "resume-roundtrip")
        let store = ClassicTransferResumeStore(baseDirectory: baseDirectory)
        let fileURL = try await store.save(record)
        let loaded = try await store.load(transferID: record.transferID)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let directoryAttributes = try fileManager.attributesOfItem(
            atPath: fileURL.deletingLastPathComponent().path
        )
        let fileMode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
        let directoryMode = try XCTUnwrap(
            directoryAttributes[.posixPermissions] as? NSNumber
        ).intValue

        XCTAssertEqual(loaded?.transferID, record.transferID)
        XCTAssertEqual(loaded?.fileHash, record.fileHash)
        XCTAssertEqual(fileMode & 0o077, 0)
        XCTAssertEqual(directoryMode & 0o077, 0)
    }

    func testTerminalResumeRecordRemovalStillRunsFromCancelledTask() async throws {
        let fileManager = FileManager.default
        let baseDirectory = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory)) }
        let store = ClassicTransferResumeStore(baseDirectory: baseDirectory)
        let record = Self.makeResumeRecord(transferID: "cancelled-cleanup")
        let recordURL = try await store.save(record)

        let cleanupTask = Task {
            await Task.yield()
            try await store.remove(matching: record)
        }
        cleanupTask.cancel()
        try await cleanupTask.value

        XCTAssertFalse(fileManager.fileExists(atPath: recordURL.path))
        let persistedRecord = try await store.load(transferID: record.transferID)
        XCTAssertNil(persistedRecord)
    }

    func testResumeRecordCompareAndDeleteRejectsStaleSameIdentifierCleanup() async throws {
        let fileManager = FileManager.default
        let baseDirectory = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory)) }
        let store = ClassicTransferResumeStore(baseDirectory: baseDirectory)
        let transferID = "same-id-new-record"
        let timestamp = Date()
        let staleRecord = Self.makeResumeRecord(
            transferID: transferID,
            timestamp: timestamp
        )
        let currentRecord = Self.makeResumeRecord(
            transferID: transferID,
            timestamp: timestamp.addingTimeInterval(0.001)
        )

        _ = try await store.save(staleRecord)
        let currentURL = try await store.save(currentRecord)

        do {
            try await store.remove(matching: staleRecord)
            XCTFail("Stale cleanup must not delete a newer same-ID resume record")
        } catch let error as FileTransferError {
            guard case .resumeStatePersistenceFailed = error else {
                return XCTFail("Unexpected compare-and-delete error: \(error)")
            }
        }

        XCTAssertTrue(fileManager.fileExists(atPath: currentURL.path))
        let persistedRecord = try await store.load(transferID: transferID)
        XCTAssertEqual(persistedRecord, currentRecord)
    }

    func testResumeStoreSerializesSameIdentifierSaveAgainstStaleRemovalAcrossInstances() async throws {
        let fileManager = FileManager.default
        let baseDirectory = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory)) }
        let firstStore = ClassicTransferResumeStore(baseDirectory: baseDirectory)
        let secondStore = ClassicTransferResumeStore(baseDirectory: baseDirectory)

        for iteration in 0..<24 {
            let transferID = "cross-instance-same-id"
            let baseTimestamp = Date().addingTimeInterval(Double(iteration))
            let staleRecord = Self.makeResumeRecord(
                transferID: transferID,
                timestamp: baseTimestamp
            )
            let currentRecord = Self.makeResumeRecord(
                transferID: transferID,
                timestamp: baseTimestamp.addingTimeInterval(0.001)
            )
            _ = try await firstStore.save(staleRecord)

            let removal = Task {
                try await firstStore.remove(matching: staleRecord)
            }
            _ = try await secondStore.save(currentRecord)
            do {
                try await removal.value
            } catch let error as FileTransferError {
                guard case .resumeStatePersistenceFailed = error else {
                    return XCTFail("Unexpected stale removal error: \(error)")
                }
            }

            let loadedRecord = try await firstStore.load(transferID: transferID)
            XCTAssertEqual(
                loadedRecord,
                currentRecord,
                "A cooperating second store must never let stale cleanup delete the replacement"
            )
        }
    }

    func testClassicResumeStorePrunesExpiredRecordAndItsOwnedPartial() async throws {
        let fileManager = FileManager.default
        let baseDirectory = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory)) }
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let partialURL = try Self.createOwnedInboundPartial(
            baseDirectory: baseDirectory,
            byteCount: 64 * 1_024
        )
        let policy = ClassicTransferResumeStore.RetentionPolicy(
            recordTTL: 60,
            maximumRecordCount: 8,
            maximumTotalInboundPartialBytes: 512 * 1_024
        )
        let initialStore = ClassicTransferResumeStore(
            baseDirectory: baseDirectory,
            retentionPolicy: policy,
            now: { timestamp }
        )
        let record = Self.makeResumeRecord(
            transferID: "resume-expired",
            direction: .incoming,
            localPath: partialURL.path,
            timestamp: timestamp
        )
        let recordURL = try await initialStore.save(record)

        let pruningStore = ClassicTransferResumeStore(
            baseDirectory: baseDirectory,
            retentionPolicy: policy,
            now: { timestamp.addingTimeInterval(61) }
        )
        let report = try await pruningStore.prune()

        XCTAssertEqual(report.removedRecordCount, 1)
        XCTAssertEqual(report.removedInboundPartialCount, 1)
        XCTAssertEqual(report.removedInboundPartialBytes, 64 * 1_024)
        XCTAssertFalse(fileManager.fileExists(atPath: recordURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: partialURL.path))
    }

    func testClassicResumeStoreEnforcesMaximumRecordCountOldestFirst() async throws {
        let fileManager = FileManager.default
        let baseDirectory = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory)) }
        let timestamp = Date(timeIntervalSince1970: 1_800_100_000)
        let policy = ClassicTransferResumeStore.RetentionPolicy(
            recordTTL: 600,
            maximumRecordCount: 2,
            maximumTotalInboundPartialBytes: 512 * 1_024
        )
        let store = ClassicTransferResumeStore(
            baseDirectory: baseDirectory,
            retentionPolicy: policy,
            now: { timestamp.addingTimeInterval(10) }
        )
        var partialURLs: [URL] = []
        for index in 0..<3 {
            let partialURL = try Self.createOwnedInboundPartial(
                baseDirectory: baseDirectory,
                byteCount: 64 * 1_024
            )
            partialURLs.append(partialURL)
            _ = try await store.save(Self.makeResumeRecord(
                transferID: "resume-count-\(index)",
                direction: .incoming,
                localPath: partialURL.path,
                timestamp: timestamp.addingTimeInterval(Double(index))
            ))
        }

        let evictedRecord = try await store.load(transferID: "resume-count-0")
        let retainedRecord1 = try await store.load(transferID: "resume-count-1")
        let retainedRecord2 = try await store.load(transferID: "resume-count-2")
        XCTAssertNil(evictedRecord)
        XCTAssertNotNil(retainedRecord1)
        XCTAssertNotNil(retainedRecord2)
        XCTAssertFalse(fileManager.fileExists(atPath: partialURLs[0].path))
        XCTAssertTrue(fileManager.fileExists(atPath: partialURLs[1].path))
        XCTAssertTrue(fileManager.fileExists(atPath: partialURLs[2].path))
    }

    func testClassicResumeStoreEnforcesTotalInboundPartialByteQuota() async throws {
        let fileManager = FileManager.default
        let baseDirectory = try Self.makeResumeStoreBaseDirectory()
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory)) }
        let timestamp = Date(timeIntervalSince1970: 1_800_200_000)
        let policy = ClassicTransferResumeStore.RetentionPolicy(
            recordTTL: 600,
            maximumRecordCount: 8,
            maximumTotalInboundPartialBytes: 96 * 1_024
        )
        let store = ClassicTransferResumeStore(
            baseDirectory: baseDirectory,
            retentionPolicy: policy,
            now: { timestamp.addingTimeInterval(10) }
        )
        let oldestPartial = try Self.createOwnedInboundPartial(
            baseDirectory: baseDirectory,
            byteCount: 64 * 1_024
        )
        _ = try await store.save(Self.makeResumeRecord(
            transferID: "resume-byte-oldest",
            direction: .incoming,
            localPath: oldestPartial.path,
            timestamp: timestamp
        ))
        let newestPartial = try Self.createOwnedInboundPartial(
            baseDirectory: baseDirectory,
            byteCount: 64 * 1_024
        )
        _ = try await store.save(Self.makeResumeRecord(
            transferID: "resume-byte-newest",
            direction: .incoming,
            localPath: newestPartial.path,
            timestamp: timestamp.addingTimeInterval(1)
        ))

        let evictedRecord = try await store.load(transferID: "resume-byte-oldest")
        let retainedRecord = try await store.load(transferID: "resume-byte-newest")
        XCTAssertNil(evictedRecord)
        XCTAssertNotNil(retainedRecord)
        XCTAssertFalse(fileManager.fileExists(atPath: oldestPartial.path))
        XCTAssertTrue(fileManager.fileExists(atPath: newestPartial.path))
    }

    func testClassicResumeStoreRejectsMaliciousPartialPathWithoutDeletingForeignFile() async throws {
        let fileManager = FileManager.default
        let baseDirectory = try Self.makeResumeStoreBaseDirectory()
        let externalDirectory = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        defer {
            XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory))
            XCTAssertNoThrow(try fileManager.removeItem(at: externalDirectory))
        }
        let externalFile = externalDirectory.appendingPathComponent("foreign.partial")
        let externalData = Data(repeating: 0x5A, count: 64 * 1_024)
        try externalData.write(to: externalFile, options: [.withoutOverwriting])
        let timestamp = Date(timeIntervalSince1970: 1_800_300_000)
        let store = ClassicTransferResumeStore(
            baseDirectory: baseDirectory,
            retentionPolicy: .init(
                recordTTL: 600,
                maximumRecordCount: 8,
                maximumTotalInboundPartialBytes: 512 * 1_024
            ),
            now: { timestamp }
        )
        let recordURL = try await store.save(Self.makeResumeRecord(
            transferID: "resume-malicious-path",
            direction: .outgoing,
            localPath: externalFile.path,
            timestamp: timestamp
        ))
        let maliciousRecord = Self.makeResumeRecord(
            transferID: "resume-malicious-path",
            direction: .incoming,
            localPath: externalFile.path,
            timestamp: timestamp
        )
        try JSONEncoder().encode(maliciousRecord).write(to: recordURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)

        await XCTAssertThrowsErrorAsync(try await store.prune())

        XCTAssertEqual(try Data(contentsOf: externalFile), externalData)
        XCTAssertFalse(fileManager.fileExists(atPath: recordURL.path))
    }

    func testClassicResumeStoreRejectsSymlinkedDirectoryComponent() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let externalDirectory = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        defer {
            XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory))
            XCTAssertNoThrow(try fileManager.removeItem(at: externalDirectory))
        }
        try fileManager.createSymbolicLink(
            at: baseDirectory.appendingPathComponent("SkyBridge", isDirectory: true),
            withDestinationURL: externalDirectory
        )

        let store = ClassicTransferResumeStore(baseDirectory: baseDirectory)
        do {
            _ = try await store.save(Self.makeResumeRecord(transferID: "directory-symlink"))
            XCTFail("A symlinked resume directory component must fail closed")
        } catch let error as FileTransferError {
            guard case .resumeStatePersistenceFailed = error else {
                return XCTFail("Unexpected resume store error: \(error)")
            }
        }
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: externalDirectory.appendingPathComponent("ResumeData").path
            )
        )
    }

    func testClassicResumeStoreRejectsFinalRecordSymlinkWithoutTouchingTarget() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resumeDirectory = baseDirectory
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("ResumeData", isDirectory: true)
        try fileManager.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)
        let externalFile = baseDirectory.appendingPathComponent("outside.txt", isDirectory: false)
        let originalExternalData = Data("must-not-change".utf8)
        try originalExternalData.write(to: externalFile, options: [.withoutOverwriting])
        let transferID = "record-symlink"
        let recordName = Self.resumeRecordFileName(transferID: transferID)
        try fileManager.createSymbolicLink(
            at: resumeDirectory.appendingPathComponent(recordName, isDirectory: false),
            withDestinationURL: externalFile
        )
        defer {
            XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory))
        }

        let store = ClassicTransferResumeStore(baseDirectory: baseDirectory)
        let expectedRecord = Self.makeResumeRecord(transferID: transferID)
        do {
            _ = try await store.save(expectedRecord)
            XCTFail("A symlinked resume record must fail closed")
        } catch let error as FileTransferError {
            guard case .resumeStatePersistenceFailed = error else {
                return XCTFail("Unexpected resume store error: \(error)")
            }
        }
        do {
            _ = try await store.load(transferID: transferID)
            XCTFail("Loading a symlinked resume record must fail closed")
        } catch let error as FileTransferError {
            guard case .resumeStatePersistenceFailed = error else {
                return XCTFail("Unexpected resume store error: \(error)")
            }
        }
        do {
            try await store.remove(matching: expectedRecord)
            XCTFail("Removing a symlinked resume record must fail closed")
        } catch let error as FileTransferError {
            guard case .resumeStatePersistenceFailed = error else {
                return XCTFail("Unexpected resume store error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: externalFile), originalExternalData)
    }

    func testClassicResumeStoreRejectsUnsafeModeOversizeCorruptionAndMismatchedRecord() async throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: false)
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: baseDirectory)) }
        let transferID = "resume-invalid-record"
        let store = ClassicTransferResumeStore(baseDirectory: baseDirectory)
        let recordURL = try await store.save(Self.makeResumeRecord(transferID: transferID))

        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: recordURL.path)
        await XCTAssertThrowsErrorAsync(try await store.load(transferID: transferID))

        try Data(repeating: 0x41, count: 64 * 1_024 + 1).write(to: recordURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        await XCTAssertThrowsErrorAsync(try await store.load(transferID: transferID))

        try Data("not-json".utf8).write(to: recordURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        await XCTAssertThrowsErrorAsync(try await store.load(transferID: transferID))

        let mismatchedRecord = Self.makeResumeRecord(transferID: "different-transfer")
        try JSONEncoder().encode(mismatchedRecord).write(to: recordURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        await XCTAssertThrowsErrorAsync(try await store.load(transferID: transferID))
    }

    private static func makeResumeStoreBaseDirectory() throws -> URL {
        let baseDirectory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: false
        )
        return baseDirectory
    }

    private static func createOwnedInboundPartial(
        baseDirectory: URL,
        byteCount: Int
    ) throws -> URL {
        let partialDirectory = baseDirectory
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent("ClassicInboundPartials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: partialDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: partialDirectory.path
        )
        let partialURL = partialDirectory.appendingPathComponent(
            ".skybridge-classic-\(UUID().uuidString).partial",
            isDirectory: false
        )
        try Data(repeating: 0x41, count: byteCount).write(
            to: partialURL,
            options: [.withoutOverwriting]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: partialURL.path
        )
        return partialURL
    }

    private static func makeResumeRecord(
        transferID: String,
        direction: TransferDirection = .outgoing,
        localPath: String = "/private/tmp/archive.bin",
        timestamp: Date = Date()
    ) -> ClassicTransferResumeRecord {
        ClassicTransferResumeRecord(
            transferID: transferID,
            fileName: "archive.bin",
            fileSize: 131_072,
            transferredBytes: 65_536,
            resumeOffset: 65_536,
            deviceID: "peer-device",
            deviceIPAddress: "192.0.2.10",
            devicePort: 8080,
            deviceName: "Peer",
            direction: direction.rawValue,
            localPath: localPath,
            fileHash: String(repeating: "a", count: 64),
            compression: "zlib",
            declaredChunkSize: 64 * 1_024,
            timestamp: timestamp
        )
    }

    private static func makeManualPauseTransfer() -> FileTransfer {
        let transfer = FileTransfer(
            id: UUID().uuidString,
            fileName: "archive.bin",
            fileSize: 131_072,
            deviceId: "peer-device",
            direction: .outgoing,
            status: .transferring
        )
        transfer.localPath = URL(fileURLWithPath: "/private/tmp/archive.bin")
        transfer.fileHash = String(repeating: "a", count: 64)
        transfer.negotiatedClassicChunkSize = 64 * 1_024
        transfer.deviceIPAddress = "192.0.2.10"
        transfer.devicePort = 8_080
        transfer.deviceName = "Peer"
        transfer.updateProgress(transferredBytes: 64 * 1_024)
        return transfer
    }

    private static func awaitPauseBoundaryAcknowledgment(
        manager: FileTransferManager,
        transfer: FileTransfer
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            await Task.yield()
            if manager.acknowledgeClassicPauseRequestIfNeeded(for: transfer) {
                return true
            }
            try await Task.sleep(for: .milliseconds(1))
        } while Date() < deadline
        return false
    }

    private static func resumeRecordFileName(transferID: String) -> String {
        let digest = SHA256.hash(data: Data(transferID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).resume"
    }

    private static func mockSessionKeys(sessionId: String) -> SessionKeys {
        SessionKeys(
            sendKey: Data(repeating: 0x11, count: 32),
            receiveKey: Data(repeating: 0x22, count: 32),
            negotiatedSuite: .x25519Ed25519,
            role: .initiator,
            transcriptHash: Data(repeating: 0x33, count: 32),
            sessionId: sessionId,
            createdAt: Date()
        )
    }
}

private actor FileTransferStopCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
