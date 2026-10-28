import Foundation
import os
import SkyBridgeProtocolCore
import XCTest

final class USBLinkEpochProtocolTests: XCTestCase {
    private typealias E = USBLinkEpochProtocol
    private typealias W = USBLinkWire
    private final class FixtureError: Error {}
    private func nonce(_ value: UInt8) throws -> W.Nonce { try .init(Data(repeating: value, count: 32)) }
    private func frame(_ kind: W.Kind, _ sender: UInt8, _ recipient: UInt8?, _ body: Data = Data()) throws -> E.Inbound {
        E.Inbound(try W.Record(kind: kind, sender: nonce(sender), recipient: recipient.map(nonce), body: body))
    }
    private func expect(_ reason: E.Failure, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? E.Failure, reason) }
    }
    private func assertWaiting(_ ticket: E.WriteTicket) {
        guard case .waiting = ticket.result else { return XCTFail("Write completed early") }
    }
    private func assertWritten(_ ticket: E.WriteTicket) {
        guard case .written = ticket.result else { return XCTFail("Write did not complete") }
    }
    private func assertFailed(_ ticket: E.WriteTicket, _ cause: FixtureError) {
        guard case .failed(let failure) = ticket.result else { return XCTFail("Missing write failure") }
        XCTAssertTrue(failure as? FixtureError === cause)
    }
    private final class Pair {
        let clock = OSAllocatedUnfairLock(initialState: Int64(0))
        let client: E, server: E
        init(_ limits: E.Limits = E.Limits()) throws {
            let clock = self.clock
            client = try E(role: .client, local: W.Nonce(Data(repeating: 1, count: 32)), limits: limits, elapsedMillis: { clock.withLock { $0 } })
            server = try E(role: .server, local: W.Nonce(Data(repeating: 2, count: 32)), limits: limits, elapsedMillis: { clock.withLock { $0 } })
        }
        func time(_ value: Int64) { clock.withLock { $0 = value } }
        @discardableResult func send(_ source: E, _ target: E, report: Bool = true) throws -> E.Outbound {
            let outbound = try XCTUnwrap(source.pollOutbound()); try source.authorizeOutbound(outbound)
            try deliver(target, outbound)
            if report { try source.reportWritten(outbound) }
            return outbound
        }
        func deliver(_ target: E, _ outbound: E.Outbound) throws {
            let wire = outbound.wireBytes(); try target.observeInboundBytes(wire.count)
            var decoder = W.Decoder(), records: [W.Record] = []
            for byte in wire {
                if let event = try decoder.accept(byte) {
                    switch event {
                    case .record(let record): records.append(record)
                    case .discarded: throw FixtureError()
                    }
                }
            }
            XCTAssertEqual(records.count, 1)
            XCTAssertNotEqual(try target.receive(E.Inbound(XCTUnwrap(records.first))), .backpressure)
        }
        func connect() throws {
            try send(client, server); try send(server, client); try send(client, server); try send(server, client)
            XCTAssertEqual(client.snapshot.phase, .ready); XCTAssertEqual(server.snapshot.phase, .ready)
        }
    }
    func testHandshakePreservesOpaqueBytesAndLocalWriteReceiptIsDistinct() throws {
        let p = try Pair(); try p.connect()
        XCTAssertEqual(p.client.snapshot.peer, try nonce(2)); XCTAssertEqual(p.server.snapshot.peer, try nonce(1))
        var body = Data((0..<W.maximumBodyBytes).map { UInt8(truncatingIfNeeded: $0) }); let original = body
        let ticket = try p.client.queueData(body); body.resetBytes(in: 0..<body.count)
        let outgoing = try p.send(p.client, p.server, report: false)
        assertWaiting(ticket); XCTAssertEqual(try p.server.readPayload(maximumBytes: W.maximumBodyBytes), original)
        try p.client.reportWritten(outgoing); assertWritten(ticket)
        XCTAssertNil(try p.server.readPayload(maximumBytes: 1)); XCTAssertNil(try p.client.pollOutbound())
    }
    func testConfirmationsBeforeCallbacksCannotPublishReadiness() throws {
        let p = try Pair()
        let offer = try p.send(p.client, p.server, report: false)
        let select = try p.send(p.server, p.client, report: false)
        XCTAssertNil(try p.client.pollOutbound()); XCTAssertEqual(p.client.snapshot.phase, .starting)
        try p.client.reportWritten(offer)
        let accept = try p.send(p.client, p.server, report: false)
        XCTAssertNil(try p.server.pollOutbound()); XCTAssertEqual(p.server.snapshot.phase, .starting)
        try p.server.reportWritten(select)
        let ready = try p.send(p.server, p.client, report: false)
        XCTAssertEqual(p.client.snapshot.phase, .starting); XCTAssertEqual(p.server.snapshot.phase, .starting)
        try p.client.reportWritten(accept); XCTAssertEqual(p.client.snapshot.phase, .ready)
        _ = try p.client.queueData(Data([8, 9])); try p.send(p.client, p.server)
        XCTAssertEqual(p.server.snapshot.bufferedBytes, 2)
        expect(.notReady) { _ = try p.server.readPayload(maximumBytes: 2) }
        try p.server.reportWritten(ready); XCTAssertEqual(try p.server.readPayload(maximumBytes: 2), Data([8, 9]))
    }
    func testClientEarlyDataWaitsForAcceptWriteCompletion() throws {
        let p = try Pair(); try p.send(p.client, p.server); try p.send(p.server, p.client)
        let accept = try p.send(p.client, p.server, report: false); try p.send(p.server, p.client)
        XCTAssertEqual(p.client.snapshot.phase, .starting)
        _ = try p.server.queueData(Data([4, 5])); try p.send(p.server, p.client)
        expect(.notReady) { _ = try p.client.readPayload(maximumBytes: 2) }
        try p.client.reportWritten(accept); XCTAssertEqual(try p.client.readPayload(maximumBytes: 2), Data([4, 5]))
    }
    func testWriteFailureAfterEarlyConfirmationDropsProvisionalData() throws {
        let p = try Pair(); try p.send(p.client, p.server); try p.send(p.server, p.client)
        let accept = try p.send(p.client, p.server, report: false); try p.send(p.server, p.client)
        _ = try p.server.queueData(Data([4])); try p.send(p.server, p.client)
        let cause = FixtureError(); try p.client.reportWriteFailure(accept, cause: cause)
        XCTAssertTrue(p.client.failure as? FixtureError === cause); XCTAssertEqual(p.client.snapshot.bufferedBytes, 0)
        XCTAssertThrowsError(try p.client.readPayload(maximumBytes: 1)) { XCTAssertTrue($0 as? FixtureError === cause) }
        expect(.wrongDispatch) { try p.client.reportWritten(accept) }; XCTAssertEqual(p.client.snapshot.phase, .failed)
    }
    func testStaleRecordsNeverReachPayload() throws {
        let p = try Pair()
        for kind in [W.Kind.data, .close, .ready] {
            XCTAssertEqual(try p.client.receive(frame(kind, 3, 4, kind == .data ? Data([9]) : Data())), .quarantined)
        }
        try p.connect()
        XCTAssertEqual(try p.client.receive(frame(.data, 3, 4, Data([9]))), .quarantined)
        XCTAssertEqual(p.client.snapshot.bufferedBytes, 0); XCTAssertEqual(p.client.snapshot.phase, .ready)
        expect(.wrongEpoch) { _ = try p.client.receive(frame(.data, 3, 1, Data([9]))) }
    }
    func testServerReplacementRequiresInteractiveReplyAndCompletedChallenge() throws {
        let p = try Pair(); try p.connect()
        XCTAssertEqual(try p.server.receive(frame(.offer, 3, nil)), .progress)
        XCTAssertEqual(p.server.snapshot.phase, .ready)
        let select = try XCTUnwrap(p.server.pollOutbound()); try p.server.authorizeOutbound(select)
        _ = try p.server.receive(frame(.accept, 3, 2)); XCTAssertEqual(p.server.snapshot.phase, .ready)
        expect(.peerRestarted) { try p.server.reportWritten(select) }; XCTAssertFalse(p.server.snapshot.dispatchPending)
    }
    func testClientReplacementRequiresInteractiveReplyAndCompletedChallenge() throws {
        let p = try Pair(); try p.connect(); _ = try p.client.receive(frame(.select, 3, 1))
        XCTAssertEqual(p.client.snapshot.phase, .ready)
        let accept = try XCTUnwrap(p.client.pollOutbound()); try p.client.authorizeOutbound(accept)
        _ = try p.client.receive(frame(.ready, 3, 1)); XCTAssertEqual(p.client.snapshot.phase, .ready)
        expect(.peerRestarted) { try p.client.reportWritten(accept) }
    }
    func testReplacementReplyCannotBypassUnsentChallenge() throws {
        let p = try Pair(); try p.connect(); _ = try p.server.receive(frame(.offer, 3, nil))
        expect(.protocolViolation) { _ = try p.server.receive(frame(.accept, 3, 2)) }
        let q = try Pair(); try q.connect(); _ = try q.client.receive(frame(.select, 3, 1))
        expect(.protocolViolation) { _ = try q.client.receive(frame(.ready, 3, 1)) }
    }
    func testOldStartupCandidateCannotTakeOverEstablishedPeer() throws {
        let p = try Pair(); _ = try p.server.receive(frame(.offer, 3, nil))
        try p.server.reportWritten(XCTUnwrap(p.server.pollOutbound())); try p.connect()
        XCTAssertEqual(try p.server.receive(frame(.offer, 3, nil)), .quarantined)
        XCTAssertEqual(try p.server.receive(frame(.accept, 3, 2)), .quarantined)
        XCTAssertEqual(p.server.snapshot.phase, .ready); XCTAssertNil(try p.server.pollOutbound())
    }
    func testClientSupersedesUnconfirmedSelectWithoutOldConfirmation() throws {
        let p = try Pair(); try p.client.reportWritten(XCTUnwrap(p.client.pollOutbound()))
        _ = try p.client.receive(frame(.select, 3, 1)); _ = try p.client.receive(frame(.select, 2, 1))
        let accept = try XCTUnwrap(p.client.pollOutbound()); XCTAssertEqual(accept.record.recipient, try nonce(2))
        try p.client.reportWritten(accept)
        XCTAssertEqual(try p.client.receive(frame(.ready, 3, 1)), .quarantined)
        _ = try p.client.receive(frame(.ready, 2, 1)); XCTAssertEqual(p.client.snapshot.phase, .ready)
    }
    func testStartupDeadlineNeverRenews() throws {
        let p = try Pair(E.Limits(startupMillis: 1000, offerIntervalMillis: 100))
        try p.client.reportWritten(XCTUnwrap(p.client.pollOutbound()))
        p.time(900); _ = try p.client.receive(frame(.close, 3, 4))
        try p.client.reportWritten(XCTUnwrap(p.client.pollOutbound())); p.time(1000)
        expect(.timeout) { try p.client.tick() }; expect(.timeout) { _ = try p.client.pollOutbound() }
    }
    func testIndependentRawByteRecordAndDiscardBudgets() throws {
        let p = try Pair(E.Limits(startupWireBytes: 100)); try p.client.observeInboundBytes(100)
        expect(.startupBudget) { try p.client.observeInboundBytes(1) }
        let q = try Pair(E.Limits(startupRecords: 4))
        for _ in 0..<4 { _ = try q.client.receive(frame(.close, 3, 4)) }
        expect(.startupBudget) { _ = try q.client.receive(frame(.close, 3, 4)) }
        let r = try Pair()
        for _ in 0..<W.maximumStartupDiscards { try r.client.observeDiscard(reason: .truncated, encodedBodyBytes: 1) }
        expect(.startupBudget) { try r.client.observeDiscard(reason: .truncated, encodedBodyBytes: 1) }
    }
    func testDecoderRecoveryForbiddenAfterReadiness() throws {
        let p = try Pair(); try p.connect()
        expect(.protocolViolation) { try p.client.observeDiscard(reason: .checksum, encodedBodyBytes: 80) }
        let q = try Pair(); expect(.protocolViolation) { try q.server.observeDiscard(reason: .header, encodedBodyBytes: 80) }
    }
    func testCandidateControlAndStaleLifetimeBudgets() throws {
        let p = try Pair(E.Limits(candidates: 1)); _ = try p.server.receive(frame(.offer, 1, nil))
        expect(.candidates) { _ = try p.server.receive(frame(.offer, 3, nil)) }
        let q = try Pair(E.Limits(controlTransmissions: 4))
        for i in 0..<4 { q.time(Int64(i) * 500); try q.client.reportWritten(XCTUnwrap(q.client.pollOutbound())) }
        q.time(2000); expect(.controlBudget) { _ = try q.client.pollOutbound() }
        let r = try Pair(E.Limits(startupRecords: 4)); try r.connect()
        for _ in 0..<4 { _ = try r.client.receive(frame(.data, 3, 4, Data([7]))) }
        expect(.staleBudget) { _ = try r.client.receive(frame(.data, 3, 4, Data([7]))) }
    }
    func testOneWriterAndNoBusyRetryWhileWriteOutstanding() throws {
        let p = try Pair(); let offer = try XCTUnwrap(p.client.pollOutbound())
        XCTAssertNil(try p.client.pollOutbound()); p.time(600)
        XCTAssertEqual(p.client.snapshot.nextWakeMillis, 10_000); try p.client.reportWritten(offer)
        let retry = try XCTUnwrap(p.client.pollOutbound())
        XCTAssertEqual(retry.record.kind, .offer); XCTAssertEqual(retry.record.sender, try nonce(1))
    }
    func testBackpressurePreservesRecordIdentityOrderAndRingWrap() throws {
        let p = try Pair(E.Limits(receiveBufferBytes: W.maximumBodyBytes)); try p.connect()
        let first = Data((0..<W.maximumBodyBytes).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertEqual(try p.server.receive(frame(.data, 1, 2, first)), .buffered)
        let next = try frame(.data, 1, 2, Data([11, 12]))
        XCTAssertEqual(try p.server.receive(next), .backpressure)
        XCTAssertEqual(try p.server.readPayload(maximumBytes: 3), first.prefix(3))
        XCTAssertEqual(try p.server.receive(next), .buffered)
        XCTAssertEqual(try p.server.readPayload(maximumBytes: W.maximumBodyBytes), first.dropFirst(3) + Data([11, 12]))
        XCTAssertNil(try p.server.readPayload(maximumBytes: 1))
    }
    func testLaterRecordCannotOvertakeBackpressure() throws {
        let p = try Pair(E.Limits(receiveBufferBytes: W.maximumBodyBytes)); try p.connect()
        _ = try p.server.receive(frame(.data, 1, 2, Data(count: W.maximumBodyBytes)))
        _ = try p.server.receive(frame(.data, 1, 2, Data([1])))
        expect(.backpressureOrder) { _ = try p.server.receive(frame(.close, 1, 2)) }
    }
    func testEarlyOverflowFailsInsteadOfBackpressuringReadiness() throws {
        let p = try Pair(E.Limits(receiveBufferBytes: W.maximumBodyBytes))
        try p.send(p.client, p.server); try p.send(p.server, p.client); try p.send(p.client, p.server)
        try p.send(p.server, p.client, report: false)
        _ = try p.server.receive(frame(.data, 1, 2, Data(count: W.maximumBodyBytes)))
        expect(.startupBudget) { _ = try p.server.receive(frame(.data, 1, 2, Data([1]))) }
        XCTAssertEqual(p.server.snapshot.bufferedBytes, 0)
    }
    func testFailureRetainsFlightUntilCallbackButCannotReviveTicket() throws {
        let p = try Pair(); try p.connect(); let ticket = try p.client.queueData(Data([1]))
        let outgoing = try XCTUnwrap(p.client.pollOutbound()), cause = FixtureError()
        p.client.failCarrier(cause); p.client.failCarrier(FixtureError())
        XCTAssertTrue(p.client.snapshot.dispatchPending); assertFailed(ticket, cause)
        XCTAssertThrowsError(try p.client.authorizeOutbound(outgoing)) { XCTAssertTrue($0 as? FixtureError === cause) }
        XCTAssertThrowsError(try p.client.reportWritten(outgoing)) { XCTAssertTrue($0 as? FixtureError === cause) }
        XCTAssertFalse(p.client.snapshot.dispatchPending); assertFailed(ticket, cause)
    }
    func testForeignCallbacksCannotCompleteCurrentOwner() throws {
        let p = try Pair(); try p.connect(); let ticket = try p.client.queueData(Data([1]))
        let current = try XCTUnwrap(p.client.pollOutbound()), foreign = try XCTUnwrap(Pair().client.pollOutbound())
        expect(.wrongDispatch) { try p.client.reportWritten(foreign) }
        expect(.wrongDispatch) { try p.client.reportWriteFailure(foreign, cause: FixtureError()) }
        XCTAssertNil(p.client.failure); assertWaiting(ticket)
        try p.client.reportWritten(current); assertWritten(ticket)
    }
    func testPayloadAndPrematureConfirmationCannotSkipHandshake() throws {
        let p = try Pair()
        expect(.notReady) { _ = try p.client.queueData(Data([1])) }
        expect(.notReady) { _ = try p.server.readPayload(maximumBytes: 1) }
        expect(.protocolViolation) { _ = try p.client.receive(frame(.select, 2, 1)) }
        XCTAssertEqual(p.client.snapshot.phase, .failed)
    }
    func testClockFailuresPreserveCauseAndStartupDeadlineEndsOnlyAtReady() throws {
        let p = try Pair(); p.time(20); try p.client.tick(); p.time(19)
        expect(.clock) { try p.client.tick() }
        let cause = FixtureError(), failing = try E(role: .client, local: nonce(1), elapsedMillis: { throw cause })
        XCTAssertThrowsError(try failing.tick()) { XCTAssertTrue($0 as? FixtureError === cause) }
        XCTAssertTrue(failing.failure as? FixtureError === cause)
        let q = try Pair(); try q.connect(); q.time(100_000); try q.client.tick(); XCTAssertEqual(q.client.snapshot.phase, .ready)
    }
    func testClockSampleAndStateUpdateShareSerializationBoundary() throws {
        let reads = OSAllocatedUnfairLock(initialState: Int64(0)), errors = OSAllocatedUnfairLock(initialState: [any Error]())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), secondStarted = DispatchSemaphore(value: 0)
        let owner = try E(role: .client, local: nonce(1), elapsedMillis: {
            let value = reads.withLock { $0 += 1; return $0 }
            // Bounded deliberate stall makes out-of-order clock sampling observable.
            if value == 1 { entered.signal(); guard release.wait(timeout: .now() + 2) == .success else { throw FixtureError() } }
            return value
        })
        let group = DispatchGroup(); defer { release.signal() }
        group.enter(); DispatchQueue.global().async {
            defer { group.leave() }; do { try owner.tick() } catch { errors.withLock { $0.append(error) } }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        group.enter(); DispatchQueue.global().async {
            defer { group.leave() }; secondStarted.signal()
            do { try owner.tick() } catch { errors.withLock { $0.append(error) } }
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success); XCTAssertEqual(reads.withLock { $0 }, 1)
        release.signal(); XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(reads.withLock { $0 }, 2); XCTAssertTrue(errors.withLock { $0.isEmpty }); XCTAssertNil(owner.failure)
    }
    func testInvalidConfigurationAndLocalArgumentsStayExplicit() throws {
        for limits in [E.Limits(startupMillis: 0), E.Limits(offerIntervalMillis: 0), E.Limits(startupWireBytes: 75),
                       E.Limits(startupRecords: 3), E.Limits(candidates: 0), E.Limits(controlTransmissions: 3),
                       E.Limits(receiveBufferBytes: W.maximumBodyBytes - 1)] {
            expect(.invalidConfiguration) { _ = try E(role: .client, local: nonce(1), limits: limits) }
        }
        let p = try Pair(); try p.connect()
        expect(.invalidArgument) { try p.client.observeInboundBytes(-1) }
        expect(.invalidArgument) { _ = try p.client.readPayload(maximumBytes: 0) }
        expect(.invalidArgument) { _ = try p.client.queueData(Data()) }
        XCTAssertEqual(p.client.snapshot.phase, .ready)
    }
}
