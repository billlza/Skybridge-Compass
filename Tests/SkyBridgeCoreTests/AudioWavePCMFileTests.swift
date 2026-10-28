import CryptoKit
import Foundation
import SkyBridgeProtocolCore
import XCTest
import os

@MainActor
final class AudioWavePCMFileTests: XCTestCase {
    func testEveryLegacyRepresentationPreservesDeclaredFormatAndExactPCMRange() async throws {
        let cases: [(UInt16, UInt16, AudioStreamingPCMFormat.Encoding)] = [
            (1, 8, .unsigned8), (1, 16, .signed16), (1, 24, .signed24), (1, 32, .signed32),
            (1, 64, .signed64), (3, 32, .float32), (3, 64, .float64)
        ]
        for (tag, bits, encoding) in cases {
            let samples = Data((0..<Int(bits / 8 * 4)).map { UInt8(($0 * 37 + 13) % 256) })
            let source = riff([("fmt ", format(tag: tag, bits: bits)), ("data", samples)])
            let observed = ReadTrace(source)
            let result = try await AudioWavePCMFile.inspect(fileSize: UInt64(source.count), read: observed.read)
            XCTAssertEqual(result.format.encoding, encoding); XCTAssertEqual(result.format.sampleRate, 44_100)
            XCTAssertEqual(result.format.channels, 2); XCTAssertEqual(result.format.declaredValidBits, UInt8(bits))
            XCTAssertNil(result.format.waveChannelMask)
            XCTAssertEqual(result.pcmByteOffset, 44); XCTAssertEqual(result.pcmByteCount, UInt64(samples.count))
            XCTAssertEqual(result.frameCount, 2)
            XCTAssertEqual(source.subdata(in: 44..<(44 + samples.count)), samples)
            XCTAssertTrue(observed.requests.withLock { $0.allSatisfy { $0.offset + UInt64($0.count) <= 44 } },
                          "Metadata inspection must not load PCM")
        }
    }

    func testExtensiblePrecisionAndRawChannelMaskAreNeverGuessedOrNormalized() async throws {
        for mask in [UInt32(0), 1, 3, 7, 0x8000_0000, .max] {
            let result = try await inspect(riff([("fmt ", format(bits: 32, extensible: true, validBits: 24, mask: mask)),
                                                ("data", Data(count: 16))]))
            XCTAssertEqual(result.format.encoding, .signed32)
            XCTAssertEqual(result.format.declaredValidBits, 24); XCTAssertEqual(result.format.waveChannelMask, mask)
            XCTAssertEqual(result.format.channels, 2); XCTAssertEqual(result.frameCount, 2)
            XCTAssertEqual(result.pcmByteOffset, 68)
        }
        let unknown = try await inspect(riff([("fmt ", format()), ("data", Data())]))
        let direct = try await inspect(riff([("fmt ", format(extensible: true, mask: 0)), ("data", Data())]))
        XCTAssertNil(unknown.format.waveChannelMask); XCTAssertEqual(direct.format.waveChannelMask, 0)
    }

    func testExtensibleFloat32And64RetainRepresentationWidth() async throws {
        for bits in [UInt16(32), 64] {
            let result = try await inspect(riff([("fmt ", format(tag: 3, bits: bits, extensible: true)),
                                                ("data", Data(count: Int(bits / 8 * 2)))]))
            XCTAssertEqual(result.format.encoding, bits == 32 ? .float32 : .float64)
            XCTAssertEqual(result.format.declaredValidBits, UInt8(bits)); XCTAssertEqual(result.frameCount, 1)
        }
    }

    func testPCMCbSizeIsIgnoredAndLongerExtensibleHeaderIsBounded() async throws {
        for extra in [Data(), Data([0xff]), Data([0xff, 0xff]), Data([0xff, 0xff, 0xa5])] {
            let result = try await inspect(riff([("fmt ", format() + extra), ("data", Data(count: 4))]))
            XCTAssertEqual(result.frameCount, 1)
        }
        var longer = format(extensible: true, rate: 12_345)
        put16(26, at: 16, into: &longer); longer.append(Data([9, 8, 7, 6]))
        let trace = ReadTrace(riff([("fmt ", longer), ("data", Data(count: 4))]))
        let result = try await AudioWavePCMFile.inspect(fileSize: UInt64(trace.bytes.count), read: trace.read)
        XCTAssertEqual(result.format.sampleRate, 12_345)
        XCTAssertEqual(trace.requests.withLock { $0.map(\.count).max() }, 40)
    }

    func testDataBeforeFormatOddPaddingAndMetadataChunksPreserveOffsets() async throws {
        let samples = Data([0, 128, 255])
        let wave = riff([("data", samples), ("JUNK", Data([1, 2, 3])), ("LIST", ascii("INFO")),
                         ("fmt ", format(bits: 8, channels: 1))])
        let result = try await inspect(wave)
        XCTAssertEqual(result.pcmByteOffset, 20); XCTAssertEqual(result.pcmByteCount, 3); XCTAssertEqual(result.frameCount, 3)
        XCTAssertEqual(wave[23], 0xa5, "A nonzero RIFF alignment pad is not part of the source samples")
    }

    func testEmptyAudioIsAnExplicitZeroFrameRange() async throws {
        let result = try await inspect(riff([("fmt ", format()), ("data", Data())]))
        XCTAssertEqual(result.pcmByteOffset, 44); XCTAssertEqual(result.pcmByteCount, 0); XCTAssertEqual(result.frameCount, 0)
    }

    func testDuplicateRequiredChunksAndSegmentedAudioAreRejectedEvenAfterData() async throws {
        let base: [(String, Data)] = [("fmt ", format()), ("data", Data(count: 4))]
        for tail in [[("fmt ", format())], [("data", Data())], [("LIST", ascii("wavl"))], [("slnt", Data(count: 4))]] {
            await rejects(riff(base + tail), .unsupportedLayout)
        }
        await rejects(riff(base + [("LIST", Data(count: 3))]), .malformed)
        await rejects(riff([("fmt ", format())]), .malformed)
        await rejects(riff([("data", Data(count: 4))]), .malformed)
    }

    func testTruncatedHeadersPayloadsAndPaddingCannotBeAccepted() async throws {
        let wave = riff([("fmt ", format(bits: 8, channels: 1)), ("data", Data([1]))])
        for length in 0..<wave.count { await rejects(Data(wave.prefix(length)), .truncated) }
        var noPadding = Data(wave.dropLast()); put32(UInt32(noPadding.count - 8), at: 4, into: &noPadding)
        await rejects(noPadding, .truncated)
        await rejects(riff([("fmt ", Data(count: 15)), ("data", Data())]), .truncated)
        var partialChunk = riff([("fmt ", format()), ("data", Data())]) + Data([1, 2, 3])
        put32(UInt32(partialChunk.count - 8), at: 4, into: &partialChunk)
        await rejects(partialChunk, .truncated)
    }

    func testContainersTrailingBytesAndCompressedOrUnsupportedSamplesFailExplicitly() async throws {
        let wave = riff([("fmt ", format()), ("data", Data())])
        for tag in ["RIFX", "RF64", "riff"] {
            var changed = wave; changed.replaceSubrange(0..<4, with: ascii(tag))
            await rejects(changed, .unsupportedContainer)
        }
        var wrongType = wave; wrongType.replaceSubrange(8..<12, with: ascii("AVI "))
        await rejects(wrongType, .unsupportedContainer)
        await rejects(wave + Data([0]), .unsupportedLayout)
        var undersized = wave; put32(3, at: 4, into: &undersized)
        await rejects(undersized, .malformed)
        let unsupported: [(UInt16, UInt16)] = [(2, 16), (6, 8), (7, 8), (1, 20), (3, 16), (3, 24)]
        for (tag, bits) in unsupported {
            await rejects(riff([("fmt ", format(tag: tag, bits: bits)), ("data", Data())]), .unsupportedEncoding)
        }
    }

    func testFormatBoundsFrameAlignmentAndByteRateAreCheckedWithoutOverflow() async throws {
        let invalidFields: [(Int, Int, UInt32)] = [(2, 2, 0), (4, 4, 0), (8, 4, 0), (12, 2, 3), (8, 4, .max)]
        for (offset, width, value) in invalidFields {
            var invalid = format()
            if width == 2 { put16(UInt16(value), at: offset, into: &invalid) } else { put32(value, at: offset, into: &invalid) }
            await rejects(riff([("fmt ", invalid), ("data", Data())]), .malformed)
        }
        await rejects(riff([("fmt ", format()), ("data", Data(count: 3))]), .malformed)
        await rejects(riff([("fmt ", format(bits: 64, channels: .max)), ("data", Data())]), .malformed)
        await rejects(riff([("fmt ", format(rate: .max)), ("data", Data())]), .malformed)
        let edge = try await inspect(riff([("fmt ", format(bits: 8, channels: .max, rate: 65_537)), ("data", Data())]))
        XCTAssertEqual(edge.format.bytesPerFrame, UInt32(UInt16.max))
        XCTAssertEqual(UInt64(edge.format.bytesPerFrame) * UInt64(edge.format.sampleRate), UInt64(UInt32.max))
    }

    func testExtensibleSizesPrecisionAndEntireGUIDAreValidated() async throws {
        let valid = format(bits: 32, extensible: true, validBits: 24)
        await rejects(riff([("fmt ", Data(valid.prefix(39))), ("data", Data())]), .truncated)
        for size in [UInt16(0), 21, 23, .max] {
            var invalid = valid; put16(size, at: 16, into: &invalid)
            await rejects(riff([("fmt ", invalid), ("data", Data())]), .malformed)
        }
        await rejects(riff([("fmt ", format(bits: 32, extensible: true, validBits: 0)), ("data", Data())]), .undeclaredPrecision)
        await rejects(riff([("fmt ", format(bits: 32, extensible: true, validBits: 33)), ("data", Data())]), .malformed)
        await rejects(riff([("fmt ", format(tag: 3, bits: 32, extensible: true, validBits: 24)), ("data", Data())]), .malformed)
        for index in 24..<40 {
            var invalid = valid; invalid[index] ^= 1
            await rejects(riff([("fmt ", invalid), ("data", Data())]), .unsupportedEncoding)
        }
    }

    func testOversizedSourcesAreRejectedBeforeAnyRead() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        for size in [UInt64.max, AudioStreamingWire.maximumFileBytes + 1, AudioWavePCMFile.maximumFileBytes + 1] {
            do {
                _ = try await AudioWavePCMFile.inspect(fileSize: size) { _, _ in reads.withLock { $0 += 1 }; return Data() }
                XCTFail("Oversized source accepted")
            } catch { XCTAssertEqual(error as? AudioWavePCMFileError, .oversized) }
        }
        XCTAssertEqual(reads.withLock { $0 }, 0)
    }

    func testUnsignedChunkSizeBeyondTwoGiBSkipsWithoutAllocatingItsPayload() async throws {
        let junkSize: UInt32 = 0x8000_0001
        let tailOffset = UInt64(20) + UInt64(junkSize) + 1
        let tail = chunk("fmt ", format()) + chunk("data", Data(count: 4))
        let fileSize = tailOffset + UInt64(tail.count)
        let prefix = ascii("RIFF") + le32(UInt32(fileSize - 8)) + ascii("WAVEJUNK") + le32(junkSize)
        let requests = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let result = try await AudioWavePCMFile.inspect(fileSize: fileSize) { offset, count in
            requests.withLock { $0.append(count) }
            if offset < UInt64(prefix.count) { return prefix.subdata(in: Int(offset)..<(Int(offset) + count)) }
            guard offset >= tailOffset else { throw FixtureError.unexpectedRead }
            let start = Int(offset - tailOffset)
            return tail.subdata(in: start..<(start + count))
        }
        XCTAssertEqual(result.pcmByteOffset, tailOffset + 32); XCTAssertEqual(result.pcmByteCount, 4)
        XCTAssertEqual(result.frameCount, 1); XCTAssertLessThanOrEqual(requests.withLock { $0.max() ?? 0 }, 40)
        var hugeChunk = riff([("fmt ", format()), ("data", Data())])
        put32(.max, at: 40, into: &hugeChunk)
        await rejects(hugeChunk, .truncated)
    }

    func testHugeDeclaredFormatReadsOnlyItsFirstFortyBytes() async throws {
        let size: UInt32 = 0x8000_0000
        let dataHeaderOffset = UInt64(20) + UInt64(size)
        let fileSize = dataHeaderOffset + 8
        let header = ascii("RIFF") + le32(UInt32(fileSize - 8)) + ascii("WAVE")
        let formatHeader = ascii("fmt ") + le32(size)
        let formatBytes = format(extensible: true)
        let trace = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let result = try await AudioWavePCMFile.inspect(fileSize: fileSize) { offset, count in
            trace.withLock { $0.append(count) }
            switch offset {
            case 0: return header
            case 12: return formatHeader
            case 20: return formatBytes
            case dataHeaderOffset: return Data("data".utf8) + Data(count: 4)
            default: throw FixtureError.unexpectedRead
            }
        }
        XCTAssertEqual(result.frameCount, 0); XCTAssertEqual(result.pcmByteOffset, fileSize)
        XCTAssertEqual(trace.withLock { $0 }, [12, 8, 40, 8])
    }

    func testChunkBudgetHasAnExactBoundary() async throws {
        let valid = [("fmt ", format()), ("data", Data())] + Array(repeating: ("JUNK", Data()), count: 4_094)
        _ = try await inspect(riff(valid))
        await rejects(riff(valid + [("JUNK", Data())]), .chunkLimit)
    }

    func testReadLengthContractAndOriginalReadErrorsAreNotHidden() async throws {
        let bytes = riff([("fmt ", format()), ("data", Data())])
        for delta in [-1, 1] {
            do {
                _ = try await AudioWavePCMFile.inspect(fileSize: UInt64(bytes.count)) { _, count in Data(count: count + delta) }
                XCTFail("Invalid read length accepted")
            } catch { XCTAssertEqual(error as? AudioWavePCMFileError, delta < 0 ? .truncated : .invalidReadLength) }
        }
        do {
            _ = try await AudioWavePCMFile.inspect(fileSize: UInt64(bytes.count)) { _, _ in throw FixtureError.sourceFailure }
            XCTFail("Read failure swallowed")
        } catch { XCTAssertEqual(error as? FixtureError, .sourceFailure) }
        // A Data subsequence may have a nonzero startIndex; parsing uses bounded normalized bytes.
        let padded = Data([0xaa]) + bytes
        let result = try await AudioWavePCMFile.inspect(fileSize: UInt64(bytes.count)) { offset, count in
            padded[(Int(offset) + 1)..<(Int(offset) + 1 + count)]
        }
        XCTAssertEqual(result.frameCount, 0)
    }

    func testCancellationAfterReadPropagatesWithoutMoreReads() async throws {
        let bytes = riff([("fmt ", format()), ("data", Data())])
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            try await AudioWavePCMFile.inspect(fileSize: UInt64(bytes.count)) { offset, count in
                reads.withLock { $0 += 1 }
                withUnsafeCurrentTask { $0?.cancel() }
                return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(reads.withLock { $0 }, 1)
    }

    func testPreparedOutboundReaderReturnsOriginalIntegerAndFloatPayloadBytes() async throws {
        let fixtures: [(Data, Data)] = [
            (format(bits: 24, extensible: true), Data([255, 255, 127, 0, 0, 128, 1, 0, 0, 255, 255, 255])),
            (format(tag: 3, bits: 64, extensible: true), Data([0x45, 0x23, 0x01, 0, 0, 0, 0xf8, 0x7f, 0, 0, 0, 0, 0, 0, 0, 0x80]))
        ]
        for (description, pcm) in fixtures {
            let wave = riff([("JUNK", Data([0xa1])), ("fmt ", description), ("data", pcm)])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-wave-\(UUID().uuidString).wav")
            try wave.write(to: url, options: .withoutOverwriting)
            let reader = try await PreparedOutboundFileReadSession.prepare(url: url,
                maximumSize: Int64(AudioStreamingWire.maximumFileBytes), sourcePolicy: .regularFile,
                expectedSHA256: Data(SHA256.hash(data: wave)))
            let metadata: AudioWavePCMMetadata
            do {
                metadata = try await AudioWavePCMFile.inspect(fileSize: UInt64(reader.metadata.fileSize)) { offset, count in
                    try await reader.read(offset: offset, length: count)
                }
                let actual = try await reader.read(offset: metadata.pcmByteOffset, length: Int(metadata.pcmByteCount))
                XCTAssertEqual(actual, pcm, "Integer low bits, IEEE NaN payloads and negative zero remain byte-identical")
                XCTAssertEqual(reader.metadata.contentSHA256, Data(SHA256.hash(data: wave)))
            } catch {
                try await reader.close(); try FileManager.default.removeItem(at: url); throw error
            }
            try await reader.close(); try FileManager.default.removeItem(at: url)
            XCTAssertEqual(metadata.pcmByteCount, UInt64(pcm.count))
        }
    }

    private func inspect(_ bytes: Data) async throws -> AudioWavePCMMetadata {
        try await AudioWavePCMFile.inspect(fileSize: UInt64(bytes.count)) { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }
    private func rejects(_ bytes: Data, _ expected: AudioWavePCMFileError, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await inspect(bytes); XCTFail("Malformed WAVE accepted", file: file, line: line) }
        catch { XCTAssertEqual(error as? AudioWavePCMFileError, expected, file: file, line: line) }
    }
    private enum FixtureError: Error, Equatable { case unexpectedRead, sourceFailure }
    private final class ReadTrace: Sendable {
        struct Request: Sendable { let offset: UInt64; let count: Int }
        let bytes: Data
        let requests = OSAllocatedUnfairLock<[Request]>(initialState: [])
        init(_ bytes: Data) { self.bytes = bytes }
        func read(offset: UInt64, count: Int) async throws -> Data {
            requests.withLock { $0.append(.init(offset: offset, count: count)) }
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }

    private func ascii(_ text: String) -> Data { Data(text.utf8) }
    private func le16(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    private func le32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private func put16(_ value: UInt16, at offset: Int, into bytes: inout Data) { bytes.replaceSubrange(offset..<(offset + 2), with: le16(value)) }
    private func put32(_ value: UInt32, at offset: Int, into bytes: inout Data) { bytes.replaceSubrange(offset..<(offset + 4), with: le32(value)) }
    private func format(tag: UInt16 = 1, bits: UInt16 = 16, channels: UInt16 = 2, extensible: Bool = false,
                        validBits: UInt16? = nil, mask: UInt32 = 3, rate: UInt32 = 44_100) -> Data {
        let frameBytes = UInt64(channels) * UInt64(bits / 8)
        var result = le16(extensible ? 0xfffe : tag) + le16(channels) + le32(rate)
        result.append(le32(UInt32(truncatingIfNeeded: UInt64(rate) * frameBytes)))
        result.append(le16(UInt16(truncatingIfNeeded: frameBytes))); result.append(le16(bits))
        if extensible {
            result.append(le16(22)); result.append(le16(validBits ?? bits)); result.append(le32(mask))
            result.append(le32(UInt32(tag)))
            result.append(Data([0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]))
        }
        return result
    }
    private func chunk(_ id: String, _ payload: Data) -> Data {
        ascii(id) + le32(UInt32(payload.count)) + payload + (payload.count % 2 == 0 ? Data() : Data([0xa5]))
    }
    private func riff(_ chunks: [(String, Data)]) -> Data {
        let body = ascii("WAVE") + chunks.reduce(into: Data()) { $0.append(chunk($1.0, $1.1)) }
        return ascii("RIFF") + le32(UInt32(body.count)) + body
    }
}
