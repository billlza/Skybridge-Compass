import Foundation
import SkyBridgeProtocolCore
import XCTest

final class USBLogicalStreamProtocolTests: XCTestCase {
    private typealias P = USBLogicalStreamProtocol
    private typealias W = USBLogicalStreamWire

    func testPublishedWireVectorsAndUnsignedValues() throws {
        let vectors: [(W.Header, String)] = [
            (.init(type: .windowUpdate, flags: 1, streamID: 1, value: 0), "000100010000000100000000"),
            (.init(type: .data, flags: 6, streamID: 3, value: 37), "000000060000000300000025"),
            (.init(type: .ping, flags: 2, streamID: 0, value: 0xfedcba98), "0002000200000000fedcba98"),
            (.init(type: .goAway, flags: 0, streamID: 0, value: 1), "000300000000000000000001"),
            (.init(type: .windowUpdate, flags: 0, streamID: 0xfffffffd, value: 0xffffffff), "00010000fffffffdffffffff"),
        ]
        for (header, hex) in vectors {
            let bytes = try data(hex)
            XCTAssertEqual(try W.encodeHeader(header), bytes)
            XCTAssertEqual(try W.decodeHeader(bytes), header)
            XCTAssertEqual(try W.decodeHeader((Data([9]) + bytes).dropFirst()), header)
        }
    }

    func testMalformedHeadersAreRejectedBeforePayloadAllocation() throws {
        let valid = try W.encodeHeader(.init(type: .windowUpdate, flags: 1, streamID: 1, value: 0))
        for (index, byte) in [(0, UInt8(1)), (1, 4), (3, 16), (3, 3), (3, 9)] {
            var bytes = valid; bytes[index] = byte
            XCTAssertThrowsError(try W.decodeHeader(bytes))
        }
        for header in [W.Header(type: .data, flags: 0, streamID: 1, value: .max),
            .init(type: .data, flags: 0, streamID: 0, value: 1),
            .init(type: .ping, flags: 0, streamID: 0, value: 1),
            .init(type: .ping, flags: 1, streamID: 1, value: 1),
            .init(type: .goAway, flags: 0, streamID: 0, value: 3)] {
            XCTAssertThrowsError(try W.encodeHeader(header))
        }
        XCTAssertThrowsError(try W.decodeHeader(Data(count: 11)))
        XCTAssertThrowsError(try W.Frame(header: .init(type: .data, flags: 0, streamID: 1, value: 2), body: Data([1])))
    }

    func testConfigurationBounds() {
        for limits in [P.Limits(owners: 0), .init(owners: 33), .init(pendingAccepts: 9),
                       .init(lifetimeStreams: 7), .init(lifetimeStreams: 65_537), .init(controlFrames: 129)] {
            XCTAssertThrowsError(try P(role: .client, limits: limits))
        }
    }

    func testFileCreditExhaustionKeepsControlUsableAndReturnsExactBytes() throws {
        let pair = try Pair(); let file = try pair.open(priority: .bulk)
        let source = payload(W.initialWindow + 1)
        try pair.send(file, source.prefix(W.initialWindow))
        XCTAssertEqual(try pair.a.snapshot(streamID: file).sendCredit, 0)
        let blocked = try pair.a.queueData(streamID: file, bytes: source.suffix(1)); try pair.pump()
        assertWaiting(blocked)
        let command = try pair.open(); try pair.send(command, Data([4, 5, 6]))
        XCTAssertEqual(try readData(pair.b, command, 3), Data([4, 5, 6]))
        let first = try readData(pair.b, file, W.initialWindow); try pair.pump(); assertWritten(blocked)
        XCTAssertEqual(first + (try readData(pair.b, file, 1)), source)
        XCTAssertLessThanOrEqual(pair.maximumWireBytes, W.maximumNativeTransfer)
    }

    func testFixedReceiveRingWrapsAndHandlesTinyFramesInOrder() throws {
        let p = try P(role: .server)
        let first = payload(200_000), second = payload(150_000, factor: 13)
        try p.receive(frame(.data, 1, 1, first)); XCTAssertEqual(try p.acceptStream(), 1)
        XCTAssertEqual(try readData(p, 1, 150_000), first.prefix(150_000)); try drain(p)
        try p.receive(frame(.data, 0, 1, second))
        XCTAssertEqual(try readData(p, 1, W.initialWindow), first.suffix(50_000) + second); try drain(p)
        for index in 0..<4_096 { try p.receive(frame(.data, 0, 1, Data([UInt8(truncatingIfNeeded: index)]))) }
        XCTAssertEqual(try readData(p, 1, W.initialWindow), Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0) }))
    }

    func testInputSlicesAndCallerMutationCannotChangeQueuedBytes() throws {
        let pair = try Pair(); let id = try pair.open()
        var bytes = Data([99, 10, 11, 12]).dropFirst()
        let ticket = try pair.a.queueData(streamID: id, bytes: bytes)
        bytes[bytes.startIndex] = 42
        try pair.pump(); assertWritten(ticket)
        XCTAssertEqual(try readData(pair.b, id, 3), Data([10, 11, 12]))
    }

    func testCreditOverflowAndDataBeyondAdvertisedCreditRetireCarrier() throws {
        let pair = try Pair(); let id = try pair.open()
        XCTAssertThrowsError(try pair.a.receive(W.Frame(header: .init(type: .windowUpdate, flags: 0, streamID: id, value: .max))))
        XCTAssertTrue(pair.a.snapshot.failed)
        let p = try P(role: .server)
        try p.receive(frame(.data, 1, 1, payload(W.initialWindow)))
        XCTAssertThrowsError(try p.receive(frame(.data, 0, 1, Data([1]))))
        XCTAssertTrue(p.snapshot.failed)
    }

    func testDistinctPeerIdentifiersCanArriveOutOfOrderButNeverRepeat() throws {
        let p = try P(role: .server)
        try p.receive(frame(.windowUpdate, 1, 3)); try p.receive(frame(.windowUpdate, 1, 1))
        XCTAssertEqual(try p.acceptStream(), 3); XCTAssertEqual(try p.acceptStream(), 1)
        XCTAssertThrowsError(try p.receive(frame(.windowUpdate, 1, 3)))
        let wrong = try P(role: .server)
        XCTAssertThrowsError(try wrong.receive(frame(.windowUpdate, 1, 2)))
    }

    func testBoundedPendingAdmissionRejectsWithoutCreatingAnotherOwner() throws {
        let p = try P(role: .server, limits: .init(owners: 2, pendingAccepts: 1))
        try p.receive(frame(.windowUpdate, 1, 1)); try p.receive(frame(.windowUpdate, 1, 3))
        XCTAssertEqual(p.snapshot.owners, 1); XCTAssertEqual(p.pendingAcceptIDs, [1])
        let rejection = try XCTUnwrap(p.pollOutbound())
        XCTAssertEqual(rejection.header.flags, W.rst); XCTAssertEqual(rejection.header.streamID, 3)
        try p.reportWritten(rejection)
        XCTAssertEqual(try p.acceptStream(), 1); XCTAssertNil(try p.acceptStream())
    }

    func testOwnerCapacityIncludesClosedButUnreleasedStreams() throws {
        let a = try P(role: .client, limits: .init(owners: 1, pendingAccepts: 1))
        let id = try a.openStream(); try a.resetStream(id)
        XCTAssertThrowsError(try a.openStream())
        XCTAssertTrue(try a.canReleaseStream(id)); try a.releaseStream(id)
        XCTAssertEqual(try a.openStream(), 3)
    }

    func testResetNeverCompletesAnInFlightWriteOrReleasesItsOwnerEarly() throws {
        let pair = try Pair(); let id = try pair.open()
        let ticket = try pair.a.queueData(streamID: id, bytes: Data([1, 2]))
        let dispatch = try XCTUnwrap(pair.a.pollOutbound())
        try pair.a.resetStream(id)
        XCTAssertFalse(try pair.a.canReleaseStream(id)); XCTAssertThrowsError(try pair.a.releaseStream(id))
        try pair.a.reportWritten(dispatch); assertFailed(ticket)
        XCTAssertFalse(try pair.a.canReleaseStream(id))
        try pair.pump(); XCTAssertTrue(try pair.a.canReleaseStream(id)); try pair.a.releaseStream(id)
        let next = try pair.open(); try pair.send(next, Data([7])); XCTAssertEqual(try readData(pair.b, next, 1), Data([7]))
    }

    func testOnlyExactRetiredUnsentDataCanBeDiscarded() throws {
        let pair = try Pair(); let id = try pair.open()
        let ticket = try pair.a.queueData(streamID: id, bytes: Data([1]))
        let pending = try XCTUnwrap(pair.a.pollOutbound())
        XCTAssertThrowsError(try pair.a.discardUnsentData(pending))
        try pair.a.resetStream(id); try pair.a.discardUnsentData(pending); assertFailed(ticket)
        let reset = try XCTUnwrap(pair.a.pollOutbound())
        XCTAssertThrowsError(try pair.a.discardUnsentData(pending))
        XCTAssertThrowsError(try pair.a.discardUnsentData(reset))
        try pair.a.reportWritten(reset); try pair.a.releaseStream(id)
    }

    func testPhysicalFailureRemainsFailureAfterAllBufferedBytesAndFin() throws {
        let pair = try Pair(); let id = try pair.open()
        try pair.send(id, Data([7])); try pair.a.finishSending(streamID: id); try pair.pump()
        pair.b.failCarrier(USBLogicalStreamError.cancelled)
        XCTAssertThrowsError(try pair.b.read(streamID: id, maximum: 1))
        XCTAssertTrue(pair.b.snapshot.failed)
    }

    func testHalfCloseAllowsReverseDataThenBothEndsAndBufferedDrain() throws {
        let pair = try Pair(); let id = try pair.open()
        try pair.a.finishSending(streamID: id); try pair.pump()
        guard case .remoteFIN = try pair.b.read(streamID: id, maximum: 1) else { return XCTFail("missing FIN") }
        let ticket = try pair.b.queueData(streamID: id, bytes: Data([3, 4])); try pair.pump(); assertWritten(ticket)
        try pair.b.finishSending(streamID: id); try pair.pump()
        XCTAssertFalse(try pair.a.canReleaseStream(id))
        XCTAssertEqual(try readData(pair.a, id, 2), Data([3, 4]))
        guard case .remoteFIN = try pair.a.read(streamID: id, maximum: 1) else { return XCTFail("missing reverse FIN") }
        XCTAssertTrue(try pair.a.canReleaseStream(id)); try pair.a.releaseStream(id); try pair.b.releaseStream(id)
    }

    func testRepeatedFinAndDataAfterFinFailTheCarrier() throws {
        for trailing in [try frame(.windowUpdate, 4, 1), try frame(.data, 0, 1, Data([1]))] {
            let p = try P(role: .server)
            try p.receive(frame(.windowUpdate, 1, 1)); _ = try p.acceptStream()
            try p.receive(frame(.windowUpdate, 4, 1))
            XCTAssertThrowsError(try p.receive(trailing)); XCTAssertTrue(p.snapshot.failed)
        }
    }

    func testLateFramesAreBoundedByCountAndRemainingCredit() throws {
        let p = try P(role: .server)
        try p.receive(frame(.windowUpdate, 1, 1)); _ = try p.acceptStream()
        try p.resetStream(1); try drain(p); try p.releaseStream(1)
        for _ in 0..<64 { try p.receive(frame(.windowUpdate, 0, 1)) }
        XCTAssertThrowsError(try p.receive(frame(.windowUpdate, 0, 1)))
        let q = try P(role: .server)
        try q.receive(frame(.data, 1, 1, payload(W.initialWindow - 1))); _ = try q.acceptStream()
        try q.resetStream(1); try drain(q); try q.releaseStream(1)
        XCTAssertThrowsError(try q.receive(frame(.data, 0, 1, Data([1, 2]))))
    }

    func testGoAwayStopsNewStreamsButPreservesExistingStream() throws {
        let pair = try Pair(); let id = try pair.open()
        try pair.b.stopAccepting(); try pair.pump()
        XCTAssertThrowsError(try pair.a.openStream())
        try pair.send(id, Data([8])); XCTAssertEqual(try readData(pair.b, id, 1), Data([8]))
    }

    func testOnlyDispatchedMatchingIncreasingPingsCanRenewLiveness() throws {
        let p = try P(role: .client)
        try p.requestPing(7)
        try p.receive(W.Frame(header: .init(type: .ping, flags: W.ack, streamID: 0, value: 7)))
        XCTAssertNil(try p.takePingAcknowledgement())
        try drain(p)
        try p.receive(W.Frame(header: .init(type: .ping, flags: W.ack, streamID: 0, value: 6)))
        XCTAssertNil(try p.takePingAcknowledgement())
        try p.receive(W.Frame(header: .init(type: .ping, flags: W.ack, streamID: 0, value: 7)))
        XCTAssertEqual(try p.takePingAcknowledgement(), 7)
        XCTAssertThrowsError(try p.requestPing(7)); XCTAssertThrowsError(try p.requestPing(6))
        try p.requestPing(8); try drain(p)
        try p.receive(W.Frame(header: .init(type: .ping, flags: W.ack, streamID: 0, value: 7)))
        XCTAssertNil(try p.takePingAcknowledgement())
    }

    func testControlQueueAndLifetimeBudgetsAreFinite() throws {
        let p = try P(role: .server, limits: .init(controlFrames: 4))
        for nonce in 0..<4 { try p.receive(W.Frame(header: .init(type: .ping, flags: 1, streamID: 0, value: UInt32(nonce)))) }
        XCTAssertThrowsError(try p.receive(W.Frame(header: .init(type: .ping, flags: 1, streamID: 0, value: 5))))
        XCTAssertTrue(p.snapshot.failed)
        let q = try P(role: .client, limits: .init(owners: 1, pendingAccepts: 1, lifetimeStreams: 2))
        for _ in 0..<2 { let id = try q.openStream(); try q.resetStream(id); try q.releaseStream(id) }
        XCTAssertThrowsError(try q.openStream()); XCTAssertEqual(q.snapshot.lifetimeStreams, 2)
    }

    func testStaleCompletionCannotFinishAnotherDispatchAndFailedWriteRetiresAll() throws {
        let pair = try Pair(); let id = try pair.open()
        let first = try pair.a.queueData(streamID: id, bytes: Data([1]))
        let old = try XCTUnwrap(pair.a.pollOutbound()); try pair.a.reportWritten(old); assertWritten(first)
        let next = try pair.a.queueData(streamID: id, bytes: Data([2])); let current = try XCTUnwrap(pair.a.pollOutbound())
        XCTAssertThrowsError(try pair.a.reportWritten(old)); assertWaiting(next)
        try pair.a.reportWriteFailure(current, cause: USBLogicalStreamError.cancelled)
        assertFailed(next); XCTAssertTrue(pair.a.snapshot.failed); XCTAssertTrue(try pair.a.canReleaseStream(id))
    }

    private final class Pair {
        let a: P, b: P
        var maximumWireBytes = 0
        init() throws { a = try P(role: .client); b = try P(role: .server) }
        func open(priority: P.Priority = .control) throws -> UInt32 {
            let id = try a.openStream(priority: priority); try pump()
            XCTAssertEqual(try b.acceptStream(priority: priority), id); try pump()
            XCTAssertTrue(try a.snapshot(streamID: id).acknowledged); return id
        }
        func pump() throws {
            for _ in 0..<512 {
                var progress = false
                for (from, to) in [(a, b), (b, a)] {
                    if let out = try from.pollOutbound() {
                        let bytes = out.wireBytes(); maximumWireBytes = max(maximumWireBytes, bytes.count)
                        let header = try W.decodeHeader(bytes.prefix(12))
                        try to.receive(W.Frame(header: header, body: Data(bytes.dropFirst(12))))
                        try from.reportWritten(out); progress = true
                    }
                }
                if !progress { return }
            }
            throw USBLogicalStreamError.protocolViolation("test pump did not quiesce")
        }
        func send(_ id: UInt32, _ data: Data) throws {
            let bytes = Data(data)
            for offset in stride(from: 0, to: bytes.count, by: W.outboundDataBytes) {
                let end = min(bytes.count, offset + W.outboundDataBytes)
                let ticket = try a.queueData(streamID: id, bytes: bytes.subdata(in: offset..<end)); try pump()
                guard case .written = ticket.result else { return XCTFail("test dispatch did not finish") }
            }
        }
    }
    private func assertWritten(_ ticket: P.WriteTicket, file: StaticString = #filePath, line: UInt = #line) {
        guard case .written = ticket.result else { return XCTFail("not written", file: file, line: line) }
    }
    private func assertWaiting(_ ticket: P.WriteTicket, file: StaticString = #filePath, line: UInt = #line) {
        guard case .waiting = ticket.result else { return XCTFail("not waiting", file: file, line: line) }
    }
    private func assertFailed(_ ticket: P.WriteTicket, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failed = ticket.result else { return XCTFail("not failed", file: file, line: line) }
    }
    private func readData(_ p: P, _ id: UInt32, _ count: Int) throws -> Data {
        guard case .data(let bytes) = try p.read(streamID: id, maximum: count) else {
            throw USBLogicalStreamError.protocolViolation("expected test data")
        }
        return bytes
    }
    private func drain(_ p: P) throws {
        for _ in 0..<512 {
            guard let out = try p.pollOutbound() else { return }
            try p.reportWritten(out)
        }
        throw USBLogicalStreamError.protocolViolation("test dispatch did not quiesce")
    }
    private func frame(_ type: W.FrameType, _ flags: UInt16, _ id: UInt32, _ body: Data = Data()) throws -> W.Frame {
        try W.Frame(header: .init(type: type, flags: flags, streamID: id, value: type == .data ? UInt32(body.count) : 0), body: body)
    }
    private func payload(_ count: Int, factor: Int = 31) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * factor + 17) }) }
    private func data(_ hex: String) throws -> Data {
        guard hex.count % 2 == 0 else { throw USBLogicalStreamError.invalidArgument }
        return try Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return try XCTUnwrap(UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16))
        })
    }
}
