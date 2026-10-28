import CryptoKit
import Foundation
import XCTest
import SkyBridgeProtocolCore

@MainActor
final class AudioAlacFileTests: XCTestCase {
    private enum Failure: Error { case fixture, unexpectedRead }
    private final class Revoked: Error {}
    private struct Vector: Decodable, Sendable {
        struct Expected: Decodable, Sendable { let rate: UInt32; let channels: UInt16; let validBits: UInt8; let frames: UInt64 }
        struct Segment: Decodable, Sendable { let offset: Int; let bytes: Data }
        let name: String; let fileSize: Int; let sourceSha256: String
        let expected: Expected; let ranges: [Segment]
        var bytes: Data {
            var result = Data(count: fileSize)
            for range in ranges { result.replaceSubrange(range.offset..<(range.offset + range.bytes.count), with: range.bytes) }
            return result
        }
        func metadataRead(_ offset: UInt64, _ count: Int) throws -> Data {
            guard let range = ranges.first(where: {
                offset >= $0.offset && offset <= $0.offset + $0.bytes.count && UInt64(count) <= UInt64($0.offset + $0.bytes.count) - offset
            }) else { throw Failure.unexpectedRead }
            let start = Int(offset) - range.offset
            return range.bytes.subdata(in: start..<(start + count))
        }
    }
    private struct ExpectedPacket: Decodable {
        let index: UInt64; let offset: UInt64; let length: Int; let firstFrameIndex: UInt64; let frames: UInt32
    }
    private struct PacketVector: Decodable { let name: String; let sourceSha256: String; let packets: [ExpectedPacket] }

    func testRealEncoderMetadataAndIndependentPacketIndexesWithoutReadingAudio() throws {
        let vectors = try metadataVectors()
        let packets: [PacketVector] = try resource("alac-packet-index-v1", schema: "alac-packet-index-v1")
        XCTAssertEqual(vectors.count, 24); XCTAssertEqual(packets.count, 24)
        for vector in vectors {
            let metadata = try AudioAlacFile.inspect(fileSize: UInt64(vector.fileSize), read: vector.metadataRead)
            XCTAssertEqual(metadata.decodedFormat.sampleRate, vector.expected.rate, vector.name)
            XCTAssertEqual(metadata.decodedFormat.channels, vector.expected.channels, vector.name)
            XCTAssertEqual(metadata.decodedFormat.declaredValidBits, vector.expected.validBits, vector.name)
            XCTAssertEqual(metadata.totalFrames, vector.expected.frames, vector.name)
            XCTAssertEqual(metadata.configuration.count, 24)
            let reference = try XCTUnwrap(packets.first(where: { $0.name == vector.name }))
            XCTAssertEqual(reference.sourceSha256, vector.sourceSha256)
            XCTAssertEqual(metadata.packetCount, UInt64(reference.packets.count))
            XCTAssertEqual(metadata.encodedAudioBytes, reference.packets.reduce(UInt64(0)) { $0 + UInt64($1.length) })
            var cursor = metadata.makePacketCursor()
            for expected in reference.packets {
                let packet = try XCTUnwrap(cursor.next(read: vector.metadataRead))
                assertPacket(packet, expected, vector.name)
            }
            XCTAssertNil(try cursor.next(read: vector.metadataRead))
            XCTAssertNil(try cursor.next(read: vector.metadataRead))
        }
    }

    func testUnsupportedAndMalformedDeclarationsDoNotProduceAnIndex() throws {
        let original = try base().bytes
        typealias Change = (inout Data) throws -> Void
        let cases: [(String, AudioAlacFileError, Change)] = [
            ("missing ftyp", .unsupportedContainer, { try self.tag(&$0, "ftyp", "free") }),
            ("missing movie", .malformed, { try self.tag(&$0, "moov", "free") }),
            ("disabled track", .unsupportedLayout, { try self.set(&$0, "tkhd", 0, 0) }),
            ("multiple tracks", .unsupportedLayout, { try self.tag(&$0, "udta", "trak") }),
            ("edit timeline", .unsupportedLayout, { try self.tag(&$0, "tkhd", "edts") }),
            ("fragmented movie", .unsupportedLayout, { try self.tag(&$0, "udta", "mvex") }),
            ("fragmented media", .unsupportedLayout, { try self.tag(&$0, "ftyp", "moof") }),
            ("sample grouping", .unsupportedLayout, { try self.tag(&$0, "stts", "sgpd") }),
            ("external URL", .unsupportedLayout, { try self.set(&$0, "url ", 0, 0) }),
            ("external URN", .unsupportedLayout, { try self.tag(&$0, "url ", "urn ") }),
            ("extra reference", .unsupportedLayout, { try self.set(&$0, "dref", 4, 2) }),
            ("AAC sample", .unsupportedEncoding, { try self.tag(&$0, "alac", "mp4a") }),
            ("encrypted sample", .unsupportedEncoding, { try self.tag(&$0, "alac", "enca") }),
            ("extra description", .unsupportedLayout, { try self.set(&$0, "stsd", 4, 2) }),
            ("unsupported sample version", .unsupportedLayout, { data in data[try self.payload(data, "alac") + 9] = 1 }),
            ("codec version", .unsupportedEncoding, { data in data[try self.payload(data, "alac", 1) + 8] = 1 }),
            ("unknown precision", .unsupportedEncoding, { data in data[try self.payload(data, "alac", 1) + 9] = 31 }),
            ("channel order", .unsupportedLayout, { data in data[try self.payload(data, "alac", 1) + 13] = 6 }),
            ("native frame limit", .metadataLimit, { try self.set(&$0, "alac", 4, 65537, 1) }),
            ("packet size bound", .malformed, { try self.set(&$0, "alac", 16, 1, 1) }),
            ("empty time run", .malformed, { try self.set(&$0, "stts", 8, 0) }),
            ("tail frame mismatch", .malformed, { try self.set(&$0, "stts", 20, 720) }),
            ("packet count", .malformed, { try self.set(&$0, "stsz", 8, 3) }),
            ("zero packet size", .malformed, { try self.set(&$0, "stsz", 12, 0) }),
            ("offset before media", .malformed, { try self.set(&$0, "stco", 8, 8) }),
            ("offset past media", .malformed, { data in try self.set(&data, "stco", 8, UInt32(data.count - 1)) }),
            ("zero first chunk", .malformed, { try self.set(&$0, "stsc", 8, 0) }),
            ("extra chunk packets", .malformed, { try self.set(&$0, "stsc", 12, 3) }),
            ("different description", .malformed, { try self.set(&$0, "stsc", 16, 2) }),
            ("wrong wide table size", .malformed, { try self.tag(&$0, "stco", "co64") })
        ]
        for (name, expected, change) in cases {
            var data = original; try change(&data)
            XCTAssertThrowsError(try inspect(data), name) { XCTAssertEqual($0 as? AudioAlacFileError, expected, name) }
        }
    }

    func testCallbackErrorsShortReadsAndExcessReadsRemainFailures() throws {
        let vector = try base(), error = Revoked()
        XCTAssertThrowsError(try AudioAlacFile.inspect(fileSize: UInt64(vector.fileSize), read: { _, _ in throw error })) {
            XCTAssertTrue(($0 as? Revoked) === error)
        }
        for (delta, expected) in [(-1, AudioAlacFileError.truncated), (1, .invalidReadLength)] {
            XCTAssertThrowsError(try AudioAlacFile.inspect(fileSize: UInt64(vector.fileSize), read: { _, count in
                Data(count: count + delta)
            })) { XCTAssertEqual($0 as? AudioAlacFileError, expected) }
        }
    }

    func testCancellationAndRevocationCoverCachedIndexReadsAndCompletion() async throws {
        let vector = try base(), error = Revoked()
        XCTAssertThrowsError(try AudioAlacFile.inspect(fileSize: UInt64(vector.fileSize),
            read: { _, _ in throw Failure.unexpectedRead }, requireCurrent: { throw error })) {
            XCTAssertTrue(($0 as? Revoked) === error)
        }
        let operation = Task {
            try AudioAlacFile.inspect(fileSize: UInt64(vector.fileSize), read: { offset, count in
                withUnsafeCurrentTask { $0?.cancel() }
                return try vector.metadataRead(offset, count)
            })
        }
        do { _ = try await operation.value; XCTFail("Cancelled inspection returned metadata") }
        catch { XCTAssertTrue(error is CancellationError) }
        let metadata = try AudioAlacFile.inspect(fileSize: UInt64(vector.fileSize), read: vector.metadataRead)
        var cursor = metadata.makePacketCursor()
        XCTAssertNotNil(try cursor.next(read: vector.metadataRead))
        XCTAssertThrowsError(try cursor.next(read: { _, _ in throw Failure.unexpectedRead }, requireCurrent: { throw error })) {
            XCTAssertTrue(($0 as? Revoked) === error)
        }
        XCTAssertThrowsError(try cursor.next(read: vector.metadataRead)) { XCTAssertTrue(($0 as? Revoked) === error) }
        var complete = metadata.makePacketCursor()
        while try complete.next(read: vector.metadataRead) != nil {}
        XCTAssertThrowsError(try complete.next(read: vector.metadataRead, requireCurrent: { throw error })) {
            XCTAssertTrue(($0 as? Revoked) === error)
        }
    }

    func testIndexReadFailureAfterInspectionIsSticky() throws {
        let vector = try base(), error = Revoked()
        let metadata = try AudioAlacFile.inspect(fileSize: UInt64(vector.fileSize), read: vector.metadataRead)
        var cursor = metadata.makePacketCursor()
        XCTAssertThrowsError(try cursor.next(read: { _, _ in throw error })) { XCTAssertTrue(($0 as? Revoked) === error) }
        XCTAssertThrowsError(try cursor.next(read: vector.metadataRead)) { XCTAssertTrue(($0 as? Revoked) === error) }
    }

    func testEveryStructuralPrefixAndMissingMediaTailFail() throws {
        let data = try base().bytes, boundary = try payload(data, "mdat")
        for length in 0..<boundary {
            XCTAssertThrowsError(try inspect(Data(data.prefix(length))), "prefix=\(length)") {
                XCTAssertNotNil($0 as? AudioAlacFileError)
            }
        }
        XCTAssertThrowsError(try inspect(Data(data.dropLast()))) { XCTAssertEqual($0 as? AudioAlacFileError, .truncated) }
    }

    func testOversizedSourceAndBoxFloodStopBeforeUnboundedWork() throws {
        XCTAssertThrowsError(try AudioAlacFile.inspect(fileSize: AudioAlacFile.maximumFileBytes + 1,
            read: { _, _ in throw Failure.unexpectedRead })) { XCTAssertEqual($0 as? AudioAlacFileError, .oversized) }
        let data = (0...AudioAlacFile.maximumBoxes).reduce(into: Data()) { value, _ in value.append(box("free", Data())) }
        var reads = 0
        XCTAssertThrowsError(try AudioAlacFile.inspect(fileSize: UInt64(data.count), read: { offset, count in
            reads += 1; return try self.read(data, offset, count)
        })) { XCTAssertEqual($0 as? AudioAlacFileError, .metadataLimit) }
        XCTAssertEqual(reads, AudioAlacFile.maximumBoxes)
    }

    func testMetadataAtEndWideOffsetsAndPagedVariableOrFixedSizes() throws {
        for wide in [false, true] { for fixed in [false, true] {
            let file = try synthetic(frames: Array(repeating: 1, count: 17003),
                sizes: Array(repeating: 1, count: 17003), groups: Array(repeating: 1, count: 17003), wide: wide, fixed: fixed)
            var maximumRead = 0
            let read: (UInt64, Int) throws -> Data = { offset, count in
                guard offset + UInt64(count) <= file.media.lowerBound || offset >= file.media.upperBound else { throw Failure.unexpectedRead }
                maximumRead = max(maximumRead, count)
                return try self.read(file.bytes, offset, count)
            }
            let metadata = try AudioAlacFile.inspect(fileSize: UInt64(file.bytes.count), read: read)
            var cursor = metadata.makePacketCursor()
            for expected in file.packets { assertPacket(try XCTUnwrap(cursor.next(read: read)), expected) }
            XCTAssertNil(try cursor.next(read: read)); XCTAssertEqual(maximumRead, AudioAlacFile.maximumReadBytes)
        } }
    }

    func testDifferentChunkAndTimingRunsPreserveExactPacketPositions() throws {
        let file = try synthetic(frames: [1, 2, 2, 3, 3], sizes: [1, 2, 3, 4, 5], groups: [2, 3])
        let metadata = try inspect(file.bytes)
        XCTAssertEqual(metadata.totalFrames, 11)
        var cursor = metadata.makePacketCursor()
        for expected in file.packets { assertPacket(try XCTUnwrap(cursor.next(read: { try self.read(file.bytes, $0, $1) })), expected) }
        XCTAssertNil(try cursor.next(read: { try self.read(file.bytes, $0, $1) }))
    }

    func testExplicitLayoutsAndOpenEndedMediaRemainUnambiguous() throws {
        for embedded in [false, true] {
            let file = try synthetic(frames: [1, 1], sizes: [1, 1], groups: [1, 1], layout: embedded ? 2 : 1)
            XCTAssertEqual(try inspect(file.bytes).decodedFormat.waveChannelMask, 3)
            var invalid = file.bytes; try set(&invalid, "chan", 4, 0)
            XCTAssertThrowsError(try inspect(invalid)) { XCTAssertEqual($0 as? AudioAlacFileError, .unsupportedLayout) }
        }
        var data = try base().bytes
        put32(&data, try payload(data, "mdat") - 8, 0)
        try set(&data, "alac", 16, 0, 1)
        XCTAssertNil(try inspect(data).maximumPacketBytes)
    }

    private func metadataVectors() throws -> [Vector] { try resource("alac-m4a-metadata-v1", schema: "alac-m4a-metadata-v1") }
    private struct Envelope<T: Decodable>: Decodable { let schema: String; let vectors: [T] }
    private func resource<T: Decodable>(_ name: String, schema: String) throws -> [T] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let value = try JSONDecoder().decode(Envelope<T>.self, from: Data(contentsOf: url))
        guard value.schema == schema else { throw Failure.fixture }
        return value.vectors
    }
    private func base() throws -> Vector { try XCTUnwrap(metadataVectors().first(where: { $0.name == "48000-2-s24" })) }
    private func read(_ data: Data, _ offset: UInt64, _ count: Int) throws -> Data {
        guard offset <= data.count, count >= 0, UInt64(count) <= UInt64(data.count) - offset else { throw Failure.unexpectedRead }
        return data.subdata(in: Int(offset)..<(Int(offset) + count))
    }
    private func inspect(_ data: Data) throws -> AudioAlacMetadata {
        try AudioAlacFile.inspect(fileSize: UInt64(data.count)) { try read(data, $0, $1) }
    }
    private func assertPacket(_ packet: AudioAlacPacket, _ expected: ExpectedPacket, _ name: String = "") {
        XCTAssertEqual(packet.index, expected.index, name); XCTAssertEqual(packet.byteOffset, expected.offset, name)
        XCTAssertEqual(packet.byteCount, expected.length, name); XCTAssertEqual(packet.firstFrameIndex, expected.firstFrameIndex, name)
        XCTAssertEqual(packet.frameCount, expected.frames, name)
    }
    private func payload(_ data: Data, _ name: String, _ occurrence: Int = 0) throws -> Int {
        var start = 0, found = 0
        for _ in 0...occurrence {
            guard let range = data.range(of: Data(name.utf8), in: start..<data.count) else { throw Failure.fixture }
            found = range.upperBound; start = found
        }
        return found
    }
    private func tag(_ data: inout Data, _ old: String, _ new: String) throws {
        let at = try payload(data, old) - 4; data.replaceSubrange(at..<(at + 4), with: Data(new.utf8))
    }
    private func set(_ data: inout Data, _ name: String, _ offset: Int, _ value: UInt32, _ occurrence: Int = 0) throws {
        let at = try payload(data, name, occurrence) + offset; put32(&data, at, value)
    }
    private func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) { data.replaceSubrange(offset..<(offset + 4), with: word(value)) }
    private func word(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) }) }
    private func longWord(_ value: UInt64) -> Data { word(UInt32(value >> 32)) + word(UInt32(truncatingIfNeeded: value)) }
    private func box(_ name: String, _ payload: Data) -> Data { word(UInt32(payload.count + 8)) + Data(name.utf8) + payload }

    private struct Synthetic { let bytes: Data; let media: Range<UInt64>; let packets: [ExpectedPacket] }
    private func synthetic(frames: [UInt32], sizes: [UInt32], groups: [Int], wide: Bool = false,
                           fixed: Bool = false, layout: Int = 0) throws -> Synthetic {
        guard let frameMaximum = frames.max(), let sizeMaximum = sizes.max(), let firstSize = sizes.first,
              frames.count == sizes.count, groups.allSatisfy({ $0 > 0 }), groups.reduce(0, +) == sizes.count,
              frames.allSatisfy({ $0 > 0 }), sizes.allSatisfy({ $0 > 0 }),
              !fixed || sizes.allSatisfy({ $0 == firstSize }) else { throw Failure.fixture }
        let ftyp = box("ftyp", Data("M4A ".utf8) + word(0) + Data("M4A ".utf8))
        let mediaBytes = sizes.reduce(0) { $0 + Int($1) }, mediaStart = UInt64(ftyp.count + (wide ? 16 : 8))
        let mdat = (wide ? word(1) + Data("mdat".utf8) + longWord(UInt64(mediaBytes + 16)) : word(UInt32(mediaBytes + 8)) + Data("mdat".utf8)) + Data(count: mediaBytes)
        var cookie = Data(count: 28)
        put32(&cookie, 4, frameMaximum); cookie[9] = 24; cookie[10] = 40; cookie[11] = 10; cookie[12] = 14; cookie[13] = 2
        cookie[15] = 255; put32(&cookie, 16, sizeMaximum); put32(&cookie, 24, 48000)
        let chan = box("chan", word(0) + word((101 << 16) + 2) + word(0) + word(0))
        if layout == 2 { cookie.append(chan) }
        var audio = Data(count: 28); audio[7] = 1; audio[17] = 2; audio[19] = 16; put32(&audio, 24, 44100 << 16)
        audio.append(box("alac", cookie)); if layout == 1 { audio.append(chan) }
        let stsd = box("stsd", word(0) + word(1) + box("alac", audio))
        var timeRows: [(count: UInt32, delta: UInt32)] = []
        for value in frames {
            if timeRows.last?.delta == value { timeRows[timeRows.count - 1].count += 1 }
            else { timeRows.append((1, value)) }
        }
        let stts = box("stts", word(0) + word(UInt32(timeRows.count)) + timeRows.reduce(into: Data()) { $0.append(word($1.count) + word($1.delta)) })
        var runRows: [(first: UInt32, count: UInt32)] = [], offsets = Data()
        var packet = 0, position = mediaStart, firstFrame: UInt64 = 0, expected: [ExpectedPacket] = []
        for (chunk, count) in groups.enumerated() {
            if runRows.last?.count != UInt32(count) { runRows.append((UInt32(chunk + 1), UInt32(count))) }
            offsets.append(wide ? longWord(position) : word(UInt32(position)))
            for _ in 0..<count {
                expected.append(ExpectedPacket(index: UInt64(packet), offset: position, length: Int(sizes[packet]), firstFrameIndex: firstFrame, frames: frames[packet]))
                position += UInt64(sizes[packet]); firstFrame += UInt64(frames[packet]); packet += 1
            }
        }
        let stsc = box("stsc", word(0) + word(UInt32(runRows.count)) + runRows.reduce(into: Data()) { $0.append(word($1.first) + word($1.count) + word(1)) })
        let stsz = box("stsz", word(0) + word(fixed ? firstSize : 0) + word(UInt32(sizes.count)) + (fixed ? Data() : sizes.reduce(into: Data()) { $0.append(word($1)) }))
        let stco = box(wide ? "co64" : "stco", word(0) + word(UInt32(groups.count)) + offsets)
        let dinf = box("dinf", box("dref", word(0) + word(1) + box("url ", word(1))))
        let minf = box("minf", dinf + box("stbl", stsd + stts + stsc + stsz + stco))
        let mdhd = box("mdhd", wide ? word(0x01000000) + longWord(0) + longWord(0) + word(48000) + longWord(firstFrame) + word(0)
            : word(0) + word(0) + word(0) + word(48000) + word(UInt32(firstFrame)) + word(0))
        let hdlr = box("hdlr", word(0) + word(0) + Data("soun".utf8) + Data(count: 12))
        let trak = box("trak", box("tkhd", word(1) + Data(count: 80)) + box("mdia", mdhd + hdlr + minf))
        return Synthetic(bytes: ftyp + mdat + box("moov", trak), media: mediaStart..<(mediaStart + UInt64(mediaBytes)), packets: expected)
    }
}
