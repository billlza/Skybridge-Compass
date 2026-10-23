#if os(macOS)
import Foundation
import os
@testable import SkyBridgeAppleTransport

private enum FixtureFailure: Error, Equatable { case failed(String), nativeRead, nativeWrite, revoked, close, abort }
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw FixtureFailure.failed(message) }
}
private func eventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate() {
        try check(ContinuousClock.now < deadline, "Fixture wait expired")
        try await Task.sleep(for: .milliseconds(1))
    }
}
private func expect(_ expected: any Error, _ action: () async throws -> Void) async throws {
    do { try await action() }
    catch {
        if let a = error as? USBHostByteError, let b = expected as? USBHostByteError { try check(a == b, "Wrong USB error: \(a), wanted \(b)"); return }
        if let a = error as? FixtureFailure, let b = expected as? FixtureFailure { try check(a == b, "Wrong fixture error"); return }
        if error is CancellationError, expected is CancellationError { return }
        throw FixtureFailure.failed("Wrong error: \(error), wanted \(expected)")
    }
    throw FixtureFailure.failed("Expected failure: \(expected)")
}

private final class Fixture: USBHostDriver {
    enum Call: Int, Sendable { case open, read, write, abort, close }
    struct State: Sendable {
        var calls = [Int](repeating: 0, count: 5)
        var active = Set<Int>()
        var blocked = Set<Int>()
        var retired = false
        var cleanupWhileActive = false
        var chunks: [Data] = []
        var infiniteZero = false
        var written: [Data] = []
        var readFailure: FixtureFailure?
        var writeFailure: FixtureFailure?
        var closeFailure: FixtureFailure?
        var abortFailure: FixtureFailure?
        var released = true
    }
    let state: OSAllocatedUnfairLock<State>
    private let gates = (0..<5).map { _ in DispatchSemaphore(value: 0) }
    init(_ configure: (inout State) -> Void = { _ in }) {
        var state = State(); configure(&state); self.state = OSAllocatedUnfairLock(initialState: state)
    }
    func count(_ call: Call) -> Int { state.withLock { $0.calls[call.rawValue] } }
    func permit(_ call: Call) { gates[call.rawValue].signal() }
    private func enter(_ call: Call) throws {
        let blocked = state.withLock { value in
            value.calls[call.rawValue] += 1; value.active.insert(call.rawValue)
            if call == .close { value.cleanupWhileActive = value.active.contains(Call.read.rawValue) || value.active.contains(Call.write.rawValue) || value.active.contains(Call.open.rawValue) }
            return value.blocked.contains(call.rawValue)
        }
        if blocked { try check(gates[call.rawValue].wait(timeout: .now() + .seconds(3)) == .success, "Native gate not released") }
    }
    private func leave(_ call: Call) { state.withLock { _ = $0.active.remove(call.rawValue) } }
    func open(registryID: UInt64) throws -> USBHostDevice {
        try enter(.open); defer { leave(.open) }
        return USBHostDevice(deviceRegistryID: registryID, interfaceRegistryID: 456, inputPacketSize: 512,
                             outputPacketSize: 512, inputEndpoint: 0x87, outputEndpoint: 3)
    }
    func read(timeoutMilliseconds: UInt32) throws -> Data {
        try check(timeoutMilliseconds > 0 && timeoutMilliseconds <= 60_000, "Invalid native read deadline")
        try enter(.read); defer { leave(.read) }
        return try state.withLock { value in
            if let failure = value.readFailure { throw failure }
            if value.infiniteZero { return Data() }
            guard !value.chunks.isEmpty else { throw FixtureFailure.failed("Unexpected fixture read") }
            return value.chunks.removeFirst()
        }
    }
    func write(_ bytes: Data, timeoutMilliseconds: UInt32) throws {
        try check(timeoutMilliseconds > 0 && timeoutMilliseconds <= 60_000, "Invalid native write deadline")
        try state.withLock { if $0.retired { throw USBHostByteError.closed } }
        try enter(.write); defer { leave(.write) }
        try state.withLock { value in
            if let failure = value.writeFailure { throw failure }; value.written.append(bytes)
        }
    }
    func retire() { state.withLock { $0.retired = true } }
    func interrupt() -> (any Error)? {
        do { try enter(.abort); leave(.abort); return state.withLock { $0.abortFailure } } catch { return error }
    }
    func closeAndRelease() -> USBHostCleanup {
        do { try enter(.close); leave(.close); return state.withLock { USBHostCleanup(referencesReleased: $0.released, failure: $0.closeFailure) } }
        catch { return USBHostCleanup(referencesReleased: false, failure: error) }
    }
    func transport() -> USBHostByteTransport { USBHostByteTransport(deviceRegistryID: 123, driver: self, requireAttachmentCurrent: {}) }
}

@main private enum USBHostByteTransportChecks {
    static func idleClose() async throws {
        let fixture = Fixture(), transport = fixture.transport()
        try await transport.closeAndAwait()
        try check(fixture.count(.open) == 0 && fixture.count(.close) == 1, "Idle close did not release")
    }
    static func limits() async throws {
        let fixture = Fixture(), transport = fixture.transport()
        do {
            try await expect(USBHostByteError.notReady) { _ = try await transport.readBytes(maximumBytes: 1, timeout: .seconds(1)) }
            try await expect(USBHostByteError.invalidTimeout) { _ = try await transport.open(timeout: .zero) }
            _ = try await transport.open(timeout: .seconds(1))
            try await expect(USBHostByteError.alreadyStarted) { _ = try await transport.open(timeout: .seconds(1)) }
            try await expect(USBHostByteError.invalidByteCount) { _ = try await transport.readBytes(maximumBytes: 16_385, timeout: .seconds(1)) }
            try await expect(USBHostByteError.invalidByteCount) { try await transport.writeBytes(Data(), timeout: .seconds(1), requireEffectAuthorization: {}) }
            try await expect(USBHostByteError.invalidTimeout) { _ = try await transport.readBytes(maximumBytes: 1, timeout: .seconds(61)) }
        }
        try check(transport.terminalFailure == nil, "Argument errors retired a healthy owner")
        try await transport.closeAndAwait()
    }
    static func packetTails() async throws {
        let fixture = Fixture { $0.chunks = [Data(), Data([1, 2, 3, 4, 5, 6]), Data([7, 8, 9, 10])] }
        let transport = fixture.transport(); _ = try await transport.open(timeout: .seconds(1))
        let a = try await transport.readBytes(maximumBytes: 3, timeout: .seconds(1))
        let b = try await transport.readBytes(maximumBytes: 10, timeout: .seconds(1))
        try check(a + b == Data([1, 2, 3, 4, 5, 6]) && fixture.count(.read) == 2, "Tail dropped or redundant read")
        let c = try await transport.readBytes(maximumBytes: 16_384, timeout: .seconds(1))
        try check(c == Data([7, 8, 9, 10]), "Packet stream changed bytes")
        try await transport.closeAndAwait()
    }
    static func sliceWrite() async throws {
        let fixture = Fixture(), transport = fixture.transport(); _ = try await transport.open(timeout: .seconds(1))
        let original = Data([0, 1, 2, 3, 4, 5, 6]), slice = original[2..<6]
        let checks = OSAllocatedUnfairLock(initialState: 0)
        try await transport.writeBytes(slice, timeout: .seconds(1), requireEffectAuthorization: { checks.withLock { $0 += 1 } })
        try check(fixture.state.withLock { $0.written } == [Data([2, 3, 4, 5])] && checks.withLock { $0 } == 2, "Write/authority scope changed")
        try await transport.closeAndAwait()
    }
    static func ownedWriteCancellationWaitsForNativeReturn() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.write.rawValue] }, transport = fixture.transport()
        _ = try await transport.open(timeout: .seconds(1))
        let finished = OSAllocatedUnfairLock(initialState: false)
        let writing = Task {
            defer { finished.withLock { $0 = true } }
            try await transport.writeBytesAndAwaitNativeCompletion(Data([1, 2]), timeout: .seconds(2), requireEffectAuthorization: {})
        }
        defer { fixture.permit(.write) }
        try await eventually { fixture.count(.write) == 1 }
        writing.cancel(); try await eventually { transport.terminalFailure != nil }
        try check(!finished.withLock { $0 }, "Owned write returned before native execution ended")
        try await expect(USBHostByteError.cleanupUnconfirmed) { try await transport.closeAndAwait(timeout: .milliseconds(30)) }
        try check(!finished.withLock { $0 } && fixture.count(.close) == 0, "Failure response was used as native completion")
        fixture.permit(.write)
        try await expect(CancellationError()) { try await writing.value }
        try await transport.closeAndAwait()
        try check(finished.withLock { $0 } && !fixture.state.withLock { $0.cleanupWhileActive }, "Owned completion or cleanup missing")
    }
    static func ownedWriteRejectedBeforeAdmissionDoesNotWaitForAnotherRequest() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.write.rawValue] }, transport = fixture.transport()
        try await expect(USBHostByteError.invalidByteCount) {
            try await transport.writeBytesAndAwaitNativeCompletion(Data(), timeout: .seconds(1), requireEffectAuthorization: {})
        }
        try await expect(USBHostByteError.notReady) {
            try await transport.writeBytesAndAwaitNativeCompletion(Data([1]), timeout: .seconds(1), requireEffectAuthorization: {})
        }
        _ = try await transport.open(timeout: .seconds(1))
        let first = Task { try await transport.writeBytesAndAwaitNativeCompletion(Data([2]), timeout: .seconds(2), requireEffectAuthorization: {}) }
        defer { fixture.permit(.write) }
        try await eventually { fixture.count(.write) == 1 }
        try await expect(USBHostByteError.writeInProgress) {
            try await transport.writeBytesAndAwaitNativeCompletion(Data([3]), timeout: .seconds(1), requireEffectAuthorization: {})
        }
        try check(transport.terminalFailure == nil && fixture.count(.write) == 1, "Foreign admission altered the active writer")
        fixture.permit(.write); try await first.value; try await transport.closeAndAwait()
        try check(fixture.state.withLock { $0.written } == [Data([2])], "Rejected write reached the device")
    }
    static func cancelBlockedRead() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.read.rawValue]; $0.chunks = [Data([1])] }
        let transport = fixture.transport(); _ = try await transport.open(timeout: .seconds(1))
        let read = Task { try await transport.readBytes(maximumBytes: 1, timeout: .seconds(2)) }
        try await eventually { fixture.count(.read) == 1 }; read.cancel()
        try await expect(CancellationError()) { _ = try await read.value }
        try await expect(USBHostByteError.cleanupUnconfirmed) { try await transport.closeAndAwait(timeout: .milliseconds(30)) }
        try check(fixture.count(.close) == 0, "Close raced active reader")
        try check(transport.shutdownState.retired && !transport.shutdownState.workersExited &&
                  !transport.shutdownState.referencesReleased, "Pending cleanup incorrectly confirmed")
        fixture.permit(.read); try await transport.closeAndAwait()
        try check(!fixture.state.withLock { $0.cleanupWhileActive }, "Cleanup preceded native worker return")
    }
    static func openDeadline() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.open.rawValue] }, transport = fixture.transport()
        let opening = Task { try await transport.open(timeout: .milliseconds(40)) }
        try await eventually { fixture.count(.open) == 1 }
        try await expect(USBHostByteError.timedOut) { _ = try await opening.value }
        try await expect(USBHostByteError.cleanupUnconfirmed) { try await transport.closeAndAwait(timeout: .milliseconds(20)) }
        fixture.permit(.open); try await transport.closeAndAwait()
        try check(fixture.count(.close) == 1, "Late open leaked")
    }
    static func zeroDeadline() async throws {
        let fixture = Fixture { $0.infiniteZero = true }, transport = fixture.transport()
        _ = try await transport.open(timeout: .seconds(1))
        try await expect(USBHostByteError.timedOut) { _ = try await transport.readBytes(maximumBytes: 12, timeout: .milliseconds(30)) }
        try check(fixture.count(.read) > 1, "Zero-length packets not exercised")
        try await transport.closeAndAwait()
    }
    static func replacedDeadline() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.read.rawValue]; $0.chunks = [Data([1]), Data([2])] }
        let transport = fixture.transport(); _ = try await transport.open(timeout: .seconds(1))
        fixture.permit(.read)
        _ = try await transport.readBytes(maximumBytes: 1, timeout: .milliseconds(50))
        let next = Task { try await transport.readBytes(maximumBytes: 1, timeout: .seconds(1)) }
        try await eventually { fixture.count(.read) == 2 }
        try await Task.sleep(for: .milliseconds(80))
        try check(transport.terminalFailure == nil, "Old read deadline retired its successor")
        fixture.permit(.read); let bytes = try await next.value
        try check(bytes == Data([2]), "Next request returned the wrong bytes")
        try await transport.closeAndAwait()
    }
    static func attachmentRevoked() async throws {
        let fixture = Fixture(), current = OSAllocatedUnfairLock(initialState: true)
        let transport = USBHostByteTransport(deviceRegistryID: 123, driver: fixture, requireAttachmentCurrent: {
            guard current.withLock({ $0 }) else { throw FixtureFailure.revoked }
        })
        _ = try await transport.open(timeout: .seconds(1)); current.withLock { $0 = false }
        try await expect(FixtureFailure.revoked) { _ = try await transport.readBytes(maximumBytes: 1, timeout: .seconds(1)) }
        try check(fixture.count(.read) == 0, "Stale attachment entered native I/O")
        try await transport.closeAndAwait()
    }
    static func cancelDuringAuthorization() async throws {
        let fixture = Fixture(), transport = fixture.transport(); _ = try await transport.open(timeout: .seconds(1))
        let entered = OSAllocatedUnfairLock(initialState: false), gate = DispatchSemaphore(value: 0)
        let writing = Task {
            try await transport.writeBytes(Data([1]), timeout: .seconds(2), requireEffectAuthorization: {
                entered.withLock { $0 = true }
                try check(gate.wait(timeout: .now() + .seconds(3)) == .success, "Authority gate not released")
            })
        }
        try await eventually { entered.withLock { $0 } }
        transport.close()
        try await expect(USBHostByteError.closed) { try await writing.value }
        try check(fixture.count(.close) == 0, "Cleanup did not await authority callback")
        gate.signal(); try await transport.closeAndAwait()
        try check(fixture.count(.write) == 0, "Retired authorization emitted native bytes")
    }
    static func revokeAfterWrite() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.close.rawValue] }, transport = fixture.transport()
        _ = try await transport.open(timeout: .seconds(1)); let checks = OSAllocatedUnfairLock(initialState: 0)
        try await expect(FixtureFailure.revoked) {
            try await transport.writeBytes(Data([1]), timeout: .seconds(1), requireEffectAuthorization: {
                try checks.withLock { value in value += 1; if value == 2 { throw FixtureFailure.revoked } }
            })
        }
        try await eventually { fixture.count(.close) == 1 }
        try check(transport.terminalFailure as? FixtureFailure == .revoked, "Close masked revocation")
        fixture.permit(.close); try await transport.closeAndAwait()
        try check(fixture.count(.write) == 1, "Partial write retried")
    }
    static func duplexAndBusy() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.read.rawValue, Fixture.Call.write.rawValue]; $0.chunks = [Data([1])] }
        let transport = fixture.transport(); _ = try await transport.open(timeout: .seconds(1))
        let read = Task { try await transport.readBytes(maximumBytes: 1, timeout: .seconds(2)) }
        let write = Task { try await transport.writeBytes(Data([2]), timeout: .seconds(2), requireEffectAuthorization: {}) }
        try await eventually { fixture.count(.read) == 1 && fixture.count(.write) == 1 }
        try await expect(USBHostByteError.readInProgress) { _ = try await transport.readBytes(maximumBytes: 1, timeout: .seconds(1)) }
        try await expect(USBHostByteError.writeInProgress) { try await transport.writeBytes(Data([3]), timeout: .seconds(1), requireEffectAuthorization: {}) }
        try check(transport.terminalFailure == nil, "Duplicate admission retired owner")
        fixture.permit(.read); fixture.permit(.write)
        _ = try await read.value; try await write.value; try await transport.closeAndAwait()
    }
    static func failureRetiresSibling() async throws {
        let fixture = Fixture { $0.blocked = [Fixture.Call.read.rawValue, Fixture.Call.write.rawValue]; $0.readFailure = .nativeRead }
        let transport = fixture.transport(); _ = try await transport.open(timeout: .seconds(1))
        let read = Task { try await transport.readBytes(maximumBytes: 1, timeout: .seconds(2)) }
        let write = Task { try await transport.writeBytes(Data([2]), timeout: .seconds(2), requireEffectAuthorization: {}) }
        try await eventually { fixture.count(.read) == 1 && fixture.count(.write) == 1 }
        fixture.permit(.read)
        try await expect(FixtureFailure.nativeRead) { _ = try await read.value }
        try await expect(FixtureFailure.nativeRead) { try await write.value }
        try check(fixture.count(.close) == 0, "Failed sibling released active writer")
        fixture.permit(.write); try await transport.closeAndAwait()
    }
    static func cleanupOutcomes() async throws {
        for mode in 0..<3 {
            let fixture = Fixture {
                if mode == 0 { $0.closeFailure = .close }
                if mode == 1 { $0.released = false }
                if mode == 2 { $0.abortFailure = .abort }
            }, transport = fixture.transport()
            _ = try await transport.open(timeout: .seconds(1))
            let error: any Error
            if mode == 0 { error = FixtureFailure.close }
            else if mode == 1 { error = USBHostByteError.cleanupUnconfirmed }
            else { error = FixtureFailure.abort }
            try await expect(error) { try await transport.closeAndAwait() }
            try check(fixture.count(.close) == 1, "Repeated native release")
            let status = transport.shutdownState
            try check(status.retired && status.workersExited && status.referencesReleased == (mode != 1), "Cleanup facts conflated")
        }
    }
    static func deinitRetires() async throws {
        let fixture = Fixture()
        func scope() { let transport = fixture.transport(); withExtendedLifetime(transport) {} }
        scope(); try await eventually { fixture.count(.close) == 1 }
    }
    static func nativeAbsent() async throws {
        let transport = try USBHostByteTransport(deviceRegistryID: UInt64.max, requireAttachmentCurrent: {})
        do { _ = try await transport.open(timeout: .seconds(1)); throw FixtureFailure.failed("Absent device was opened") }
        catch let error as USBHostFailure { try check(error.status == 2 && error.phase == 2, "Unexpected native absence error") }
        try await transport.closeAndAwait()
    }
    static func main() async throws {
        let tests: [(String, () async throws -> Void)] = [
            ("idle_close", idleClose), ("limits_and_single_use", limits), ("packet_tails_and_zlp", packetTails),
            ("sliced_write_and_effect", sliceWrite), ("cancel_blocked_native_read", cancelBlockedRead),
            ("owned_write_waits_for_native_return", ownedWriteCancellationWaitsForNativeReturn),
            ("owned_rejection_does_not_wait_for_foreign_write", ownedWriteRejectedBeforeAdmissionDoesNotWaitForAnotherRequest),
            ("late_open_deadline", openDeadline), ("zero_packets_whole_deadline", zeroDeadline),
            ("completed_deadline_does_not_cancel_successor", replacedDeadline), ("attachment_revocation", attachmentRevoked),
            ("cancel_in_authorization_callback", cancelDuringAuthorization), ("post_write_revocation", revokeAfterWrite),
            ("duplex_and_busy_admission", duplexAndBusy), ("io_failure_retires_sibling", failureRetiresSibling),
            ("cleanup_outcomes", cleanupOutcomes), ("deinit_retires", deinitRetires), ("native_absent", nativeAbsent)
        ]
        for (name, test) in tests { try await test(); print("PASS \(name)") }
        print("PASS \(tests.count) cases; no physical USB data or audio acceptance")
    }
}
#endif
