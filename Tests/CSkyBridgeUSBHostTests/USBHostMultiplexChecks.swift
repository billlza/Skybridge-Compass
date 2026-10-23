import Foundation
import SkyBridgeProtocolCore
import os
@testable import SkyBridgeAppleTransport

@main enum USBHostMultiplexChecks {
    static func framedLarge() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        defer { withExtendedLifetime((a, b)) {} }
        let expected = usbPattern(600_007)
        let send = Task { try await a.writeFrame(expected, timeout: .seconds(4), requireEffectAuthorization: {}) }
        let received = try await b.readFrame(timeout: .seconds(4))
        try await send.value; try usbCheck(received == expected, "Large framed body changed")
        try await f.close()
    }
    static func blockedBulkControl() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open(priority: .bulk)
        let bytes = usbPattern(700_011), done = OSAllocatedUnfairLock(initialState: false)
        let send = Task { try await a.writeFrame(bytes, timeout: .seconds(5), requireEffectAuthorization: {}); done.withLock { $0 = true } }
        try await usbEventually { f.b.protocolSnapshot.bufferedReceiveBytes == 262_144 && f.a.protocolSnapshot.pendingWriteBytes > 0 }
        try await f.sibling()
        try usbCheck(!done.withLock { $0 }, "Bulk did not remain blocked on receiver credit")
        let result = try await b.readFrame(timeout: .seconds(4)); try await send.value
        try usbCheck(result == bytes, "Credit replenishment lost bytes"); try await f.close()
    }
    static func readTimeoutSibling() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        try await usbExpect(USBHostMultiplexError.timedOut) { _ = try await b.readFrame(timeout: .milliseconds(40)) }
        try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func writeCreditDeadline() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open(priority: .bulk)
        try await usbExpect(USBHostMultiplexError.timedOut) {
            try await a.writeFrame(usbPattern(600_007), timeout: .milliseconds(120), requireEffectAuthorization: {})
        }
        try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func cancelRead() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        let read = Task { try await b.readFrame(timeout: .seconds(2)) }
        try await Task.sleep(for: .milliseconds(20)); read.cancel()
        try await usbExpect(CancellationError()) { _ = try await read.value }
        try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func queuedRevocation() async throws {
        let f = try USBMultiplexFixture(); try await f.start()
        let (blocked, blockedPeer) = try await f.open(), (target, targetPeer) = try await f.open()
        let id = blocked.id, targetID = target.id, gate = USBFixtureGate(), allowed = OSAllocatedUnfairLock(initialState: true)
        f.nativeA.state.withLock { value in value.beforeWrite = { bytes in
            let header = try USBLogicalStreamWire.decodeHeader(Data(bytes.prefix(12)))
            if header.type == .data && header.streamID == id { try gate.wait() }
        } }
        let holding = Task { try await blocked.writeBytes(Data([1]), timeout: .seconds(3), requireEffectAuthorization: {}) }
        try await usbEventually { gate.entered.withLock { $0 } }
        let sending = Task {
            try await target.writeBytes(Data([9, 8, 7]), timeout: .seconds(3), requireEffectAuthorization: {
                guard allowed.withLock({ $0 }) else { throw MultiplexFixtureError.revoked }
            })
        }
        try await usbEventually { f.a.protocolSnapshot.pendingWriteBytes >= 4 }
        allowed.withLock { $0 = false }; gate.release()
        try await holding.value
        try await usbExpect(MultiplexFixtureError.revoked) { try await sending.value }
        try usbCheck(!f.nativeA.state.withLock { $0.headers.contains { $0.type == .data && $0.streamID == targetID } }, "Revoked queued bytes entered native writer")
        f.nativeA.state.withLock { $0.beforeWrite = nil }
        for stream in [blocked, blockedPeer, target, targetPeer] { try await stream.closeAndAwait() }
        try await f.sibling(); try await f.close()
    }
    static func nativeRevocationPrecedesCleanup() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        defer { withExtendedLifetime((a, b)) {} }
        let allowed = OSAllocatedUnfairLock(initialState: true), closeGate = USBFixtureGate()
        f.nativeA.state.withLock { value in
            value.closeGate = closeGate
            value.afterWrite = { bytes in
                if try USBLogicalStreamWire.decodeHeader(Data(bytes.prefix(12))).type == .data { allowed.withLock { $0 = false } }
            }
        }
        try await usbExpect(MultiplexFixtureError.revoked) {
            try await a.writeBytes(Data([1, 3, 5]), timeout: .seconds(2), requireEffectAuthorization: {
                guard allowed.withLock({ $0 }) else { throw MultiplexFixtureError.revoked }
            })
        }
        try await usbEventually { closeGate.entered.withLock { $0 } }
        try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) { try await f.a.closeAndAwait(timeout: .milliseconds(30)) }
        closeGate.release(); try await f.close()
    }
    static func halfCloseReverse() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        try await a.finishSending()
        switch try await b.readBytes(maximumBytes: 1, timeout: .seconds(1)) {
        case .end: break
        case .bytes: throw MultiplexFixtureError.check("FIN was fabricated as bytes")
        }
        try await b.writeFrame(Data([17, 19]), timeout: .seconds(1), requireEffectAuthorization: {})
        try usbCheck(try await a.readFrame(timeout: .seconds(1)) == Data([17, 19]), "FIN blocked reverse direction")
        try await b.finishSending(); try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.close()
    }
    static func halfCloseDeadline() async throws {
        let f = try USBMultiplexFixture(configuration: .init(halfClose: .milliseconds(60)))
        try await f.start(); let (a, b) = try await f.open(); try await a.finishSending()
        try await usbExpect(USBHostMultiplexError.timedOut) { _ = try await a.readFrame(timeout: .seconds(1)) }
        try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func pendingAcceptExpires() async throws {
        let f = try USBMultiplexFixture(configuration: .init(pendingAccept: .milliseconds(60))); try await f.start()
        try await usbExpect(USBLogicalStreamError.resetByPeer) { _ = try await f.a.openStream(timeout: .seconds(1)) }
        try await usbEventually { f.a.protocolSnapshot.owners == 0 && f.b.protocolSnapshot.owners == 0 }
        try await f.sibling(); try await f.close()
    }
    static func droppedViewsRelease() async throws {
        let f = try USBMultiplexFixture(); try await f.start()
        func drop() async throws { let pair = try await f.open(); withExtendedLifetime(pair) {} }
        try await drop(); try await usbEventually { f.a.protocolSnapshot.owners == 0 && f.b.protocolSnapshot.owners == 0 }
        try await f.sibling(); try await f.close()
    }
    static func partialFrameFIN() async throws {
        let f = try USBMultiplexFixture(readLimit: 3); try await f.start(); let (a, b) = try await f.open()
        try await a.writeBytes(Data([0, 0]), timeout: .seconds(1), requireEffectAuthorization: {}); try await a.finishSending()
        try await usbExpect(USBHostMultiplexError.unexpectedEnd) { _ = try await b.readFrame(timeout: .seconds(1)) }
        try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func silentPeer() async throws {
        let f = try USBMultiplexFixture(configuration: .init(frameRead: .seconds(1), pingInterval: .milliseconds(40), pingReply: .milliseconds(40)))
        try await f.a.start()
        try await usbEventually { f.a.terminalFailure != nil }
        try usbCheck(f.a.terminalFailure as? USBHostMultiplexError == .timedOut, "Silent peer did not expire through its challenge")
        try await f.close()
    }
    static func livePings() async throws {
        let f = try USBMultiplexFixture(configuration: .init(frameRead: .seconds(1), pingInterval: .milliseconds(40), pingReply: .milliseconds(100)))
        try await f.start(); try await Task.sleep(for: .milliseconds(200))
        try usbCheck(f.a.terminalFailure == nil && f.b.terminalFailure == nil, "Matching pings did not keep transport alive")
        try await f.sibling(); try await f.close()
    }
    static func cancelledOpen() async throws {
        let f = try USBMultiplexFixture(), gate = USBFixtureGate()
        f.nativeA.state.withLock { $0.openGate = gate }
        let starting = Task { try await f.a.start() }
        try await usbEventually { gate.entered.withLock { $0 } }; f.a.close()
        try await usbExpect(USBHostMultiplexError.closed) { try await starting.value }
        try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) { try await f.a.closeAndAwait(timeout: .milliseconds(30)) }
        gate.release(); try await f.close()
    }
    static func parentAndStreamCleanup() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        let read = Task { try await a.readFrame(timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(10))
        let cleanup = Task { try await a.closeAndAwait() }
        try await usbEventually { a.isClosed }
        try await f.close(); try await cleanup.value
        try await usbExpect(USBLogicalStreamError.cancelled) { _ = try await read.value }
        try await b.closeAndAwait()
    }
    static func cancelledAcceptDoesNotConsumeIncomingOwner() async throws {
        let f = try USBMultiplexFixture(); try await f.start()
        let accepting = Task { try await f.a.acceptStream(timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(10)); accepting.cancel()
        try await usbExpect(CancellationError()) { _ = try await accepting.value }
        try await f.sibling(); try await f.close()
    }
    static func wakeCancellationAndDeadlineReuse() async throws {
        let wake = USBMultiplexWake()
        for _ in 0..<32 {
            let waiting = Task { try await wake.wait() }
            await Task.yield(); waiting.cancel()
            try await usbExpect(CancellationError()) { try await waiting.value }
            wake.signal(); try await wake.wait()
            let signalled = try await wake.wait(until: .now.advanced(by: .milliseconds(1)))
            try usbCheck(!signalled, "Deadline manufactured a notification")
            wake.signal(); try await wake.wait()
        }
    }
    static func oversizedHeaderFailsBeforeBodyRead() async throws {
        let f = try USBMultiplexFixture(); try await f.a.start()
        try f.nativeB.inject(Data([0, 0, 0, 0, 0, 0, 0, 2, 0, 4, 0, 1]))
        try await usbEventually { f.a.terminalFailure != nil }
        try usbCheck(f.a.terminalFailure as? USBLogicalStreamError == .invalidHeader("data exceeds advertised receive window"), "Oversized header was not rejected")
        try await f.close()
    }
    static func closeErrorRetainsReleaseFacts() async throws {
        let f = try USBMultiplexFixture(); try await f.start()
        f.nativeA.state.withLock { $0.closeFailure = true }; f.a.close(); f.b.close()
        try await usbExpect(MultiplexFixtureError.closeFailed) { try await f.a.closeAndAwait() }
        try await f.b.closeAndAwait()
        let state = f.a.shutdownState
        try usbCheck(state.referencesReleased && state.nativeWorkersExited && state.pumpsJoined && state.logicalOwnersReleased,
                     "Native close error was confused with unresolved owners")
        try usbCheck(state.cleanupFailure as? MultiplexFixtureError == .closeFailed, "Native close failure disappeared")
    }
    static func main() async {
        let tests: [(String, () async throws -> Void)] = [
            ("large_frame_across_credit_windows", framedLarge), ("blocked_bulk_keeps_control_live", blockedBulkControl),
            ("logical_read_timeout_keeps_sibling", readTimeoutSibling), ("write_deadline_includes_credit_wait", writeCreditDeadline),
            ("cancel_read_keeps_sibling", cancelRead), ("revoked_queued_data_never_enters_native_io", queuedRevocation),
            ("native_revocation_precedes_blocked_cleanup", nativeRevocationPrecedesCleanup), ("half_close_preserves_reverse", halfCloseReverse),
            ("half_close_deadline_is_local", halfCloseDeadline), ("pending_accept_expires", pendingAcceptExpires),
            ("dropped_views_release_owners", droppedViewsRelease), ("partial_frame_fin_is_failure", partialFrameFIN),
            ("silent_peer_expires", silentPeer), ("matching_pings_keep_transport_live", livePings),
            ("cancelled_open_never_publishes_pumps", cancelledOpen), ("parent_and_stream_cleanup_waiters", parentAndStreamCleanup),
            ("cancelled_accept_releases_waiter", cancelledAcceptDoesNotConsumeIncomingOwner),
            ("notification_cancellation_and_deadline_reuse", wakeCancellationAndDeadlineReuse),
            ("oversized_header_before_allocation", oversizedHeaderFailsBeforeBodyRead),
            ("native_close_error_preserves_release_facts", closeErrorRetainsReleaseFacts)
        ]
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { print("FAIL \(name): \(error)"); exit(1) }
        }
        print("PASS \(tests.count) cases; synthetic acquisition, no physical USB/audio acceptance")
    }
}
