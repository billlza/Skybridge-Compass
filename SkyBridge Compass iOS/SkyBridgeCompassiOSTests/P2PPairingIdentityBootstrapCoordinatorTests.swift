import Foundation
import XCTest
@testable import SkyBridgeCompass_iOS

final class P2PPairingIdentityBootstrapCoordinatorTests: XCTestCase {
    @MainActor
    func testCurrentEvidenceDoesNotRepeatExchangeOrRefresh() async throws {
        let source = BootstrapSource()
        source.strictMaterial = true
        let result = try await source.run()
        XCTAssertEqual(result.receipt, source.receipt)
        XCTAssertTrue(result.observedReply)
        XCTAssertEqual(source.refreshCount, 0)
        XCTAssertEqual(source.exchangeCount, 0)
    }

    @MainActor
    func testExpiredMaterialUsesOneSignedRefreshOnTheSameSession() async throws {
        let source = BootstrapSource()
        let result = try await source.run()
        XCTAssertEqual(result.receipt, source.receipt)
        XCTAssertTrue(result.observedReply)
        XCTAssertEqual(source.refreshCount, 1)
        XCTAssertEqual(source.exchangeCount, 0)
        XCTAssertEqual(source.refreshedObservation?.connectionGeneration, source.receipt.connectionGeneration)
        XCTAssertEqual(source.refreshedObservation?.protocolPublicKeyFingerprint, source.receipt.protocolPublicKeyFingerprint)
    }

    @MainActor
    func testMissingObservationRequiresAnExchangeBeforeRefreshing() async throws {
        let source = BootstrapSource()
        source.observation = nil
        let result = try await source.run()
        XCTAssertEqual(result.receipt, source.receipt)
        XCTAssertEqual(source.events, ["exchange", "refresh", "receipt"])
    }

    @MainActor
    func testJournalQuarantinePreventsRefreshAndReceiptPublication() async throws {
        let source = BootstrapSource()
        source.recoveryReady = false
        let waiting = XCTestExpectation(description: "Journal quarantine observed")
        source.onQuarantineObserved = { waiting.fulfill() }
        let operation = Task { try await source.run() }
        let result = await XCTWaiter.fulfillment(of: [waiting], timeout: 1)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(source.events.isEmpty)
        source.recoveryReady = true
        let completed = try await operation.value
        XCTAssertEqual(completed.receipt, source.receipt)
        XCTAssertEqual(source.refreshCount, 1)
    }

    @MainActor
    func testRefreshFailurePropagatesWithoutMetadataFallback() async throws {
        let source = BootstrapSource()
        source.refreshBody = { throw BootstrapSource.Failure.refreshRejected }
        do {
            _ = try await source.run()
            XCTFail("A rejected signed refresh must fail the operation")
        } catch BootstrapSource.Failure.refreshRejected {
            XCTAssertEqual(source.refreshCount, 1)
        }
        XCTAssertEqual(source.refreshCount, 1)
        XCTAssertEqual(source.exchangeCount, 0)
        XCTAssertEqual(source.receiptCount, 0)
    }

    @MainActor
    func testReplacementDuringRefreshCannotPublishTheOldReceipt() async throws {
        let source = BootstrapSource()
        source.refreshBody = {
            source.isCurrent = false
            source.strictMaterial = true
        }
        defer { source.refreshBody = nil }
        do {
            _ = try await source.run()
            XCTFail("A replaced connection must remain fenced after refresh")
        } catch BootstrapSource.Failure.staleSession {
            XCTAssertFalse(source.isCurrent)
        }
        XCTAssertEqual(source.receiptCount, 0)
    }

    @MainActor
    func testReplacementDuringTrustReadCannotPublishTheOldReceipt() async throws {
        let source = BootstrapSource()
        source.strictReadBody = {
            source.isCurrent = false
            return true
        }
        defer { source.strictReadBody = nil }
        do {
            _ = try await source.run()
            XCTFail("A trust-store read cannot outlive its authenticated session")
        } catch BootstrapSource.Failure.staleSession {
            XCTAssertFalse(source.isCurrent)
        }
        XCTAssertEqual(source.receiptCount, 0)
        XCTAssertEqual(source.refreshCount, 0)
    }

    @MainActor
    func testOneBoundedSignedRefreshPreservesTheMetadataWaitBudget() async throws {
        let source = BootstrapSource()
        source.refreshBody = {
            try await Task.sleep(for: .milliseconds(150))
            source.strictMaterial = true
        }
        defer { source.refreshBody = nil }
        let result = try await source.run()
        XCTAssertEqual(result.receipt, source.receipt)
        XCTAssertEqual(source.refreshCount, 1)
    }

    @MainActor
    func testCancellationDuringRefreshCannotPublishAReceipt() async throws {
        let source = BootstrapSource()
        let started = XCTestExpectation(description: "Signed refresh started")
        var release: CheckedContinuation<Void, Never>?
        source.refreshBody = {
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            source.strictMaterial = true
        }
        defer { source.refreshBody = nil }
        let operation = Task { try await source.run() }
        let waiting = await XCTWaiter.fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(waiting, .completed)
        operation.cancel()
        try XCTUnwrap(release).resume()
        do {
            _ = try await operation.value
            XCTFail("Cancellation cannot become a ready session")
        } catch is CancellationError {
            XCTAssertTrue(operation.isCancelled)
        }
        XCTAssertEqual(source.receiptCount, 0)
    }

    @MainActor
    func testAnUnusableRefreshFailsWithoutRepeatedRefreshes() async throws {
        let source = BootstrapSource()
        source.refreshBody = { /* Simulates a verified response without required material. */ }
        do {
            _ = try await source.run()
            XCTFail("An unusable signed refresh must remain an explicit failure")
        } catch P2PPairingIdentityBootstrapCoordinator.Failure.signedMaterialUnavailableAfterRefresh {
            XCTAssertEqual(source.refreshCount, 1)
        }
        XCTAssertEqual(source.refreshCount, 1)
        XCTAssertEqual(source.exchangeCount, 0)
        XCTAssertEqual(source.receiptCount, 0)
    }

    @MainActor
    func testMissingReplyTimesOutAfterOneExchange() async throws {
        let source = BootstrapSource()
        source.observation = nil
        source.deliverObservation = false
        let result = try await source.run()
        XCTAssertFalse(result.isReady)
        XCTAssertFalse(result.observedReply)
        XCTAssertEqual(source.exchangeCount, 1)
        XCTAssertEqual(source.refreshCount, 0)
        XCTAssertEqual(source.receiptCount, 0)
    }
}

@MainActor
private final class BootstrapSource {
    enum Failure: Error { case refreshRejected, staleSession }
    let receipt: P2PPairingIdentityBootstrapReadinessReceipt
    let initialObservation: P2PPairingIdentityBootstrapObservation
    var observation: P2PPairingIdentityBootstrapObservation?
    var refreshedObservation: P2PPairingIdentityBootstrapObservation?
    var isCurrent = true
    var recoveryReady = true
    var strictMaterial = false
    var deliverObservation = true
    var refreshCount = 0
    var exchangeCount = 0
    var receiptCount = 0
    var events: [String] = []
    var refreshBody: (@MainActor () async throws -> Void)?
    var strictReadBody: (@MainActor () async -> Bool)?
    var onQuarantineObserved: (@MainActor () -> Void)?

    init() {
        let generation = UUID()
        receipt = .init(peerId: "peer", connectionGeneration: generation,
                        sessionId: "session", declaredDeviceId: "device",
                        protocolPublicKeyFingerprint: "pinned", acceptedMaterialDigest: Data([7]))
        initialObservation = .init(connectionGeneration: generation, sessionId: "session",
                                   observedAt: .distantPast, declaredDeviceId: "device",
                                   protocolPublicKeyFingerprint: "pinned", acceptedMaterialDigest: Data([7]))
        observation = initialObservation
    }

    func run() async throws -> P2PPairingIdentityBootstrapReadinessResult {
        try await P2PPairingIdentityBootstrapCoordinator.run(
            timeout: .milliseconds(100), pollInterval: .milliseconds(1),
            operations: .init(
                requireCurrent: { if !self.isCurrent { throw Failure.staleSession } },
                isRecoveryReady: {
                    if !self.recoveryReady {
                        let callback = self.onQuarantineObserved
                        self.onQuarantineObserved = nil
                        callback?()
                    }
                    return self.recoveryReady
                },
                observe: { self.observation },
                hasStrictMaterial: { _ in
                    if let body = self.strictReadBody { return await body() }
                    return self.strictMaterial
                },
                refreshSignedMaterial: { observation in
                    self.refreshCount += 1
                    self.events.append("refresh")
                    self.refreshedObservation = observation
                    if let body = self.refreshBody { try await body() }
                    else { self.strictMaterial = true }
                },
                makeCurrentReceipt: { _ in
                    self.receiptCount += 1
                    self.events.append("receipt")
                    return self.receipt
                },
                sendIdentityExchange: {
                    self.exchangeCount += 1
                    self.events.append("exchange")
                    if self.deliverObservation { self.observation = self.initialObservation }
                }
            )
        )
    }
}
