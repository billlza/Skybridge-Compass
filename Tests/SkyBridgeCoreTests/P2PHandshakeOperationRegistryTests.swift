import Network
import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PHandshakeOperationRegistryTests: XCTestCase {
    private final class Driver: @unchecked Sendable {}
    private enum TestFailure: Error {
        case unexpectedBeginOutcome
        case unexpectedArbiterDecision
    }

    private func started(
        _ outcome: P2PHandshakeOperationBeginOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> P2PHandshakeOperationToken {
        guard case .started(let token) = outcome else {
            XCTFail("Expected a started operation, got \(outcome)", file: file, line: line)
            throw TestFailure.unexpectedBeginOutcome
        }
        return token
    }

    func testDisconnectDetachesExactDriverAndPermanentlyInvalidatesOwner() throws {
        var registry = P2PHandshakeOperationRegistry<Driver>()
        let started = try started(registry.begin(kind: .authentication))
        let driver = Driver()

        let installation = registry.install(driver, for: started)
        XCTAssertTrue(installation.installed)
        XCTAssertNil(installation.displacedDriver)
        XCTAssertTrue(registry.owns(started, exactDriver: driver))

        let detached = registry.disconnect()

        XCTAssertTrue(detached === driver)
        XCTAssertFalse(registry.owns(started, exactDriver: driver))
        XCTAssertNil(registry.currentOwnedDriver())
        XCTAssertEqual(registry.begin(kind: .authentication), .disconnected)
        XCTAssertGreaterThan(
            registry.connectionGeneration,
            started.connectionGeneration
        )
    }

    func testOperationSequenceExhaustionIsExplicitAndPermanent() {
        var registry = P2PHandshakeOperationRegistry<Driver>(
            testingConnectionGeneration: 7,
            testingNextOperationSequence: .max
        )

        XCTAssertEqual(registry.begin(kind: .authentication), .sequenceExhausted)
        XCTAssertTrue(registry.isOperationSequenceExhausted)
        XCTAssertFalse(registry.isDisconnected)
        XCTAssertEqual(registry.begin(kind: .outboundRekey), .sequenceExhausted)
        XCTAssertNil(registry.currentOwnedDriver())
    }

    func testDisconnectAtMaximumGenerationIsIdempotentAndNeverRevivesOwner() throws {
        var registry = P2PHandshakeOperationRegistry<Driver>(
            testingConnectionGeneration: .max,
            testingNextOperationSequence: 0
        )
        let token = try started(registry.begin(kind: .authentication))
        let driver = Driver()
        XCTAssertTrue(registry.install(driver, for: token).installed)

        XCTAssertTrue(registry.disconnect() === driver)
        XCTAssertEqual(registry.connectionGeneration, .max)
        XCTAssertNil(registry.disconnect())
        XCTAssertEqual(registry.connectionGeneration, .max)
        XCTAssertFalse(registry.owns(token, exactDriver: driver))
        XCTAssertEqual(registry.begin(kind: .authentication), .disconnected)
    }

    func testOperationDoesNotAllowConcurrentReplacement() throws {
        var registry = P2PHandshakeOperationRegistry<Driver>()
        let first = try started(registry.begin(kind: .outboundRekey))
        let firstDriver = Driver()
        XCTAssertTrue(registry.install(firstDriver, for: first).installed)

        XCTAssertEqual(registry.begin(kind: .inboundRekey), .operationInProgress)
        XCTAssertTrue(registry.owns(first, exactDriver: firstDriver))
    }

    func testDriverReplacementWithinOneOperationInvalidatesExactOldOwner() throws {
        var registry = P2PHandshakeOperationRegistry<Driver>()
        let started = try started(registry.begin(kind: .authentication))
        let firstDriver = Driver()
        let secondDriver = Driver()

        XCTAssertTrue(registry.install(firstDriver, for: started).installed)
        let replacement = registry.install(secondDriver, for: started)

        XCTAssertTrue(replacement.installed)
        XCTAssertTrue(replacement.displacedDriver === firstDriver)
        XCTAssertFalse(registry.owns(started, exactDriver: firstDriver))
        XCTAssertTrue(registry.owns(started, exactDriver: secondDriver))
    }

    func testFinishRequiresExactCurrentDriver() throws {
        var registry = P2PHandshakeOperationRegistry<Driver>()
        let started = try started(registry.begin(kind: .inboundRekey))
        let currentDriver = Driver()
        let staleDriver = Driver()
        XCTAssertTrue(registry.install(currentDriver, for: started).installed)

        XCTAssertFalse(registry.finish(started, exactDriver: staleDriver))
        XCTAssertTrue(registry.owns(started, exactDriver: currentDriver))
        XCTAssertTrue(registry.finish(started, exactDriver: currentDriver))
        XCTAssertFalse(registry.owns(started, exactDriver: currentDriver))
    }

    func testFinishedTokenCannotInstallOrPublishThroughLaterOperation() throws {
        var registry = P2PHandshakeOperationRegistry<Driver>()
        let first = try started(registry.begin(kind: .authentication))
        XCTAssertTrue(registry.finish(first))

        let second = try started(registry.begin(kind: .outboundRekey))
        let staleDriver = Driver()
        let currentDriver = Driver()

        XCTAssertFalse(registry.install(staleDriver, for: first).installed)
        XCTAssertTrue(registry.install(currentDriver, for: second).installed)
        XCTAssertFalse(registry.owns(first, exactDriver: currentDriver))
        XCTAssertTrue(registry.owns(second, exactDriver: currentDriver))
    }

    func testConnectionDisconnectDetachesDriverBeforeAsynchronousCancellation() throws {
        let source = try p2pModelsSource()
        let disconnect = try sourceSlice(
            from: "public func disconnect()",
            to: "// MARK: - Authentication (HandshakeDriver)",
            in: source
        )

        let detach = try XCTUnwrap(disconnect.range(of: "let driver = registry.disconnect()"))
        let cancel = try XCTUnwrap(disconnect.range(of: "await teardown.driver?.cancel()"))
        XCTAssertLessThan(detach.lowerBound, cancel.lowerBound)
        XCTAssertTrue(disconnect.contains("clearEstablished(arbiterLease)"))
        XCTAssertFalse(disconnect.contains("handshakeDriverLock.withLock { $0 = nil }"))
    }

    func testConnectionPresencePublicationAndTeardownRequireExactOwnerLease() throws {
        let source = try p2pModelsSource()
        let publish = try sourceSlice(
            from: "private func publishAuthenticatedPresence(",
            to: "private func handleAppMessage(",
            in: source
        )
        let disconnect = try sourceSlice(
            from: "public func disconnect()",
            to: "// MARK: - Authentication (HandshakeDriver)",
            in: source
        )

        XCTAssertTrue(source.contains("private let presenceLeaseLock"))
        XCTAssertTrue(publish.contains("markConnectedOwned("))
        XCTAssertTrue(publish.contains("refreshConnectedIfOwned("))
        XCTAssertFalse(publish.contains("publishConnectedAtomically("))
        XCTAssertFalse(publish.contains("ConnectionPresenceService.shared.markConnected("))
        XCTAssertTrue(disconnect.contains("disconnectIfOwned(presenceLease)"))
        XCTAssertFalse(disconnect.contains("ConnectionPresenceService.shared.markDisconnected("))

        let ownerCAS = try XCTUnwrap(disconnect.range(of: "if didDisconnectPresence"))
        let unifiedDisconnect = try XCTUnwrap(
            disconnect.range(of: "UnifiedOnlineDeviceManager.shared.markDeviceAsDisconnected")
        )
        XCTAssertLessThan(ownerCAS.lowerBound, unifiedDisconnect.lowerBound)
    }

    func testConnectionClassicTransferUsesExactSessionLeaseForHeartbeatAndCleanup() throws {
        let source = try p2pModelsSource()
        let heartbeat = try sourceSlice(
            from: "private func refreshClassicTransferSessionFromHeartbeat(",
            to: "private func removeClassicTransferSessionLease(",
            in: source
        )
        let disconnect = try sourceSlice(
            from: "public func disconnect()",
            to: "// MARK: - Authentication (HandshakeDriver)",
            in: source
        )

        XCTAssertTrue(source.contains("classicTransferSessionLeasesLock"))
        XCTAssertTrue(source.contains("updateAuthenticatedSessionIfOwned("))
        XCTAssertTrue(heartbeat.contains("refreshIfOwned("))
        XCTAssertTrue(disconnect.contains("ifOwned: sessionLease"))
        XCTAssertFalse(source.contains("ClassicTransferSessionRegistry.shared.upsert(session:"))
        XCTAssertFalse(source.contains("ClassicTransferSessionRegistry.shared.remove(sessionId:"))
    }

    func testOutboundConfigurationIsResolvedBeforeExactLeaseRelease() throws {
        let source = try p2pModelsSource()
        let attempt = try sourceSlice(
            from: "private func performHandshakeAttempt(",
            to: "private func performPQCBootstrapRecoveryIfNeeded(",
            in: source
        )

        let configuration = try XCTUnwrap(
            attempt.range(of: ".committedProtocolIdentityConfiguration()")
        )
        let leaseRelease = try XCTUnwrap(
            attempt.range(of: "clearEstablished(activeLease)")
        )
        XCTAssertLessThan(
            configuration.lowerBound,
            leaseRelease.lowerBound,
            "A configuration read failure must leave the previous exact lease untouched."
        )
        XCTAssertTrue(attempt.contains("detachAndCancelDriverIfOwned(owner)"))
        XCTAssertTrue(attempt.contains("restoreReleasedArbiterLease("))
    }

    func testEstablishedReceiptRequiresExactDriverBindingAndLeaseBeforePublication() throws {
        let source = try p2pModelsSource()
        let authenticate = try sourceSlice(
            from: "public func authenticate() async throws",
            to: "private func performHandshake(",
            in: source
        )
        let attempt = try sourceSlice(
            from: "private func performHandshakeAttempt(",
            to: "private func performPQCBootstrapRecoveryIfNeeded(",
            in: source
        )

        XCTAssertTrue(attempt.contains("getAuthenticatedHandshakePeerBinding()"))
        XCTAssertTrue(attempt.contains("getEstablishedArbiterLease()"))
        XCTAssertGreaterThanOrEqual(
            attempt.components(separatedBy: "exactDriver: owner.driver").count - 1,
            3
        )
        XCTAssertTrue(attempt.contains("EstablishedHandshakeReceipt("))
        XCTAssertFalse(attempt.contains("$0 = newArbiterLease"))
        XCTAssertTrue(authenticate.contains("publishEstablishedSession(receipt)"))
        XCTAssertTrue(authenticate.contains("finishHandshakeOperation(receipt.owner)"))
    }

    func testInboundSyncRequiresExactOwnerAndRestoresExactPreviousSession() throws {
        let source = try p2pModelsSource()
        let sync = try sourceSlice(
            from: "private func syncHandshakeState(after owner:",
            to: "private func publishAuthenticatedPresence(",
            in: source
        )

        XCTAssertTrue(sync.contains("exactDriver: owner.driver"))
        XCTAssertTrue(sync.contains("guard owner.token.kind == .inboundRekey"))
        XCTAssertTrue(sync.contains("receipt.owner.driver === owner.driver"))
        XCTAssertTrue(sync.contains("rollbackReceipt.previousSession"))
        XCTAssertTrue(sync.contains("failHandshakeOperation("))
        XCTAssertFalse(sync.contains("handshakeDriverLock.withLock"))
    }

    func testPublishedNewLeaseIsClearedBeforeExactOldLeaseIsRestored() async throws {
        let pairKey = uniquePairKey("rollback-old")
        let oldLease = try await commitLease(
            pairKey: pairKey,
            sessionId: "old",
            attemptByte: 0x11
        )
        let clearedOld = await PeerSessionArbiter.shared.clearEstablished(oldLease)
        XCTAssertTrue(clearedOld)
        let newLease = try await commitLease(
            pairKey: pairKey,
            sessionId: "new",
            attemptByte: 0x22
        )
        let connection = makeConnection()
        defer { connection.disconnect() }

        let restored = try await connection.testingRollbackPublishedArbiterLease(
            currentLease: newLease,
            to: oldLease
        )

        XCTAssertEqual(restored, oldLease)
        let staleNewWasRemoved = await PeerSessionArbiter.shared.clearEstablished(newLease)
        XCTAssertFalse(staleNewWasRemoved)
        let exactOldWasRestored = await PeerSessionArbiter.shared.clearEstablished(oldLease)
        XCTAssertTrue(exactOldWasRestored)
    }

    func testInitialAuthenticationRollbackClearsPublishedNewLease() async throws {
        let pairKey = uniquePairKey("rollback-initial")
        let newLease = try await commitLease(
            pairKey: pairKey,
            sessionId: "new-initial",
            attemptByte: 0x33
        )
        let connection = makeConnection()
        defer { connection.disconnect() }

        let restored = try await connection.testingRollbackPublishedArbiterLease(
            currentLease: newLease,
            to: nil
        )

        XCTAssertNil(restored)
        let orphanedNewLease = await PeerSessionArbiter.shared.clearEstablished(newLease)
        XCTAssertFalse(orphanedNewLease)
    }

    func testRollbackNeverClearsUnrelatedReplacementLease() async throws {
        let pairKey = uniquePairKey("rollback-replacement")
        let oldLease = try await commitLease(
            pairKey: pairKey,
            sessionId: "old",
            attemptByte: 0x44
        )
        let oldWasCleared = await PeerSessionArbiter.shared.clearEstablished(oldLease)
        XCTAssertTrue(oldWasCleared)
        let supersededNewLease = try await commitLease(
            pairKey: pairKey,
            sessionId: "superseded-new",
            attemptByte: 0x55
        )
        let supersededNewWasCleared = await PeerSessionArbiter.shared.clearEstablished(
            supersededNewLease
        )
        XCTAssertTrue(supersededNewWasCleared)
        let replacementLease = try await commitLease(
            pairKey: pairKey,
            sessionId: "replacement",
            attemptByte: 0x66
        )
        let connection = makeConnection()
        defer { connection.disconnect() }

        do {
            _ = try await connection.testingRollbackPublishedArbiterLease(
                currentLease: supersededNewLease,
                to: oldLease
            )
            XCTFail("Rollback must fail closed when an unrelated replacement owns the slot")
        } catch {
            XCTAssertTrue(error is P2PConnectionError)
        }

        let replacementSurvived = await PeerSessionArbiter.shared.clearEstablished(
            replacementLease
        )
        XCTAssertTrue(replacementSurvived)
        let oldWasNotRestoredOverReplacement = await PeerSessionArbiter.shared
            .clearEstablished(oldLease)
        XCTAssertFalse(oldWasNotRestoredOverReplacement)
    }

    func testP2PConnectionNeverUsesPairKeyOnlyOutgoingTeardown() throws {
        let source = try p2pModelsSource()
        XCTAssertFalse(source.contains("PeerSessionArbiter.shared.clearOutgoing"))
    }

    func testOutboundRekeyGateIsStagedBeforeSnapshotAwaitAndClearedByOwner() throws {
        let source = try p2pModelsSource()
        let authenticate = try sourceSlice(
            from: "public func authenticate() async throws",
            to: "private func performHandshake(",
            in: source
        )
        let finish = try sourceSlice(
            from: "private func finishHandshakeOperation(",
            to: "private func publishStatus(",
            in: source
        )

        let gate = try XCTUnwrap(
            authenticate.range(of: "rekeyInProgressLock.withLock { $0 = true }")
        )
        let snapshotAwait = try XCTUnwrap(
            authenticate.range(of: "try await currentEstablishedSessionSnapshot(")
        )
        XCTAssertLessThan(gate.lowerBound, snapshotAwait.lowerBound)
        XCTAssertTrue(finish.contains("exactDriver: owner.driver"))
        XCTAssertTrue(finish.contains("rekeyInProgressLock.withLock { $0 = false }"))
    }

    func testFailureRollbackRemovesExactNewSnapshotBeforeLeaseReconciliation() throws {
        let source = try p2pModelsSource()
        let failure = try sourceSlice(
            from: "private func failHandshakeOperation(",
            to: "private func clearPublishedSession(",
            in: source
        )

        let exactSnapshotRemoval = try XCTUnwrap(
            failure.range(
                of: "removeClassicTransferSessionLease(sessionId: publishedClassicSessionId)"
            )
        )
        let leaseRollback = try XCTUnwrap(
            failure.range(of: "rollbackPublishedArbiterLease(")
        )
        XCTAssertLessThan(exactSnapshotRemoval.lowerBound, leaseRollback.lowerBound)
        XCTAssertTrue(failure.contains("previousSession?.assuranceLevel ?? .unknown"))
    }

    private func p2pModelsSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/P2P/P2PModels.swift"
            ),
            encoding: .utf8
        )
    }

    private func uniquePairKey(_ label: String) -> Data {
        Data("\(label)-\(UUID().uuidString)".utf8)
    }

    private func commitLease(
        pairKey: Data,
        sessionId: String,
        attemptByte: UInt8
    ) async throws -> PeerSessionArbiter.EstablishedLease {
        let decision = await PeerSessionArbiter.shared.registerOutgoing(.init(
            pairKey: pairKey,
            initiatorPeerId: Data(repeating: attemptByte, count: 32),
            attemptId: Data(repeating: attemptByte, count: 16),
            startedAt: Date(),
            onSuperseded: { _, _ in }
        ))
        guard case .accepted(let reservation) = decision else {
            throw TestFailure.unexpectedArbiterDecision
        }
        return try await PeerSessionArbiter.shared.commitEstablished(
            reservation,
            sessionId: sessionId
        )
    }

    private func makeConnection() -> P2PConnection {
        let device = P2PDevice(
            id: "lease-rollback-\(UUID().uuidString)",
            name: "Lease Rollback Test",
            type: .macOS,
            address: "127.0.0.1",
            port: 9,
            osVersion: "test",
            capabilities: [],
            publicKey: Data(),
            lastSeen: Date()
        )
        return P2PConnection(
            device: device,
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        )
    }

    private func sourceSlice(
        from startMarker: String,
        to endMarker: String,
        in source: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }
}
