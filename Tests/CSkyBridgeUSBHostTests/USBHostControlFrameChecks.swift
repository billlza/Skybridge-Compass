import Foundation
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeAppleTransport

private final class FrameReceipts: Sendable {
    let state = OSAllocatedUnfairLock<[Int: Result<Void, any Error>]>(initialState: [:])
    let order = OSAllocatedUnfairLock<[Int]>(initialState: [])
    let duplicate = OSAllocatedUnfairLock(initialState: false)
    func complete(_ id: Int, _ result: Result<Void, any Error>) {
        state.withLock { values in
            if values[id] != nil { duplicate.withLock { $0 = true } }
            values[id] = result
        }
        order.withLock { $0.append(id) }
    }
    func result(_ id: Int) async throws -> Result<Void, any Error> {
        try await usbEventually { self.state.withLock { $0[id] != nil } }
        return try state.withLock { values in
            guard let result = values[id] else { throw MultiplexFixtureError.check("Missing receipt") }
            return result
        }
    }
}

@main enum USBHostControlFrameChecks {
    static func fifoAndCanonicalBytes(_ profile: USBHostMultiplexConnection.LinkProfile = .rawYamuxV1) async throws {
        let f = try USBMultiplexFixture(configuration: .init(linkProfile: profile)); try await f.start(); let (a, b) = try await f.open()
        let writer = try USBHostControlFrameTransport(stream: a), receipts = FrameReceipts()
        for n in 0..<8 {
            try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: Data([UInt8(n), 29])),
                requireEffectAuthorization: {}, completion: { receipts.complete(n, $0) })
        }
        for n in 0..<8 {
            let body = try await b.readFrame(timeout: .seconds(2))
            try usbCheck(body == Data([UInt8(n), 29]), "MAIN frame order or canonical bytes changed")
            try await receipts.result(n).get()
        }
        try usbCheck(receipts.order.withLock { $0 } == Array(0..<8), "Completion order changed")
        try usbCheck(!receipts.duplicate.withLock { $0 }, "Duplicate completion")
        try await writer.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }

    static func byteAndCountBounds() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        let writer = try USBHostControlFrameTransport(stream: a, maximumPendingFrames: 2,
            maximumPendingBytes: P2PControlFramePolicy.maximumBodyByteCount + 4)
        let receipts = FrameReceipts(), bulk = usbPattern(700_007)
        try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: bulk), requireEffectAuthorization: {},
                                     completion: { receipts.complete(0, $0) })
        try await usbEventually { f.b.protocolSnapshot.bufferedReceiveBytes == 262_144 }
        do {
            try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: usbPattern(400_000)),
                requireEffectAuthorization: {}, completion: { receipts.complete(99, $0) })
            throw MultiplexFixtureError.check("Byte budget accepted too much data")
        } catch let error as USBHostControlFrameError { try usbCheck(error == .queueFull, "Wrong byte bound error") }
        try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: Data([7])), requireEffectAuthorization: {},
                                     completion: { receipts.complete(1, $0) })
        do {
            try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: Data([8])), requireEffectAuthorization: {},
                                         completion: { receipts.complete(98, $0) })
            throw MultiplexFixtureError.check("Frame count bound was exceeded")
        } catch let error as USBHostControlFrameError { try usbCheck(error == .queueFull, "Wrong count bound error") }
        let first = try await b.readFrame(timeout: .seconds(2)), second = try await b.readFrame(timeout: .seconds(2))
        try usbCheck(first == bulk && second == Data([7]), "Bounded queue changed retained data")
        try await receipts.result(0).get(); try await receipts.result(1).get()
        try usbCheck(receipts.state.withLock { $0.count == 2 }, "Rejected admission manufactured a receipt")
        try await writer.closeAndAwait(); try await b.closeAndAwait(); try await f.close()
    }

    static func queuedExpiryDoesNotCancelActiveFrame() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        let writer = try USBHostControlFrameTransport(stream: a), receipts = FrameReceipts(), bulk = usbPattern(600_003)
        try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: bulk), requireEffectAuthorization: {},
                                     completion: { receipts.complete(0, $0) })
        try await usbEventually { f.b.protocolSnapshot.bufferedReceiveBytes == 262_144 }
        try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: Data([9])), timeout: .milliseconds(40),
            requireEffectAuthorization: {}, completion: { receipts.complete(1, $0) })
        let expired = try await receipts.result(1)
        try await usbExpect(USBHostMultiplexError.timedOut) { try expired.get() }
        try usbCheck(writer.isReady && writer.pendingFrameCount == 1, "Queued expiry retired the active write")
        let bytes = try await b.readFrame(timeout: .seconds(2)); try usbCheck(bytes == bulk, "Active frame was lost")
        try await receipts.result(0).get()
        try await writer.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }

    static func queuedRevocationAndCancellation() async throws {
        for cancel in [false, true] {
            let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
            let writer = try USBHostControlFrameTransport(stream: a), receipts = FrameReceipts(), bulk = usbPattern(600_003)
            let allowed = OSAllocatedUnfairLock(initialState: true)
            try writer.enqueueFramedBytes(P2PControlFramePolicy.frame(body: bulk), requireEffectAuthorization: {},
                                         completion: { receipts.complete(0, $0) })
            try await usbEventually { f.b.protocolSnapshot.bufferedReceiveBytes == 262_144 }
            let queued = Task { try await writer.sendFrame(Data([91])) {
                guard allowed.withLock({ $0 }) else { throw MultiplexFixtureError.revoked }
            } }
            try await usbEventually { writer.pendingFrameCount == 2 }
            if cancel { queued.cancel() } else { allowed.withLock { $0 = false } }
            let bytes = try await b.readFrame(timeout: .seconds(2)); try usbCheck(bytes == bulk, "Earlier frame changed")
            if cancel { try await usbExpect(CancellationError()) { try await queued.value } }
            else { try await usbExpect(MultiplexFixtureError.revoked) { try await queued.value } }
            let final = Task { try await writer.sendFrame(Data([17])) {} }
            let last = try await b.readFrame(timeout: .seconds(2)); try await final.value
            try usbCheck(last == Data([17]), "Cancelled/revoked bytes escaped the queue")
            try await receipts.result(0).get()
            try await writer.closeAndAwait(); try await b.closeAndAwait(); try await f.close()
        }
    }

    static func activeDeadlineAndCancellationRetireOnlyMain() async throws {
        for cancel in [false, true] {
            let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
            let writer = try USBHostControlFrameTransport(stream: a)
            let write = Task { try await writer.sendFrame(usbPattern(600_003),
                timeout: cancel ? .seconds(3) : .milliseconds(150)) {} }
            // Distinguish cancellation while waiting for credit from cancellation
            // after a raw native write has entered. Only the former is stream-local.
            try await usbEventually {
                f.b.protocolSnapshot.bufferedReceiveBytes == 262_144 &&
                    f.a.protocolSnapshot.pendingWriteBytes > 0 && !f.a.protocolSnapshot.dispatchPending
            }
            if cancel { write.cancel(); try await usbExpect(CancellationError()) { try await write.value } }
            else { try await usbExpect(USBHostMultiplexError.timedOut) { try await write.value } }
            try usbCheck(!writer.isReady, "Partially written frame left MAIN usable")
            try await writer.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
        }
    }

    static func cleanupWaitsForCommittedNativeWrite() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        let writer = try USBHostControlFrameTransport(stream: a), gate = USBFixtureGate(), id = a.id
        f.nativeA.state.withLock { value in value.beforeWrite = { bytes in
            let header = try USBLogicalStreamWire.decodeHeader(Data(bytes.prefix(12)))
            if header.type == .data && header.streamID == id { try gate.wait() }
        } }
        let write = Task { try await writer.sendFrame(Data([1, 2, 3])) {} }
        try await usbEventually { gate.entered.withLock { $0 } }
        writer.close()
        do {
            try await usbExpect(USBHostMultiplexError.closed) { try await write.value }
            try await usbExpect(USBHostMultiplexError.cleanupUnconfirmed) {
                try await writer.closeAndAwait(timeout: .milliseconds(40))
            }
        } catch { gate.release(); throw error }
        gate.release(); f.nativeA.state.withLock { $0.beforeWrite = nil }
        try await writer.closeAndAwait(); try await b.closeAndAwait()
        // Once native dispatch has entered, interruption cannot promise that the
        // Yamux frame was wholly written. The existing byte owner retires the
        // physical link; a new stream here must not manufacture a usable carrier.
        try await usbEventually { f.a.shutdownState.retired }
        guard let originalFailure = f.a.terminalFailure else {
            throw MultiplexFixtureError.check("Physical retirement lost its originating failure")
        }
        try await usbExpect(originalFailure) { _ = try await f.a.openStream() }
        try await f.close()
    }

    static func readerOwnershipAndCancellation() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        let receiver = try USBHostControlFrameTransport(stream: a)
        let read = Task { try await receiver.receiveFrame() }
        try await usbEventually { receiver.readInProgress }
        try await usbExpect(USBHostMultiplexError.readInProgress) { _ = try await receiver.receiveFrame() }
        read.cancel(); try await usbExpect(CancellationError()) { _ = try await read.value }
        try await receiver.closeAndAwait(); try await b.closeAndAwait(); try await f.sibling(); try await f.close()
    }

    static func malformedFrameCannotReachNativeWriter() async throws {
        let f = try USBMultiplexFixture(); try await f.start(); let (a, b) = try await f.open()
        let writer = try USBHostControlFrameTransport(stream: a), receipts = FrameReceipts()
        for bytes in [Data(), Data([0, 0, 0, 0]), Data([0, 0, 0, 2, 1]), Data([0, 0, 0, 1, 1, 2])] {
            do {
                try writer.enqueueFramedBytes(bytes, requireEffectAuthorization: {}, completion: { receipts.complete(0, $0) })
                throw MultiplexFixtureError.check("Malformed frame was accepted")
            } catch let error as USBHostControlFrameError { try usbCheck(error == .invalidFrame, "Wrong malformed frame error") }
        }
        try usbCheck(writer.pendingFrameCount == 0 && receipts.state.withLock { $0.isEmpty }, "Malformed frame entered queue")
        try await writer.closeAndAwait(); try await b.closeAndAwait(); try await f.close()
    }

    static func record(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
    static func main() async {
        let checks: [(String, @Sendable () async throws -> Void)] = [
            ("fifo-canonical-bytes", { try await fifoAndCanonicalBytes() }), ("byte-count-bounds", byteAndCountBounds),
            ("queued-expiry", queuedExpiryDoesNotCancelActiveFrame), ("queued-revocation-cancellation", queuedRevocationAndCancellation),
            ("active-deadline-cancellation", activeDeadlineAndCancellationRetireOnlyMain),
            ("native-cleanup-wait", cleanupWaitsForCommittedNativeWrite),
            ("reader-owner-cancellation", readerOwnershipAndCancellation), ("malformed-frame", malformedFrameCannotReachNativeWriter),
            ("epoch-v2-fifo-canonical-bytes", { try await fifoAndCanonicalBytes(.epochV2) })]
        for (name, check) in checks {
            record("START \(name)")
            do { try await check(); record("PASS \(name)") }
            catch { record("FAIL \(name): \(error)"); exit(1) }
        }
        record("USB MAIN frame checks passed: \(checks.count); native USB and product handshake not qualified")
    }
}
