import Foundation
import SkyBridgeProtocolCore
import XCTest

final class USBLinkWireTests: XCTestCase {
    private typealias W = USBLinkWire
    private enum FixtureFailure: Error { case unexpectedDiscard }
    private func nonce(_ start: Int) throws -> W.Nonce { try .init(Data((start..<(start + 32)).map { UInt8($0) })) }
    private func record(_ body: Data = Data([1])) throws -> W.Record {
        try .init(kind: .data, sender: nonce(1), recipient: nonce(33), body: body)
    }
    private func hex(_ text: String) throws -> Data {
        let chars = Array(text)
        return try Data(stride(from: 0, to: chars.count, by: 2).map { index in
            try XCTUnwrap(UInt8(String(chars[index...index + 1]), radix: 16))
        })
    }
    private func feed(_ bytes: Data, to decoder: inout W.Decoder) throws -> [W.Record] {
        var records: [W.Record] = []
        for byte in bytes {
            if let event = try decoder.accept(byte) {
                switch event {
                case .record(let record): records.append(record)
                case .discarded: throw FixtureFailure.unexpectedDiscard
                }
            }
        }
        return records
    }
    private func events(_ bytes: Data, to decoder: inout W.Decoder) throws -> [W.Event] {
        try bytes.compactMap { try decoder.accept($0) }
    }
    private func expect(_ reason: W.Failure, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { XCTAssertEqual($0 as? W.Failure, reason) }
    }
    private func repairingCRC(_ bytes: Data) -> Data {
        var result = Data(bytes.dropLast(4)), crc: UInt32 = 0xffffffff
        // Bitwise reference independent of the production lookup-table path.
        for byte in result {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        crc ^= 0xffffffff
        for shift in stride(from: 0, to: 32, by: 8) { result.append(UInt8(truncatingIfNeeded: crc >> shift)) }
        return result
    }

    func testIndependentVectorsForEveryKindAndEscaping() throws {
        // Independent Python zlib/explicit octet-stuffing reference.
        let vectors = [
            "7e5342554c02000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2000000000000000000000000000000000000000000000000000000000000000000000cfb4cc987e",
            "7e5342554c02010102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f400000b01411ce7e",
            "7e5342554c02020102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f400000193ea2827e",
            "7e5342554c02030102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40000041dae30f7e",
            "7e5342554c02040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f400006007d5e7d5dff11225c6da5577e",
            "7e5342554c02050102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f400000138f85967e"
        ]
        for index in vectors.indices {
            let kind = try XCTUnwrap(W.Kind(rawValue: UInt8(index)))
            let body = kind == .data ? try hex("007e7dff1122") : Data()
            let record = try W.Record(kind: kind, sender: nonce(1), recipient: kind == .offer ? nil : nonce(33), body: body)
            let expected = try hex(vectors[index]); XCTAssertEqual(W.encode(record), expected)
            var decoder = W.Decoder(); let records = try feed(expected, to: &decoder)
            XCTAssertEqual(records.count, 1)
            let decoded = try XCTUnwrap(records.first)
            XCTAssertEqual(decoded.kind, kind); XCTAssertEqual(decoded.sender, record.sender)
            XCTAssertEqual(decoded.recipient, record.recipient); XCTAssertEqual(decoded.body, body)
            XCTAssertEqual(try W.decodeRaw((Data([99]) + W.encodeRaw(record)).dropFirst()).body, body)
        }
    }
    func testMaximumRecordAndEscapeExpansionPreserveAllBytes() throws {
        for body in [Data((0..<W.maximumBodyBytes).map { UInt8(truncatingIfNeeded: $0) }),
                     Data((0..<W.maximumBodyBytes).map { $0 % 2 == 0 ? UInt8(0x7e) : 0x7d })] {
            let encoded = W.encode(try record(body)); XCTAssertLessThanOrEqual(encoded.count, W.maximumEncodedBytes)
            var decoder = W.Decoder(); XCTAssertEqual(try feed(encoded, to: &decoder).first?.body, body)
            XCTAssertTrue(decoder.isAtRecordBoundary); XCTAssertEqual(decoder.bufferedBytes, 0)
        }
    }
    func testEveryPartialOldRecordOffsetFindsNextWholeRecordOnly() throws {
        let old = W.encode(try record(Data((0..<512).map { UInt8(truncatingIfNeeded: $0) })))
        let fresh = W.encode(try W.Record(kind: .offer, sender: nonce(33), recipient: nil))
        for cut in 1..<old.count {
            var decoder = W.Decoder(); let records = try feed(old.dropFirst(cut) + fresh, to: &decoder)
            XCTAssertEqual(records.count, 1, "cut \(cut)")
            let decoded = try XCTUnwrap(records.first)
            XCTAssertEqual(decoded.kind, .offer); XCTAssertEqual(decoded.sender, try nonce(33))
            XCTAssertEqual(decoder.prefixDiscardedBytes, old.count - cut - 1)
        }
    }
    func testCompleteOldRecordKeepsItsEpochTagsAndNeedsHigherLayerAdmission() throws {
        let reset = try hex("000100080000000100000000")
        let old = W.encode(try record(reset))
        let fresh = W.encode(try W.Record(kind: .offer, sender: nonce(33), recipient: nil))
        var decoder = W.Decoder(); let records = try feed(old + fresh, to: &decoder)
        XCTAssertEqual(records.count, 2); XCTAssertEqual(records[0].body, reset)
        XCTAssertEqual(records[0].sender, try nonce(1)); XCTAssertEqual(records[1].kind, .offer)
        // Decoding never implies a fresh or authenticated link.
    }
    func testCorruptionRetiresDecoderInsteadOfScanningToLaterValidData() throws {
        var damaged = W.encode(try record(Data([0, 1])))
        damaged[1 + W.headerBytes] = 1
        let valid = W.encode(try record()); var decoder = W.Decoder()
        expect(.checksum) { _ = try feed(damaged, to: &decoder) }
        expect(.checksum) { _ = try feed(valid, to: &decoder) }
        XCTAssertFalse(decoder.isAtRecordBoundary)
    }
    func testMalformedEscapeIsTerminal() throws {
        for bytes in [try hex("7e7d7e"), try hex("7e7d01")] {
            var decoder = W.Decoder()
            expect(.escape) { _ = try feed(bytes, to: &decoder) }
            expect(.escape) { _ = try decoder.accept(0x7e) }
        }
    }
    func testPrefixAndDecodedRecordCapacityStayBounded() throws {
        var prefix = W.Decoder()
        for _ in 0..<(W.maximumEncodedBytes - 1) { XCTAssertNil(try prefix.accept(1)) }
        expect(.capacity) { _ = try prefix.accept(1) }; XCTAssertEqual(prefix.bufferedBytes, 0)
        var decoder = W.Decoder(); _ = try decoder.accept(0x7e)
        for _ in 0..<W.maximumRecordBytes { XCTAssertNil(try decoder.accept(1)) }
        expect(.capacity) { _ = try decoder.accept(1) }; XCTAssertEqual(decoder.bufferedBytes, W.maximumRecordBytes)
    }
    func testHeaderAndNonceRulesHoldWithValidChecksum() throws {
        let raw = W.encodeRaw(try record())
        let mutations: [(Int, UInt8)] = [(0, 0), (4, 1), (5, 127)]
        for (index, byte) in mutations {
            var bad = raw; bad[index] = byte
            expect(.header) { _ = try W.decodeRaw(repairingCRC(bad)) }
        }
        var senderZero = raw; senderZero.replaceSubrange(6..<38, with: repeatElement(UInt8(0), count: 32))
        expect(.nonce) { _ = try W.decodeRaw(repairingCRC(senderZero)) }
        var recipientZero = raw; recipientZero.replaceSubrange(38..<70, with: repeatElement(UInt8(0), count: 32))
        expect(.header) { _ = try W.decodeRaw(repairingCRC(recipientZero)) }
        var badLength = raw; badLength[70] = 0x7f
        expect(.body) { _ = try W.decodeRaw(badLength) }
        expect(.truncated) { _ = try W.decodeRaw(raw.prefix(10)) }
    }
    func testNonceAndBodyRemainImmutableValues() throws {
        var source = Data((1...32).map { UInt8($0) }), body = Data([3, 4])
        let n = try W.Nonce(source), r = try W.Record(kind: .data, sender: n, recipient: nonce(33), body: body)
        let before = W.encode(r)
        source[0] = 0; body[0] = 0
        var exposedNonce = n.bytes, exposedBody = r.body
        exposedNonce[0] = 0; exposedBody[0] = 0
        XCTAssertNotEqual(exposedNonce, n.bytes); XCTAssertNotEqual(exposedBody, r.body)
        XCTAssertEqual(W.encode(r), before); XCTAssertEqual(n, try nonce(1))
    }
    func testInvalidConstructedRecordsAreRejected() throws {
        let a = try nonce(1), b = try nonce(33)
        expect(.nonce) { _ = try W.Nonce(Data(count: 32)) }
        expect(.nonce) { _ = try W.Nonce(Data(repeating: 1, count: 33)) }
        expect(.header) { _ = try W.Record(kind: .offer, sender: a, recipient: b) }
        expect(.header) { _ = try W.Record(kind: .close, sender: a, recipient: a) }
        expect(.body) { _ = try W.Record(kind: .accept, sender: a, recipient: b, body: Data([1])) }
        expect(.body) { _ = try record(Data()) }
        expect(.body) { _ = try record(Data(count: W.maximumBodyBytes + 1)) }
    }
    func testEmptyFlagsAndPartialFrameAreNotRecords() throws {
        var decoder = W.Decoder(); XCTAssertFalse(decoder.isAtRecordBoundary)
        XCTAssertTrue(try feed(hex("7e7e7e"), to: &decoder).isEmpty); XCTAssertTrue(decoder.isAtRecordBoundary)
        let encoded = W.encode(try record())
        XCTAssertTrue(try feed(encoded.dropLast(), to: &decoder).isEmpty)
        XCTAssertFalse(decoder.isAtRecordBoundary); XCTAssertNotNil(try decoder.accept(0x7e))
    }
    func testStartupReportsEveryInterruptedWriterPrefixAndFindsFreshRecord() throws {
        let old = W.encode(try record(Data((0..<512).map { UInt8(truncatingIfNeeded: $0) })))
        let fresh = W.encode(try W.Record(kind: .offer, sender: nonce(33), recipient: nil))
        for cut in 1..<old.count {
            var d = W.Decoder(mode: .startup)
            let received = try events(old.prefix(cut) + fresh, to: &d)
            let records = received.compactMap { event -> W.Record? in
                if case .record(let record) = event { return record }; return nil
            }
            XCTAssertEqual(records.count, cut == old.count - 1 ? 2 : 1, "cut \(cut)")
            let last = try XCTUnwrap(records.last)
            XCTAssertEqual(last.kind, .offer); XCTAssertEqual(last.sender, try nonce(33))
            XCTAssertEqual(d.discardedRecords, cut == 1 || cut == old.count - 1 ? 0 : 1)
        }
    }
    func testSealingIsIrreversibleAndRequiresARecordBoundary() throws {
        let offer = W.encode(try W.Record(kind: .offer, sender: nonce(33), recipient: nil))
        var d = W.Decoder(mode: .startup); _ = try feed(offer, to: &d); try d.seal()
        let partial = W.encode(try record(Data(count: 512))).prefix(90)
        expect(.body) { _ = try events(partial + offer, to: &d) }; XCTAssertEqual(d.discardedRecords, 0)
        var unfinished = W.Decoder(mode: .startup)
        _ = try unfinished.accept(0x7e); _ = try unfinished.accept(1)
        expect(.state) { try unfinished.seal() }; expect(.state) { _ = try unfinished.accept(0x7e) }
    }
    func testStartupDiscardBudgetIsFiniteAndTerminal() throws {
        var d = W.Decoder(mode: .startup)
        for _ in 0..<W.maximumStartupDiscards {
            let received = try events(hex("7e007e"), to: &d)
            XCTAssertEqual(received.count, 1)
            guard case .discarded(let reason, let bytes) = try XCTUnwrap(received.first) else { return XCTFail("Expected a reported discard") }
            XCTAssertEqual(reason, .truncated); XCTAssertEqual(bytes, 1)
        }
        expect(.recoveryBudget) { _ = try events(hex("7e007e"), to: &d) }
        expect(.recoveryBudget) { _ = try d.accept(0x7e) }
    }
    func testStartupDamagedEscapeCannotWaitForAnUnboundedDelimiter() throws {
        var d = W.Decoder(mode: .startup)
        XCTAssertTrue(try events(hex("7e7d00"), to: &d).isEmpty)
        for _ in 0..<(W.maximumEncodedBytes - 4) { XCTAssertNil(try d.accept(1)) }
        expect(.capacity) { _ = try d.accept(1) }; XCTAssertEqual(d.bufferedBytes, 0)
    }
    func testStartupDoesNotFallbackFromIncompatibleVersion() throws {
        var d = W.Decoder(mode: .startup), oldVersion = W.encode(try record())
        oldVersion[5] = 1
        expect(.header) { _ = try events(oldVersion, to: &d) }; XCTAssertEqual(d.discardedRecords, 0)
    }
    func testStartupReportsChecksumDiscardAsAnExplicitEvent() throws {
        var damaged = W.encode(try record(Data([0, 1]))); damaged[1 + W.headerBytes] = 1
        let fresh = W.encode(try W.Record(kind: .offer, sender: nonce(33), recipient: nil))
        var d = W.Decoder(mode: .startup); let received = try events(damaged + fresh, to: &d)
        XCTAssertEqual(received.count, 2)
        guard case .discarded(let reason, _) = received[0], case .record(let record) = received[1] else { return XCTFail("Expected rejection and then the fresh record") }
        XCTAssertEqual(reason, .checksum); XCTAssertEqual(record.kind, .offer); XCTAssertEqual(d.discardedRecords, 1)
    }
}
