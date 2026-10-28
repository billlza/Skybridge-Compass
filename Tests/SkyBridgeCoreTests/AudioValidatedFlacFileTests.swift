#if os(macOS) || os(iOS)
import CryptoKit
import Foundation
import XCTest
import os
import SkyBridgeAudioFile
import SkyBridgeProtocolCore

@MainActor
final class AudioValidatedFlacFileTests: XCTestCase {
    private enum Failure: Error, Equatable { case revoked }

    func testCompleteValidationThenSplitAndJoinedReadsPreserveGoldenPCM() async throws {
        for name in ["golden-4-8", "golden-12-6", "golden-20-2", "golden-32-8",
                     "three-valid-frames", "reference-true32-stereo", "reference-s24-48000-6ch"] {
            let source = try await AudioFlacTestFixture.prepare(name, in: self)
            let file = try await AudioValidatedFlacFile.validate(reader: source.reader,
                                                               requireAuthorization: {})
            let reader = try AudioFlacPCMReadSession(file: file)
            var actual = Data(), position: UInt64 = 0, turn = 0
            while position < file.receipt.sourceFrames {
                let limit = AudioFlacPCMReadSession.maximumReadBytes / Int(source.metadata.decodedFormat.bytesPerFrame)
                let preferred = [1, 7, 19, limit][turn % 4]
                let count = Int(min(UInt64(preferred), file.receipt.sourceFrames - position))
                let bytes = try await reader.read(frameOffset: position, frames: count, requireAuthorization: {})
                XCTAssertEqual(bytes.count, count * Int(source.metadata.decodedFormat.bytesPerFrame))
                XCTAssertLessThanOrEqual(bytes.count, 65_536)
                actual.append(bytes); position += UInt64(count); turn += 1
            }
            try await reader.finish(requireAuthorization: {})
            XCTAssertEqual(actual, try AudioFlacTestFixture.resource(name, extension: "pcm"), name)
            await reader.close()
            let signature = try await source.reader.read(offset: 0, length: 4)
            XCTAssertEqual(signature, Data("fLaC".utf8), "Codec cleanup must leave file cleanup to its owner")
        }
    }

    func testMalformedFilesNeverProduceAValidationWitness() async throws {
        for name in ["frame-crc-mismatch", "missing-silent-middle-must-not-recover", "valid-crc-wrong-pcm-md5"] {
            let source = try await AudioFlacTestFixture.prepare(name, in: self)
            do {
                _ = try await AudioValidatedFlacFile.validate(reader: source.reader,
                                                             requireAuthorization: {})
                XCTFail("Corrupt file acquired a playback witness: \(name)")
            } catch { XCTAssertNotNil(error as? AudioFlacDecodeError, "\(error)") }
            let signature = try await source.reader.read(offset: 0, length: 4)
            XCTAssertEqual(signature, Data("fLaC".utf8))
        }
    }

    func testWitnessDerivesExplicitLayoutFromItsOwnCommittedFile() async throws {
        let original = try AudioFlacTestFixture.resource("three-valid-frames", extension: "flac")
        func little(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        for mask in [0, 3] {
            let field = Data("WAVEFORMATEXTENSIBLE_CHANNEL_MASK=0x\(mask)".utf8)
            let comment = little(0) + little(1) + little(field.count) + field
            var file = Data(original.prefix(42)); file[4] = 0 // STREAMINFO followed by one last Vorbis-comment block.
            file.append(contentsOf: [0x84, 0, 0, UInt8(comment.count)])
            file.append(comment); file.append(original.dropFirst(42))
            let source = try await AudioFlacTestFixture.prepare(data: file, in: self)
            let validated = try await AudioValidatedFlacFile.validate(reader: source.reader, requireAuthorization: {})
            XCTAssertTrue(validated.metadata.hasExplicitChannelMask)
            XCTAssertEqual(validated.metadata.decodedFormat.waveChannelMask, UInt32(mask))
            XCTAssertEqual(validated.receipt.encodedBytes, UInt64(file.count))
            XCTAssertEqual(validated.reader.metadata.contentSHA256, Data(SHA256.hash(data: file)))
        }
    }

    func testUnknownLengthAndExcessiveDeclaredDurationAreRejected() async throws {
        let unknown = try await AudioFlacTestFixture.prepare("unknown-length-not-admitted-by-finite-decoder", in: self)
        do {
            _ = try await AudioValidatedFlacFile.validate(reader: unknown.reader,
                                                         requireAuthorization: {})
            XCTFail("Unknown finite duration was accepted")
        } catch { XCTAssertEqual(error as? AudioFlacValidationError, .unsupportedDuration) }
        var data = try AudioFlacTestFixture.resource("three-valid-frames", extension: "flac")
        let packed = data[18..<26].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let frames = 44_100 * (AudioValidatedFlacFile.maximumSourceSeconds + 1)
        let changed = (packed & ~((1 << 36) - 1)) | frames
        for index in 0..<8 { data[18 + index] = UInt8(truncatingIfNeeded: changed >> ((7 - index) * 8)) }
        let long = try await AudioFlacTestFixture.prepare(data: data, in: self)
        do {
            _ = try await AudioValidatedFlacFile.validate(reader: long.reader,
                                                         requireAuthorization: {})
            XCTFail("Unbounded playback duration was accepted")
        } catch { XCTAssertEqual(error as? AudioFlacValidationError, .unsupportedDuration) }
    }

    func testValidationHasABoundedMonotonicDeadline() async throws {
        let source = try await AudioFlacTestFixture.prepare("three-valid-frames", in: self)
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        do {
            _ = try await AudioValidatedFlacFile.validate(reader: source.reader,
                requireAuthorization: {}, maximumTime: .milliseconds(50), now: {
                    clock.withLock { value in defer { value = value.advanced(by: .milliseconds(10)) }; return value }
                })
            XCTFail("Validation deadline was ignored")
        } catch { XCTAssertEqual(error as? AudioFlacValidationError, .timedOut) }
        for limit in [Duration.zero, .seconds(181)] {
            do {
                _ = try await AudioValidatedFlacFile.validate(reader: source.reader,
                    requireAuthorization: {}, maximumTime: limit)
                XCTFail("Invalid validation limit admitted")
            } catch { XCTAssertEqual(error as? AudioFlacValidationError, .invalidLimit) }
        }
    }

    func testCancellationInFinalValidationCallbackCannotPublishAWitness() async throws {
        let source = try await AudioFlacTestFixture.prepare("three-valid-frames", in: self)
        let observed = OSAllocatedUnfairLock(initialState: 0)
        _ = try await AudioValidatedFlacFile.validate(reader: source.reader,
            requireAuthorization: { observed.withLock { $0 += 1 } })
        let finalCall = observed.withLock { $0 }, calls = OSAllocatedUnfairLock(initialState: 0)
        XCTAssertGreaterThan(finalCall, 1)
        let task = Task {
            try await AudioValidatedFlacFile.validate(reader: source.reader, requireAuthorization: {
                if calls.withLock({ $0 += 1; return $0 }) == finalCall { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; XCTFail("Cancelled validation published a witness") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.withLock { $0 }, finalCall)
    }

    func testCancellationInFinalCachedReadCallbackReturnsNoPCMAndIsSticky() async throws {
        let source = try await AudioFlacTestFixture.prepare("three-valid-frames", in: self)
        let file = try await AudioValidatedFlacFile.validate(reader: source.reader, requireAuthorization: {})
        let baseline = try AudioFlacPCMReadSession(file: file), observed = OSAllocatedUnfairLock(initialState: 0)
        _ = try await baseline.read(frameOffset: 0, frames: 1, requireAuthorization: {})
        _ = try await baseline.read(frameOffset: 1, frames: 1, requireAuthorization: { observed.withLock { $0 += 1 } })
        let finalCall = observed.withLock { $0 }; await baseline.close()
        XCTAssertGreaterThan(finalCall, 1)
        let reader = try AudioFlacPCMReadSession(file: file), calls = OSAllocatedUnfairLock(initialState: 0)
        _ = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {})
        let task = Task {
            try await reader.read(frameOffset: 1, frames: 1) {
                if calls.withLock({ $0 += 1; return $0 }) == finalCall { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled cached read returned PCM") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.withLock { $0 }, finalCall)
        do { _ = try await reader.read(frameOffset: 1, frames: 1, requireAuthorization: {}); XCTFail("Cancelled read resumed") }
        catch { XCTAssertTrue(error is CancellationError) }
        await reader.close()
    }

    func testPlaybackCannotReadMutatedFileThroughEarlierWitness() async throws {
        let source = try await AudioFlacTestFixture.prepare("reference-true32-stereo", in: self)
        let file = try await AudioValidatedFlacFile.validate(reader: source.reader,
                                                           requireAuthorization: {})
        let writer = try FileHandle(forWritingTo: source.url)
        try writer.seek(toOffset: 300_000); try writer.write(contentsOf: Data(repeating: 0x77, count: 100)); try writer.close()
        let reader = try AudioFlacPCMReadSession(file: file)
        var position: UInt64 = 0
        do {
            while position < file.receipt.sourceFrames {
                let frames = Int(min(8_192, file.receipt.sourceFrames - position))
                _ = try await reader.read(frameOffset: position, frames: frames, requireAuthorization: {})
                position += UInt64(frames)
            }
            XCTFail("Changed committed block was returned")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .contentChanged) }
        await reader.close()
    }

    func testClosingCommittedReaderRetiresAlreadyDecodedPendingSamples() async throws {
        let source = try await AudioFlacTestFixture.prepare("three-valid-frames", in: self)
        let file = try await AudioValidatedFlacFile.validate(reader: source.reader, requireAuthorization: {})
        let reader = try AudioFlacPCMReadSession(file: file)
        _ = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {})
        try await source.reader.close()
        for _ in 0..<2 {
            do {
                _ = try await reader.read(frameOffset: 1, frames: 1, requireAuthorization: {})
                XCTFail("A closed committed file still returned cached PCM")
            } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
        }
        await reader.close()
    }

    func testChangedFileIdentityRetiresAlreadyDecodedPendingSamples() async throws {
        let source = try await AudioFlacTestFixture.prepare("three-valid-frames", in: self)
        let file = try await AudioValidatedFlacFile.validate(reader: source.reader, requireAuthorization: {})
        let reader = try AudioFlacPCMReadSession(file: file)
        _ = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {})
        let writer = try FileHandle(forWritingTo: source.url)
        try writer.truncate(atOffset: 0)
        try writer.close()
        do {
            _ = try await reader.read(frameOffset: 1, frames: 1, requireAuthorization: {})
            XCTFail("A file whose size changed still returned cached PCM")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .sourceChanged) }
        await reader.close()
    }

    func testRevocationAndCloseApplyToAlreadyDecodedPendingSamples() async throws {
        let source = try await AudioFlacTestFixture.prepare("three-valid-frames", in: self)
        let file = try await AudioValidatedFlacFile.validate(reader: source.reader,
                                                           requireAuthorization: {})
        for close in [false, true] {
            let reader = try AudioFlacPCMReadSession(file: file)
            _ = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {})
            if close { await reader.close() }
            do {
                _ = try await reader.read(frameOffset: 1, frames: 1,
                                          requireAuthorization: { if !close { throw Failure.revoked } })
                XCTFail("Retired pending PCM escaped")
            } catch {
                if close { XCTAssertEqual(error as? AudioFlacDecodeError, .closed) }
                else { XCTAssertEqual(error as? Failure, .revoked) }
            }
            if !close {
                do {
                    _ = try await reader.read(frameOffset: 1, frames: 1, requireAuthorization: {})
                    XCTFail("Revoked pending read resumed")
                } catch { XCTAssertEqual(error as? Failure, .revoked) }
            }
            await reader.close()
        }
    }
}

struct AudioFlacTestFixture: Sendable {
    let url: URL
    let reader: PreparedOutboundFileReadSession
    let metadata: AudioFlacMetadata

    static func resource(_ name: String, extension suffix: String) throws -> Data {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "flac-decoder-v1", withExtension: nil))
        return try Data(contentsOf: directory.appendingPathComponent(name + "." + suffix))
    }

    @MainActor static func prepare(_ name: String, in test: XCTestCase) async throws -> Self {
        try await prepare(data: resource(name, extension: "flac"), in: test)
    }
    @MainActor static func prepare(data: Data, in test: XCTestCase) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("audio-validated-flac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        test.addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.flac")
        try data.write(to: url, options: .withoutOverwriting)
        let reader = try await PreparedOutboundFileReadSession.prepare(url: url, maximumSize: Int64(data.count),
            sourcePolicy: .regularFile, expectedSHA256: Data(SHA256.hash(data: data)))
        test.addTeardownBlock { try await reader.close() }
        let metadata = try await AudioFlacFile.inspect(fileSize: UInt64(data.count)) { offset, length in
            try await reader.read(offset: offset, length: length)
        }
        return .init(url: url, reader: reader, metadata: metadata)
    }
}
#endif
