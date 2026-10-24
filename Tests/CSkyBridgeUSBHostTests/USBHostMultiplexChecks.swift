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
        try usbCheck(f.a.protocolSnapshot.owners == 0, "Canceled acquisition published a logical stream")
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
    static func epochLargeAndNativeFragments() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2)); try await f.start()
        let (a, b) = try await f.open()
        let expected = Data((0..<900_003).map { $0 % 2 == 0 ? UInt8(0x7d) : 0x7e })
        let sending = Task { try await a.writeFrame(expected, timeout: .seconds(10), requireEffectAuthorization: {}) }
        let received = try await b.readFrame(timeout: .seconds(10)); try await sending.value
        try usbCheck(received == expected, "Epoch changed escaped payload")
        try usbCheck(f.a.epochSnapshot?.phase == .ready && f.b.epochSnapshot?.phase == .ready, "Epoch did not establish")
        try usbCheck(f.nativeA.state.withLock { $0.linkRecords > 50 && $0.maximumWrite <= 16_384 }, "Epoch transfer bounds not exercised")
        try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func epochBlockedBulkKeepsControlLive() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2)); try await f.start()
        let (a, b) = try await f.open(priority: .bulk), expected = usbPattern(700_011)
        let done = OSAllocatedUnfairLock(initialState: false)
        let sending = Task { try await a.writeFrame(expected, timeout: .seconds(8), requireEffectAuthorization: {}); done.withLock { $0 = true } }
        try await usbEventually { f.b.protocolSnapshot.bufferedReceiveBytes == 262_144 && f.a.protocolSnapshot.pendingWriteBytes > 0 }
        try await f.sibling(); try usbCheck(!done.withLock { $0 }, "Epoch bulk bypassed receive credit")
        let received = try await b.readFrame(timeout: .seconds(6)); try await sending.value
        try usbCheck(received == expected, "Epoch credit replenishment lost data"); try await f.close()
    }
    static func epochEarlyDataWaitsForWriteCallback() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2)), gate = USBFixtureGate()
        let accessoryDone = OSAllocatedUnfairLock(initialState: false)
        f.nativeB.state.withLock { $0.afterLink = { record in if record.kind == .ready { try gate.wait() } } }
        defer { gate.release() }
        let host = Task { try await f.a.start() }
        let accessory = Task { try await f.b.start(); accessoryDone.withLock { $0 = true } }
        try await usbEventually { gate.entered.withLock { $0 } }; try await host.value
        try usbCheck(!accessoryDone.withLock { $0 } && f.b.epochSnapshot?.phase == .starting, "Readiness preceded native callback")
        try await usbExpect(USBHostMultiplexError.notStarted) { _ = try await f.b.acceptStream(timeout: .milliseconds(100)) }
        let opening = Task { try await f.a.openStream(timeout: .seconds(3)) }
        try await usbEventually { (f.b.epochSnapshot?.bufferedBytes ?? 0) >= 12 }
        try usbCheck(f.b.protocolSnapshot.owners == 0, "Provisional payload entered logical parser")
        gate.release(); try await accessory.value
        let peer = try await f.b.acceptStream(timeout: .seconds(2)), source = try await opening.value
        try await source.writeFrame(Data([37]), timeout: .seconds(1), requireEffectAuthorization: {})
        try usbCheck(try await peer.readFrame(timeout: .seconds(1)) == Data([37]), "Early data needed an unrelated extra packet")
        try await f.close()
    }
    static func epochSilentPeerCannotPublishStart() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2))
        try await usbExpect(USBHostMultiplexError.timedOut) { try await f.a.start(timeout: .milliseconds(250)) }
        try usbCheck(f.a.epochSnapshot?.phase == .failed, "Silent peer became usable")
        try usbCheck(f.nativeA.state.withLock { $0.linkRecords > 0 && $0.headers.isEmpty }, "Startup fell back to raw logical streams")
        try await f.close()
    }
    static func epochDeadlineIncludesNativeAcquisition() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2,
            epochLimits: .init(startupMillis: 500))), gate = USBFixtureGate()
        f.nativeA.state.withLock { $0.openGate = gate }; defer { gate.release() }
        let starting = Task { try await f.a.start(timeout: .seconds(3)) }
        try await usbEventually { gate.entered.withLock { $0 } }
        try await usbExpect(USBLinkEpochProtocol.Failure.timeout) { try await starting.value }
        try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) { try await f.a.closeAndAwait(timeout: .milliseconds(30)) }
        try usbCheck(!f.a.shutdownState.nativeWorkersExited && !f.a.shutdownState.referencesReleased, "Native acquisition was abandoned")
        try usbCheck(f.nativeA.state.withLock { $0.linkRecords == 0 }, "Native write preceded acquisition")
        gate.release(); try await f.close()
    }
    static func epochDeadlineRetainsNativeWriteFlight() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2,
            epochLimits: .init(startupMillis: 500))), gate = USBFixtureGate()
        f.nativeA.state.withLock { $0.afterLink = { record in if record.kind == .offer { try gate.wait() } } }
        defer { gate.release() }
        let starting = Task { try await f.a.start(timeout: .seconds(3)) }
        try await usbEventually { gate.entered.withLock { $0 } }
        try await usbExpect(USBLinkEpochProtocol.Failure.timeout) { try await starting.value }
        try usbCheck(f.a.epochSnapshot?.dispatchPending == true, "Early API failure released native write ownership")
        try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) { try await f.a.closeAndAwait(timeout: .milliseconds(30)) }
        try usbCheck(!f.a.shutdownState.nativeWorkersExited && !f.a.shutdownState.pumpsJoined, "Active native write was certified closed")
        gate.release(); try await f.close()
        try usbCheck(f.a.epochSnapshot?.dispatchPending == false && f.a.terminalFailure as? USBLinkEpochProtocol.Failure == .timeout,
                     "Late native completion revived or replaced the original timeout")
    }
    private static func oldRecord() throws -> Data {
        USBLinkWire.encode(try USBLinkWire.Record(kind: .data,
            sender: USBLinkWire.Nonce(Data(repeating: 7, count: 32)), recipient: USBLinkWire.Nonce(Data(repeating: 8, count: 32)),
            body: Data(repeating: 99, count: 512)))
    }
    static func epochQueuedOldRecordsAndInterruptedWrite() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2), readLimit: 31)
        let old = try oldRecord(); try f.nativeA.inject(old + old.prefix(90)); try f.nativeB.inject(old + old.prefix(90))
        try await f.start()
        for owner in [f.a, f.b] {
            try usbCheck(owner.epochSnapshot?.discardedRecords == 1 && owner.epochSnapshot?.quarantinedRecords == 1,
                         "Old queued record/prefix was not explicitly isolated")
        }
        try await f.sibling(); try await f.close()
    }
    static func epochQueuedRevocationKeepsSibling() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2)); try await f.start()
        let (a, b) = try await f.open(), allowed = OSAllocatedUnfairLock(initialState: true)
        try await a.writeBytes(Data(count: 262_144), timeout: .seconds(4), requireEffectAuthorization: {})
        let sending = Task {
            try await a.writeBytes(Data([7]), timeout: .seconds(3), requireEffectAuthorization: {
                guard allowed.withLock({ $0 }) else { throw MultiplexFixtureError.revoked }
            })
        }
        try await usbEventually { f.a.protocolSnapshot.pendingWriteBytes > 0 }
        allowed.withLock { $0 = false }
        _ = try await b.readBytes(maximumBytes: 1, timeout: .seconds(1))
        try await usbExpect(MultiplexFixtureError.revoked) { try await sending.value }
        let emitted = f.nativeA.state.withLock { $0.headers.filter { $0.type == .data && $0.streamID == a.id }.reduce(UInt64(0)) { $0 + UInt64($1.value) } }
        try usbCheck(emitted == 262_144, "Revoked queued bytes entered epoch writer")
        try await a.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }
    static func epochActiveDamageIsTerminalAfterStaleQuarantine() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2)); try await f.start()
        try f.nativeB.inject(oldRecord()); try await usbEventually { f.a.epochSnapshot?.quarantinedRecords == 1 }
        try await f.sibling()
        guard let sender = f.a.epochSnapshot?.peer, let recipient = f.b.epochSnapshot?.peer else { throw MultiplexFixtureError.check("Missing epoch") }
        let record = try USBLinkWire.Record(kind: .data, sender: sender, recipient: recipient,
            body: Data([0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 99]))
        var raw = USBLinkWire.encodeRaw(record); raw[USBLinkWire.headerBytes] = 1
        var damaged = Data([0x7e])
        for byte in raw {
            if byte == 0x7e || byte == 0x7d { damaged.append(contentsOf: [0x7d, byte ^ 0x20]) } else { damaged.append(byte) }
        }
        damaged.append(0x7e)
        try f.nativeB.inject(damaged + USBLinkWire.encode(record))
        try await usbEventually { f.a.terminalFailure != nil }
        try usbCheck(f.a.terminalFailure as? USBLinkWire.Failure == .checksum, "Active damage was silently recovered or misclassified")
        try await f.close()
    }
    static func epochParentCloseRetainsCommittedPayloadUntilNativeReturn() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2)); try await f.start()
        let (a, b) = try await f.open(), gate = USBFixtureGate()
        f.nativeA.state.withLock { $0.afterLink = { record in if record.kind == .data { try gate.wait() } } }
        defer { gate.release() }
        let sending = Task { try await a.writeBytes(Data([1, 3, 5]), timeout: .seconds(3), requireEffectAuthorization: {}) }
        try await usbEventually { gate.entered.withLock { $0 } }; f.a.close()
        try await usbExpect(USBHostMultiplexError.closed) { try await sending.value }
        try usbCheck(f.a.epochSnapshot?.dispatchPending == true && f.a.protocolSnapshot.dispatchPending, "Committed write owner was discarded")
        try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) { try await f.a.closeAndAwait(timeout: .milliseconds(30)) }
        gate.release(); try await f.close(); try await b.closeAndAwait()
    }
    static func finalReceiptRetainsNativeCreditFlight() async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: .epochV2))
        let gate = USBFixtureGate()
        do {
            try await f.start()
            let (host, peer) = try await f.open()
            let streamID = host.id
            f.nativeA.state.withLock { state in state.beforeWrite = { bytes in
                var decoder = USBLinkWire.Decoder()
                for byte in bytes {
                    if case .record(let record) = try decoder.accept(byte), record.kind == .data {
                        let header = try USBLogicalStreamWire.decodeHeader(Data(record.body.prefix(12)))
                        if header.streamID == streamID && header.type == .windowUpdate && header.flags == 0 && header.value == 32 {
                            try gate.wait()
                        }
                    }
                }
            } }
            try await host.finishSending()
            guard case .end = try await peer.readBytes(maximumBytes: 1, timeout: .seconds(1)) else {
                throw MultiplexFixtureError.check("Request FIN missing")
            }
            let digest = usbPattern(32)
            try await peer.writeBytes(digest, timeout: .seconds(1), requireEffectAuthorization: {})
            guard case .bytes(let received) = try await host.readBytes(maximumBytes: 32, timeout: .seconds(1)), received == digest else {
                throw MultiplexFixtureError.check("Final receipt changed")
            }
            try await usbEventually { gate.entered.withLock { $0 } }
            try await peer.finishSending()
            guard case .end = try await host.readBytes(maximumBytes: 1, timeout: .seconds(1)) else {
                throw MultiplexFixtureError.check("Receipt FIN missing")
            }
            try await peer.closeAndAwait()
            try usbCheck(f.a.protocolSnapshot.dispatchPending, "Control write is no longer in flight")
            try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) {
                try await host.closeAndAwait(timeout: .milliseconds(40))
            }
            // Retiring the entire carrier must still not certify a blocked native
            // write as released, even though the final receipt and both FINs arrived.
            f.a.close()
            try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) {
                try await f.a.closeAndAwait(timeout: .milliseconds(40))
            }
            try usbCheck(!f.a.shutdownState.nativeWorkersExited, "Blocked native write was certified exited")
            gate.release()
            try await f.close()
            try await host.closeAndAwait()
            try usbCheck(f.a.shutdownState.nativeWorkersExited && f.a.shutdownState.logicalOwnersReleased,
                         "Final connection cleanup did not release the control write and stream")
        } catch {
            gate.release()
            do { try await f.close() } catch { print("CLEANUP_FAILURE \(error)") }
            throw error
        }
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
            ("cancelled_open_never_publishes_ready", cancelledOpen), ("parent_and_stream_cleanup_waiters", parentAndStreamCleanup),
            ("cancelled_accept_releases_waiter", cancelledAcceptDoesNotConsumeIncomingOwner),
            ("notification_cancellation_and_deadline_reuse", wakeCancellationAndDeadlineReuse),
            ("oversized_header_before_allocation", oversizedHeaderFailsBeforeBodyRead),
            ("native_close_error_preserves_release_facts", closeErrorRetainsReleaseFacts),
            ("epoch_escaped_large_frame_native_fragments", epochLargeAndNativeFragments),
            ("epoch_blocked_bulk_keeps_control_live", epochBlockedBulkKeepsControlLive),
            ("epoch_early_data_waits_for_native_callback", epochEarlyDataWaitsForWriteCallback),
            ("epoch_silent_peer_never_publishes_start", epochSilentPeerCannotPublishStart),
            ("epoch_deadline_covers_native_acquisition", epochDeadlineIncludesNativeAcquisition),
            ("epoch_deadline_retains_native_write_flight", epochDeadlineRetainsNativeWriteFlight),
            ("epoch_isolates_old_queued_records", epochQueuedOldRecordsAndInterruptedWrite),
            ("epoch_queued_revocation_keeps_sibling", epochQueuedRevocationKeepsSibling),
            ("epoch_active_damage_is_terminal", epochActiveDamageIsTerminalAfterStaleQuarantine),
            ("epoch_parent_close_waits_for_native_return", epochParentCloseRetainsCommittedPayloadUntilNativeReturn),
            ("final_receipt_retains_native_credit_flight", finalReceiptRetainsNativeCreditFlight)
        ]
        for (name, test) in tests {
            do { try await test(); print("PASS \(name)") }
            catch { print("FAIL \(name): \(error)"); exit(1) }
        }
        print("PASS \(tests.count) cases; synthetic acquisition, no physical USB/audio acceptance")
    }
}
