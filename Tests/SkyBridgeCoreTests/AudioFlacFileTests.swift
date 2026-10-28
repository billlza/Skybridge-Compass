import Foundation
import SkyBridgeProtocolCore
import XCTest
import os

@MainActor
final class AudioFlacFileTests: XCTestCase {
    private struct Fixtures: Decodable { let schema: String; let vectors: [Vector] }
    private struct Vector: Decodable {
        let name: String; let dataBase64: String; let fileSize: UInt64
        let expected: Expected?; let error: String?
    }
    private struct Expected: Decodable {
        let sampleRate: UInt32; let channels: UInt16; let validBits: UInt8; let containerBits: UInt8
        let totalFrames: UInt64?; let waveChannelMask: UInt32; let hasExplicitChannelMask: Bool
        let firstFrameByteOffset: UInt64; let pcmMD5Hex: String?
        let minimumBlockFrames: UInt16; let maximumBlockFrames: UInt16
        let minimumFrameBytes: UInt32?; let maximumFrameBytes: UInt32?
    }
    private final class Trace: Sendable {
        let data: Data
        let reads = OSAllocatedUnfairLock(initialState: [(UInt64, Int)]())
        init(_ data: Data) { self.data = data }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count > 0, count <= AudioFlacFile.maximumReadBytes,
                  offset + UInt64(count) <= data.count else { throw TestReadError.outOfBounds }
            reads.withLock { $0.append((offset, count)) }
            // Retain nonzero Data slice indices: the parser must normalize its own small copies.
            return (Data([0xa5]) + data)[(Int(offset) + 1)..<(Int(offset) + 1 + count)]
        }
    }
    private enum TestReadError: Error { case outOfBounds, failed }

    private func fixtures() throws -> Fixtures {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "flac-metadata-v1-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
    }

    func testCommonRFCAndIndependentEncoderMetadataVectors() async throws {
        let fixture = try fixtures()
        XCTAssertEqual(fixture.schema, "flac-metadata-v1"); XCTAssertEqual(fixture.vectors.count, 93)
        for vector in fixture.vectors {
            let trace = Trace(try XCTUnwrap(Data(base64Encoded: vector.dataBase64)))
            do {
                let actual = try await AudioFlacFile.inspect(fileSize: vector.fileSize, read: trace.read)
                let expected = try XCTUnwrap(vector.expected, "Unexpected acceptance: \(vector.name)")
                XCTAssertNil(vector.error, vector.name)
                XCTAssertEqual(actual.decodedFormat.sampleRate, expected.sampleRate, vector.name)
                XCTAssertEqual(actual.decodedFormat.channels, expected.channels, vector.name)
                XCTAssertEqual(actual.decodedFormat.declaredValidBits, expected.validBits, vector.name)
                XCTAssertEqual(actual.decodedFormat.encoding.containerBits, expected.containerBits, vector.name)
                XCTAssertFalse(actual.decodedFormat.encoding.isFloatingPoint, vector.name)
                if expected.containerBits == 8 { XCTAssertEqual(actual.decodedFormat.encoding, .unsigned8, vector.name) }
                XCTAssertEqual(actual.decodedFormat.waveChannelMask, expected.waveChannelMask, vector.name)
                XCTAssertEqual(actual.hasExplicitChannelMask, expected.hasExplicitChannelMask, vector.name)
                XCTAssertEqual(actual.totalFrames, expected.totalFrames, vector.name)
                XCTAssertEqual(actual.pcmMD5Hex, expected.pcmMD5Hex, vector.name)
                XCTAssertEqual(actual.firstFrameByteOffset, expected.firstFrameByteOffset, vector.name)
                XCTAssertEqual(actual.minimumBlockFrames, expected.minimumBlockFrames, vector.name)
                XCTAssertEqual(actual.maximumBlockFrames, expected.maximumBlockFrames, vector.name)
                XCTAssertEqual(actual.minimumFrameBytes, expected.minimumFrameBytes, vector.name)
                XCTAssertEqual(actual.maximumFrameBytes, expected.maximumFrameBytes, vector.name)
                XCTAssertTrue(trace.reads.withLock { $0.allSatisfy { $0.0 + UInt64($0.1) <= actual.firstFrameByteOffset } }, vector.name)
            } catch let actual as AudioFlacMetadataError {
                XCTAssertEqual(String(describing: actual), vector.error, vector.name)
            }
        }
    }

    func testEveryRequiredHeaderTruncationFails() async throws {
        let data = try base()
        for count in 0...42 { await rejects(Data(data.prefix(count)), .truncated) }
    }

    func testShortAndOversizedReadsAreRejectedAndIoFailureIsPropagated() async throws {
        for (delta, expected) in [(-1, AudioFlacMetadataError.truncated), (1, .invalidReadLength)] {
            do {
                _ = try await AudioFlacFile.inspect(fileSize: 43) { _, count in Data(count: count + delta) }
                XCTFail("Invalid callback length accepted")
            } catch let failure as AudioFlacMetadataError { XCTAssertEqual(failure, expected) }
        }
        do {
            _ = try await AudioFlacFile.inspect(fileSize: 43) { _, _ in throw TestReadError.failed }
            XCTFail("I/O failure was replaced")
        } catch TestReadError.failed { }
    }

    func testOversizedSourceIsRejectedBeforeIo() async throws {
        do {
            _ = try await AudioFlacFile.inspect(fileSize: AudioFlacFile.maximumFileBytes + 1) { _, _ in
                throw TestReadError.outOfBounds
            }
            XCTFail("Oversized source accepted")
        } catch let failure as AudioFlacMetadataError { XCTAssertEqual(failure, .oversized) }
    }

    func testCancellationBeforeAndDuringReadIsNotTurnedIntoMetadata() async throws {
        let trace = Trace(try base())
        let task = Task { try await AudioFlacFile.inspect(fileSize: UInt64(trace.data.count), read: trace.read) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled inspector succeeded") }
        catch is CancellationError { XCTAssertTrue(trace.reads.withLock { $0.isEmpty }) }
        do {
            _ = try await AudioFlacFile.inspect(fileSize: 43) { _, _ in throw CancellationError() }
            XCTFail("Source cancellation was replaced")
        } catch is CancellationError { }
    }

    func testBlockCountAndCommentAllocationAreBoundedBeforePayloadRead() async throws {
        var header = Data(try base().prefix(42)); header[4] = 0
        let many = header + Data((0..<(4 * AudioFlacFile.maximumBlocks)).map { $0 % 4 == 0 ? 1 : 0 }) + Data([0xff])
        await rejects(many, .metadataLimit)
        let declared = AudioFlacFile.maximumCommentBytes + 1
        let prefix = header + Data([0x84, UInt8(truncatingIfNeeded: declared >> 16),
                                   UInt8(truncatingIfNeeded: declared >> 8), UInt8(truncatingIfNeeded: declared)])
        let trace = Trace(prefix)
        do {
            _ = try await AudioFlacFile.inspect(fileSize: UInt64(prefix.count + declared + 1), read: trace.read)
            XCTFail("Oversized comment accepted")
        } catch let failure as AudioFlacMetadataError { XCTAssertEqual(failure, .metadataLimit) }
    }

    func testIgnoredMetadataIsSkippedAndTotalBudgetIsEnforced() async throws {
        var changed = Data(try base().prefix(42)); changed[4] = 0
        let header = changed
        let reads = OSAllocatedUnfairLock(initialState: 0)
        do {
            _ = try await AudioFlacFile.inspect(fileSize: 100_000_000) { offset, count in
                reads.withLock { $0 += 1 }
                if offset < header.count { return header[Int(offset)..<(Int(offset) + count)] }
                guard (offset - 42) % (0x00ff_ffff + 4) == 0, count == 4 else { throw TestReadError.outOfBounds }
                return Data([1, 0xff, 0xff, 0xff])
            }
            XCTFail("Metadata budget was ignored")
        } catch let failure as AudioFlacMetadataError { XCTAssertEqual(failure, .metadataLimit) }
        XCTAssertEqual(reads.withLock { $0 }, 7)
    }

    private func base() throws -> Data {
        let vector = try XCTUnwrap(fixtures().vectors.first { $0.name == "precision-24-channels-2" })
        return try XCTUnwrap(Data(base64Encoded: vector.dataBase64))
    }
    private func rejects(_ bytes: Data, _ expected: AudioFlacMetadataError) async {
        do {
            _ = try await AudioFlacFile.inspect(fileSize: UInt64(bytes.count), read: Trace(bytes).read)
            XCTFail("Invalid metadata accepted")
        } catch let failure as AudioFlacMetadataError { XCTAssertEqual(failure, expected) }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
