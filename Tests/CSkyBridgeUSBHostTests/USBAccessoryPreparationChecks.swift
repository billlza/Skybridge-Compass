#if os(macOS)
import CSkyBridgeUSBHost
import Foundation
import os
@testable import SkyBridgeAppleTransport

private enum CheckFailure: Error, Equatable { case failed(String), revoked, factory }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}
private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition() {
        try check(ContinuousClock.now < deadline, "Fixture wait expired")
        try await Task.sleep(for: .milliseconds(1))
    }
}
private func fail(_ action: () async throws -> Void) async throws -> any Error {
    do { try await action() } catch { return error }
    throw CheckFailure.failed("Expected an explicit failure")
}
private func nativeFailure(_ status: SBUSBStatus, phase: SBUSBPhase = SB_USB_PHASE_ACCESSORY_QUERY) -> USBHostFailure {
    USBHostFailure(SBUSBResult(status: status, phase: phase, domain: SB_USB_DOMAIN_NONE,
        nativeCode: 0, bytesTransferred: 0, byteCountKnown: false))
}

private final class Driver: USBHostAccessoryDriver {
    struct State: Sendable {
        var calls = 0
        var entered = false
        var closing = false
        var blockBeforeRequest = false
        var blockCleanup = false
        var released = true
        var cleanupFailure: USBHostFailure?
    }
    let state: OSAllocatedUnfairLock<State>
    let beforeRequest = DispatchSemaphore(value: 0)
    let cleanup = DispatchSemaphore(value: 0)
    init(_ configure: (inout State) -> Void = { _ in }) {
        var value = State(); configure(&value); state = OSAllocatedUnfairLock(initialState: value)
    }
    func run(registryID: UInt64, nonce: UUID?, authorize: @escaping @Sendable () -> Bool) -> USBHostAccessoryReceipt {
        let blocked = state.withLock { value in value.calls += 1; value.entered = true; return value.blockBeforeRequest }
        if blocked { precondition(beforeRequest.wait(timeout: .now() + 3) == .success) }
        let admitted = authorize()
        let closing = state.withLock { value in value.closing = true; return value.blockCleanup }
        if closing { precondition(cleanup.wait(timeout: .now() + 3) == .success) }
        let snapshot = state.withLock { $0 }
        return USBHostAccessoryReceipt(deviceRegistryID: registryID, operationStarted: true, protocolVersion: admitted ? 2 : 0,
            identificationAttempted: admitted && nonce != nil ? 6 : 0, identificationCompleted: admitted && nonce != nil ? 6 : 0,
            startRequested: admitted && nonce != nil, startCompletionConfirmed: admitted && nonce != nil,
            referencesReleased: snapshot.released,
            operationFailure: admitted ? nil : nativeFailure(SB_USB_CANCELLED), cleanupFailure: snapshot.cleanupFailure)
    }
}

@main private struct Checks {
    static func main() async {
        do { try await run(); FileHandle.standardOutput.write(Data("PASS accessory Swift ownership checks\n".utf8)) }
        catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
    }
    private static func run() async throws {
        try await retiredBeforeRun()
        try await successfulSingleUse()
        try await cancelledAcquisition()
        try await cancelledCleanup()
        try await revokedAuthority()
        try await retainedCleanupFailure()
        try await failureBeforeNativeAcquisition()
        try await actualAbsentDevice()
    }
    private static func owner(_ driver: Driver, authority: @escaping @Sendable () throws -> Void = {}) -> USBHostAccessoryPreparation {
        USBHostAccessoryPreparation(deviceRegistryID: 123, mode: .start(attachmentNonce: UUID()), authority: authority, factory: { driver })
    }
    private static func pass(_ name: String) { FileHandle.standardOutput.write(Data("PASS \(name)\n".utf8)) }
    private static func retiredBeforeRun() async throws {
        let driver = Driver(), preparation = owner(driver)
        try await preparation.closeAndAwait()
        let error = try await fail { _ = try await preparation.run() }
        try check(error is CancellationError, "A released owner admitted a new worker instead of rejecting before startup")
        try check(preparation.workerExited && preparation.receipt == nil && driver.state.withLock { $0.calls == 0 }, "Retired owner acquired work")
        pass("retirement-before-run-is-final")
    }
    private static func successfulSingleUse() async throws {
        let driver = Driver(), preparation = owner(driver)
        let receipt = try await preparation.run()
        try await preparation.closeAndAwait()
        try check(receipt.startRequested && receipt.startCompletionConfirmed && receipt.referencesReleased && preparation.workerExited, "Startup facts lost")
        let error = try await fail { _ = try await preparation.run() }
        try check(error as? USBHostByteError == .alreadyStarted && driver.state.withLock { $0.calls == 1 }, "Repeated mode request")
        pass("one-run-one-native-owner")
    }
    private static func cancelledAcquisition() async throws {
        let driver = Driver { $0.blockBeforeRequest = true }, preparation = owner(driver)
        let running = Task { try await preparation.run() }
        try await eventually { driver.state.withLock { $0.entered } }
        running.cancel()
        let early = try await fail { try await preparation.closeAndAwait(timeout: .milliseconds(10)) }
        try check(early as? USBHostByteError == .cleanupUnconfirmed && !preparation.workerExited, "Blocked worker falsely released")
        driver.beforeRequest.signal()
        let error = try await fail { _ = try await running.value }
        guard let failure = error as? USBHostAccessoryPreparationFailure else { throw error }
        try check(failure.cause is CancellationError && !failure.receipt.startRequested && failure.receipt.referencesReleased, "Cancelled acquisition submitted mode change")
        try await preparation.closeAndAwait()
        pass("cancelled-acquisition-remains-owned")
    }
    private static func cancelledCleanup() async throws {
        let driver = Driver { $0.blockCleanup = true }, preparation = owner(driver)
        let running = Task { try await preparation.run() }
        try await eventually { driver.state.withLock { $0.closing } }
        let cancelReturned = OSAllocatedUnfairLock(initialState: false)
        let cancelling = Task.detached { preparation.cancel(); cancelReturned.withLock { $0 = true } }
        try await eventually { cancelReturned.withLock { $0 } }
        await cancelling.value
        let early = try await fail { try await preparation.closeAndAwait(timeout: .milliseconds(10)) }
        try check(early as? USBHostByteError == .cleanupUnconfirmed, "Cleanup was reported complete before release returned")
        driver.cleanup.signal()
        let error = try await fail { _ = try await running.value }
        guard let failure = error as? USBHostAccessoryPreparationFailure else { throw error }
        try check(failure.cause is CancellationError && failure.receipt.startCompletionConfirmed,
                  "Cancellation hid a completed mode change")
        try await preparation.closeAndAwait()
        pass("retirement-does-not-block-behind-native-release")
    }
    private static func revokedAuthority() async throws {
        let driver = Driver { $0.blockBeforeRequest = true }
        let valid = OSAllocatedUnfairLock(initialState: true)
        let preparation = owner(driver) { if !valid.withLock({ $0 }) { throw CheckFailure.revoked } }
        let running = Task { try await preparation.run() }
        try await eventually { driver.state.withLock { $0.entered } }
        valid.withLock { $0 = false }; driver.beforeRequest.signal()
        let error = try await fail { _ = try await running.value }
        guard let failure = error as? USBHostAccessoryPreparationFailure else { throw error }
        try check(failure.cause as? CheckFailure == .revoked && !failure.receipt.startRequested, "Replaced attempt remained authorized")
        try await preparation.closeAndAwait()
        pass("captured-attempt-authority-is-rechecked")
    }
    private static func retainedCleanupFailure() async throws {
        let driver = Driver { $0.released = false }, preparation = owner(driver)
        let error = try await fail { _ = try await preparation.run() }
        guard let failure = error as? USBHostAccessoryPreparationFailure else { throw error }
        try check(!failure.receipt.referencesReleased && failure.receipt.startCompletionConfirmed, "Unknown release treated as success")
        let cleanup = try await fail { try await preparation.closeAndAwait() }
        try check(cleanup as? USBHostByteError == .cleanupUnconfirmed && preparation.workerExited, "Release and worker exit conflated")
        pass("unconfirmed-reference-release-is-retained")
    }
    private static func failureBeforeNativeAcquisition() async throws {
        let preparation = USBHostAccessoryPreparation(deviceRegistryID: 123, mode: .query, authority: {}, factory: { throw CheckFailure.factory })
        let error = try await fail { _ = try await preparation.run() }
        guard let failure = error as? USBHostAccessoryPreparationFailure else { throw error }
        try check(failure.cause as? CheckFailure == .factory && !failure.receipt.operationStarted && failure.receipt.referencesReleased, "Factory error masked")
        try await preparation.closeAndAwait()
        pass("allocation-failure-is-not-native-success")
    }
    private static func actualAbsentDevice() async throws {
        let preparation = try USBHostAccessoryPreparation(deviceRegistryID: .max, mode: .query, requireAttemptCurrent: {})
        let error = try await fail { _ = try await preparation.run() }
        guard let failure = error as? USBHostAccessoryPreparationFailure else { throw error }
        try check(failure.receipt.operationFailure?.status == SB_USB_UNAVAILABLE.rawValue && failure.receipt.referencesReleased,
                  "Missing registry entry did not propagate with cleanup")
        try await preparation.closeAndAwait()
        pass("actual-native-absent-device-is-cleaned")
    }
}
#endif
