#if os(macOS)
import Foundation
import Network
import XCTest
import SkyBridgeProtocolCore
import CSkyBridgeUSBHost
@testable import SkyBridgeAppleTransport
@testable import SkyBridgeCore

/// These fixtures exercise ownership and cancellation only. A fixture marked
/// authenticated is not evidence of a cryptographic or physical USB handshake.
@MainActor
final class AndroidUSBConnectionCoordinatorTests: XCTestCase {
    private enum Failure: Error { case run, cleanup, deadline }
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private final class Runtime: AndroidUSBSessionRuntime {
        var connection: P2PConnection?
        var connectionEndFailure: (any Error)?
        var attemptKey: String? = "fixture"
        var cleanupConfirmed = false
        var runGate: Gate?
        var cleanupGate: Gate?
        var runFailure: (any Error)?
        var cleanupFailure: (any Error)?
        var confirmCleanup = true
        var runs = 0, cleanups = 0, retirements = 0, releases = 0
        var onRetire: (() -> Void)?
        func run(progress: @escaping @MainActor (AndroidUSBConnectionPhase) -> Void) async throws {
            runs += 1
            progress(.authenticating)
            await runGate?.wait() // deliberately ignores cancellation until released
            if let runFailure { throw runFailure }
        }
        func releaseAttempt() { releases += 1 }
        func retire() { retirements += 1; onRetire?() }
        func closeAndAwait() async throws {
            cleanups += 1
            await cleanupGate?.wait()
            cleanupConfirmed = confirmCleanup
            if let cleanupFailure { throw cleanupFailure }
        }
    }
    private func source() -> USBDeviceInfo {
        USBDeviceInfo(deviceID: "fixture", name: "Android", deviceType: .androidDevice,
            vendorID: 0x04e8, productID: 0x6860, serialNumber: nil, isMFiCertified: false,
            connectionInterface: "USB", capabilities: [], registryEntryID: 100, locationID: 200)
    }
    private func peer() throws -> AndroidUSBSelectedPeer {
        try .init(deviceID: "id:12345678-1234-1234-1234-123456789abc",
                  fingerprint: String(repeating: "a", count: 64), algorithm: .mlDSA65, name: "Paired phone")
    }
    private func connection(status: P2PConnectionStatus = .authenticated) -> P2PConnection {
        let device = P2PDevice(id: "fixture", name: "Fixture", type: .android,
            address: "fixture", port: 0, osVersion: "", capabilities: [], publicKey: Data(), lastSeen: Date())
        // No network start. Only the observable status is used by this suite.
        let result = P2PConnection(device: device,
            connection: NWConnection(to: .unix(path: "/tmp/skybridge-usb-unused"), using: .tcp))
        result.testingSetStatus(status)
        return result
    }
    private func owner(_ runtime: Runtime, observation: Duration = .seconds(1)) -> AndroidUSBConnectionCoordinator {
        AndroidUSBConnectionCoordinator(factory: { _, _, _ in runtime }, cleanupObservation: observation)
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testSelectionRequiresProtocolIdentity() throws {
        let value = try peer()
        XCTAssertEqual(value.deviceID, "12345678-1234-1234-1234-123456789abc")
        for id in ["USB phone", "R3-hardware-serial"] {
            XCTAssertThrowsError(try AndroidUSBSelectedPeer(deviceID: id,
                fingerprint: value.fingerprint, algorithm: .mlDSA65, name: "Phone"))
        }
        XCTAssertThrowsError(try AndroidUSBSelectedPeer(deviceID: value.deviceID,
            fingerprint: "not-a-pin", algorithm: .mlDSA65, name: "Phone"))
        XCTAssertThrowsError(try AndroidUSBSelectedPeer(deviceID: value.deviceID,
            fingerprint: value.fingerprint, algorithm: .ed25519, name: "Phone"))
    }

    func testAccessoryReconnectWaitsForThePriorOwnerToActuallyRelease() async throws {
        for product: UInt16 in [0x2d00, 0x2d01] {
            let runtime = Runtime(), cleanup = Gate()
            runtime.runFailure = Failure.run
            runtime.cleanupGate = cleanup
            var creations = 0
            let coordinator = AndroidUSBConnectionCoordinator(factory: { _, _, _ in
                creations += 1
                return runtime
            })
            let source = USBDeviceInfo(deviceID: "same-serial", name: "Phone", deviceType: .androidDevice,
                vendorID: 0x18d1, productID: product, serialNumber: "same-serial", isMFiCertified: false,
                connectionInterface: "USB", capabilities: [], registryEntryID: 101, locationID: 200)
            XCTAssertNoThrow(try coordinator.connect(source: source, peer: peer()),
                             "An explicit v2 reconnect must not require physically detaching the cable")
            guard creations == 1 else { return }
            try await wait { runtime.cleanups == 1 }
            XCTAssertTrue(coordinator.isOccupied)
            XCTAssertThrowsError(try coordinator.connect(source: source, peer: peer()))
            XCTAssertEqual(creations, 1, "A rescan cannot bypass the existing native owner")
            cleanup.release()
            try await wait { !coordinator.isOccupied }
            try coordinator.connect(source: source, peer: peer())
            try await wait { runtime.runs == 2 && !coordinator.isOccupied }
            XCTAssertEqual(creations, 2)
        }
    }

    func testCancelWaitsForUncancellableRunBeforeCleanupOrAnotherOwner() async throws {
        let runtime = Runtime(), gate = Gate()
        runtime.runGate = gate
        defer { gate.release() }
        let coordinator = owner(runtime, observation: .milliseconds(30))
        try coordinator.connect(source: source(), peer: peer())
        try await wait { runtime.runs == 1 }
        coordinator.stop()
        try await wait { coordinator.phase == .cleanupRequired }
        XCTAssertEqual(runtime.cleanups, 0)
        XCTAssertTrue(coordinator.isOccupied)
        XCTAssertThrowsError(try coordinator.connect(source: source(), peer: peer()))
        gate.release()
        coordinator.finishCleanup()
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(runtime.runs, 1)
        XCTAssertEqual(runtime.cleanups, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testCleanupTimeoutDoesNotReplayRunOrDuplicateCleanup() async throws {
        let runtime = Runtime(), gate = Gate()
        runtime.runFailure = Failure.run; runtime.cleanupGate = gate
        defer { gate.release() }
        let coordinator = owner(runtime, observation: .milliseconds(30))
        try coordinator.connect(source: source(), peer: peer())
        try await wait { coordinator.phase == .cleanupRequired }
        coordinator.finishCleanup()
        try await wait { runtime.cleanups == 1 }
        XCTAssertThrowsError(try coordinator.connect(source: source(), peer: peer()))
        gate.release()
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(runtime.runs, 1)
        XCTAssertEqual(runtime.cleanups, 1)
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertNotNil(coordinator.failure)
    }

    func testFailedUnconfirmedCleanupRetriesOnlySameOwner() async throws {
        let runtime = Runtime()
        runtime.runFailure = Failure.run; runtime.cleanupFailure = Failure.cleanup; runtime.confirmCleanup = false
        let coordinator = owner(runtime)
        try coordinator.connect(source: source(), peer: peer())
        try await wait { coordinator.phase == .cleanupRequired }
        XCTAssertTrue(coordinator.isOccupied)
        XCTAssertThrowsError(try coordinator.connect(source: source(), peer: peer()))
        runtime.cleanupFailure = nil; runtime.confirmCleanup = true
        coordinator.finishCleanup()
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(runtime.runs, 1)
        XCTAssertEqual(runtime.cleanups, 2)
        XCTAssertEqual(coordinator.phase, .failed)
    }

    func testCleanupErrorWithProvenReleaseRemainsFailureButReleasesAdmission() async throws {
        let runtime = Runtime()
        runtime.runFailure = Failure.run; runtime.cleanupFailure = Failure.cleanup
        let coordinator = owner(runtime)
        try coordinator.connect(source: source(), peer: peer())
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(coordinator.phase, .failed)
        let failure = try XCTUnwrap(coordinator.failure as? AndroidUSBPreparationCleanupFailure)
        XCTAssertTrue(failure.primary is Failure)
        XCTAssertTrue(failure.cleanup is Failure)
        XCTAssertEqual(runtime.cleanups, 1)
    }

    func testCleanupReturnWithoutReleaseProofRetainsOwner() async throws {
        let runtime = Runtime()
        runtime.runFailure = Failure.run; runtime.confirmCleanup = false
        let coordinator = owner(runtime)
        try coordinator.connect(source: source(), peer: peer())
        try await wait { coordinator.phase == .cleanupRequired }
        XCTAssertTrue(coordinator.isOccupied)
        XCTAssertThrowsError(try coordinator.connect(source: source(), peer: peer()))
        // Receipt may be refined after a native join; observing it is not replay.
        runtime.cleanupConfirmed = true
        coordinator.finishCleanup()
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(runtime.cleanups, 1)
    }

    func testRunReturnCannotPublishMissingOrUnauthenticatedConnection() async throws {
        for candidate in [nil, connection(status: .disconnected)] {
            let runtime = Runtime(); runtime.connection = candidate
            let coordinator = owner(runtime)
            try coordinator.connect(source: source(), peer: peer())
            try await wait { !coordinator.isOccupied }
            XCTAssertNil(coordinator.authenticatedConnection)
            XCTAssertEqual(coordinator.phase, .failed)
            XCTAssertEqual(runtime.releases, 0)
        }
    }

    func testAuthenticatedStatusIsObservedUntilDisconnectAndCleanup() async throws {
        let runtime = Runtime(), connection = connection()
        runtime.connection = connection
        let coordinator = owner(runtime)
        try coordinator.connect(source: source(), peer: peer())
        try await wait { coordinator.phase == .connected }
        XCTAssertTrue(coordinator.authenticatedConnection === connection)
        XCTAssertEqual(runtime.releases, 1)
        connection.testingSetStatus(.disconnected)
        try await wait { !coordinator.isOccupied }
        XCTAssertNil(coordinator.authenticatedConnection)
        XCTAssertEqual(runtime.cleanups, 1)
    }

    func testPeerTerminationCauseRemainsVisibleAfterCleanup() async throws {
        let runtime = Runtime(), connection = connection()
        runtime.connection = connection
        let coordinator = owner(runtime)
        try coordinator.connect(source: source(), peer: peer())
        try await wait { coordinator.phase == .connected }
        runtime.connectionEndFailure = USBLogicalStreamError.resetByPeer
        connection.testingSetStatus(.disconnected)
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertEqual(coordinator.failure as? USBLogicalStreamError, .resetByPeer)
        XCTAssertEqual(coordinator.failureMessage, AndroidUSBConnectionError.connectionLost.localizedDescription)
    }

    func testIntentionalStopDoesNotBecomeAPeerFailure() async throws {
        let runtime = Runtime()
        runtime.connection = connection()
        let coordinator = owner(runtime)
        try coordinator.connect(source: source(), peer: peer())
        try await wait { coordinator.phase == .connected }
        runtime.onRetire = { runtime.connectionEndFailure = USBHostMultiplexError.closed }
        coordinator.stop()
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertNil(coordinator.failure)
        runtime.onRetire = nil
    }

    func testSupersededAttemptRetiresOnlyCurrentConnectingOwner() async throws {
        let runtime = Runtime(), gate = Gate()
        runtime.runGate = gate
        defer { gate.release() }
        var authority: AndroidUSBAttemptAuthority?
        let coordinator = AndroidUSBConnectionCoordinator(factory: { _, _, current in
            authority = current; return runtime
        })
        try coordinator.connect(source: source(), peer: peer())
        try await wait { runtime.runs == 1 }
        let id = try XCTUnwrap(authority?.id)
        coordinator.invalidateSupersededAttempt(["fixture": id, "other": UUID()])
        XCTAssertEqual(runtime.retirements, 0)
        coordinator.invalidateSupersededAttempt(["fixture": UUID()])
        XCTAssertGreaterThan(runtime.retirements, 0)
        XCTAssertThrowsError(try authority?.requireCurrent())
        gate.release()
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(runtime.cleanups, 1)
    }

    func testExactTrustRevocationRetiresLiveOwner() async throws {
        let runtime = Runtime(), gate = Gate(), selected = try peer()
        runtime.runGate = gate
        defer { gate.release() }
        let coordinator = owner(runtime)
        try coordinator.connect(source: source(), peer: selected)
        try await wait { runtime.runs == 1 }
        func event(algorithm: ProtocolSigningAlgorithm, fingerprint: String) throws -> TrustInvalidationEvent {
            let record = TrustRecord(deviceId: selected.deviceID, pubKeyFP: fingerprint, publicKey: Data(),
                protocolSigningAlgorithm: algorithm, protocolPublicKeyFingerprint: fingerprint,
                signature: Data())
            return TrustInvalidationEvent(identities: [try XCTUnwrap(TrustInvalidationIdentity(record: record))])
        }
        // ML-DSA-87 requires a v2 raw-key binding; an invented legacy pin is
        // deliberately not a valid fixture. Ed25519 supplies a real alternative
        // authority type here, with the same fingerprint but a different algorithm.
        coordinator.invalidateTrust(try event(algorithm: .ed25519, fingerprint: selected.fingerprint))
        coordinator.invalidateTrust(try event(algorithm: .mlDSA65, fingerprint: String(repeating: "b", count: 64)))
        XCTAssertEqual(runtime.retirements, 0)
        coordinator.invalidateTrust(try event(algorithm: .mlDSA65, fingerprint: selected.fingerprint))
        XCTAssertGreaterThan(runtime.retirements, 0)
        gate.release()
        try await wait { !coordinator.isOccupied }
        XCTAssertEqual(coordinator.phase, .failed)
        XCTAssertNotNil(coordinator.failure)
    }

    func testFinalIdentityComparisonRequiresBothAlgorithmAndFingerprint() {
        let value = connection(), fingerprint = String(repeating: "a", count: 64)
        XCTAssertFalse(value.matchesAuthenticatedProtocolIdentity(algorithm: .mlDSA65, fingerprint: fingerprint))
        value.testingSetAuthenticatedRemoteAuthority(.init(protocolSigningAlgorithm: .mlDSA65,
            protocolPublicKeyFingerprint: fingerprint))
        XCTAssertTrue(value.matchesAuthenticatedProtocolIdentity(algorithm: .mlDSA65, fingerprint: fingerprint))
        XCTAssertFalse(value.matchesAuthenticatedProtocolIdentity(algorithm: .mlDSA87, fingerprint: fingerprint))
        XCTAssertFalse(value.matchesAuthenticatedProtocolIdentity(algorithm: .mlDSA65,
            fingerprint: String(repeating: "b", count: 64)))
    }

    func testNativeStartupCancellationRequiresReleaseAndNoOtherFailure() async throws {
        for kind in 0..<4 {
            let runtime = Runtime(), gate = Gate()
            runtime.runGate = gate
            defer { gate.release() }
            let native = USBHostFailure(SBUSBResult(status: kind == 1 ? SB_USB_NATIVE_FAILURE : SB_USB_CANCELLED,
                phase: SB_USB_PHASE_ACCESSORY_QUERY, domain: SB_USB_DOMAIN_NONE,
                nativeCode: 0, bytesTransferred: 0, byteCountKnown: false))
            let receipt = USBHostAccessoryReceipt(deviceRegistryID: 100, operationStarted: true,
                protocolVersion: 0, requestedLinkProfile: .epochV2, identificationAttempted: 0, identificationCompleted: 0,
                startRequested: false, startCompletionConfirmed: false, referencesReleased: kind != 2,
                operationFailure: native, cleanupFailure: kind == 3 ? native : nil)
            runtime.runFailure = USBHostAccessoryPreparationFailure(receipt: receipt, cause: CancellationError())
            let coordinator = owner(runtime)
            try coordinator.connect(source: source(), peer: peer())
            try await wait { runtime.runs == 1 }
            coordinator.stop(); gate.release()
            try await wait { !coordinator.isOccupied }
            XCTAssertEqual(coordinator.phase, kind == 0 ? .idle : .failed)
            XCTAssertEqual(coordinator.failure == nil, kind == 0)
            XCTAssertEqual(runtime.cleanups, 1)
        }
    }
}
#endif
