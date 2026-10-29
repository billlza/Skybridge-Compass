#if os(macOS) || os(iOS)
import CryptoKit
import Foundation
import XCTest
import os
import SkyBridgeAudioFile
import SkyBridgeProtocolCore

/// Actual pinned native decoder, Swift callback bridge and held-descriptor reader. No audio device.
@MainActor
final class AudioFlacPCMDecoderTests: XCTestCase {
    private enum Failure: Error, Equatable { case revoked, missingFixture, unexpectedStep }
    private struct Fixture: Sendable {
        let directory: URL
        let file: URL
        let reader: PreparedOutboundFileReadSession
        let metadata: AudioFlacMetadata
    }

    func testGoldenIntegerPrecisionAndChannelsThroughRealReader() async throws {
        let generated = [4, 8, 12, 16, 20, 24, 32].flatMap { bits in
            [1, 2, 6, 8].map { "golden-\(bits)-\($0)" }
        }
        for name in generated + ["three-valid-frames", "reference-true32-stereo", "reference-s24-48000-6ch"] {
            let source = try await fixture(name)
            let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
            let (pcm, receipt) = try await decode(decoder)
            XCTAssertEqual(pcm, try resource(name, extension: "pcm"), name)
            XCTAssertEqual(receipt.sourceFrames, source.metadata.totalFrames, name)
            XCTAssertEqual(receipt.encodedBytes, UInt64(source.reader.metadata.fileSize), name)
            XCTAssertTrue(receipt.md5Available, name); XCTAssertTrue(receipt.md5Verified, name)
            guard case .complete(let repeated) = try await decoder.next(requireAuthorization: {}) else {
                throw Failure.unexpectedStep
            }
            XCTAssertEqual(receipt, repeated)
            decoder.close(); try await clean(source)
        }
    }

    func testCancellationInFinalNativePublicationCallbackReturnsNoFrame() async throws {
        let source = try await fixture("three-valid-frames")
        let baseline = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        let observed = OSAllocatedUnfairLock(initialState: 0)
        _ = try await baseline.next(requireAuthorization: { observed.withLock { $0 += 1 } })
        let finalCall = observed.withLock { $0 }; baseline.close()
        let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            try await decoder.next(requireAuthorization: {
                if calls.withLock({ $0 += 1; return $0 }) == finalCall { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await task.value; XCTFail("Cancelled native publication returned a frame") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.withLock { $0 }, finalCall)
        decoder.close(); try await clean(source)
    }

    func testAbsentMD5RemainsExplicitlyUnavailable() async throws {
        let source = try await fixture("md5-explicitly-unavailable")
        let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        let (pcm, receipt) = try await decode(decoder)
        XCTAssertEqual(pcm, try resource("md5-explicitly-unavailable", extension: "pcm"))
        XCTAssertFalse(receipt.md5Available); XCTAssertFalse(receipt.md5Verified)
        decoder.close(); try await clean(source)
    }

    func testCRCErrorMissingFrameAndMD5FailureCannotComplete() async throws {
        for (name, expected) in [
            ("frame-crc-mismatch", AudioFlacDecodeError.native(status: 105, codecError: 2)),
            ("missing-silent-middle-must-not-recover", .native(status: 105, codecError: 6)),
            ("valid-crc-wrong-pcm-md5", .native(status: 113, codecError: -1))
        ] {
            let source = try await fixture(name)
            let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
            do { _ = try await decode(decoder); XCTFail("Corrupt file completed: \(name)") }
            catch { XCTAssertEqual(error as? AudioFlacDecodeError, expected, name) }
            // A failed owner never re-enters the source or converts an invalid suffix to completion.
            try await source.reader.close()
            do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Failure was not sticky") }
            catch { XCTAssertEqual(error as? AudioFlacDecodeError, expected, name) }
            decoder.close(); try await clean(source)
        }
    }

    func testUnknownSampleCountIsNotAdmittedByFiniteDecoder() async throws {
        let source = try await fixture("unknown-length-not-admitted-by-finite-decoder")
        XCTAssertNil(source.metadata.totalFrames)
        XCTAssertThrowsError(try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)) { error in
            XCTAssertEqual(error as? AudioFlacDecodeError, .invalidMetadata)
        }
        try await clean(source)
    }

    func testDecoderCloseDoesNotCloseOrReopenItsCallerReader() async throws {
        let source = try await fixture("three-valid-frames")
        let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        decoder.close(); decoder.close()
        do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Closed decoder returned PCM") }
        catch { XCTAssertEqual(error as? AudioFlacDecodeError, .closed) }
        let bytes = try await source.reader.read(offset: 0, length: 4)
        XCTAssertEqual(bytes, Data("fLaC".utf8))
        let replacement = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        try await source.reader.close()
        do { _ = try await replacement.next(requireAuthorization: {}); XCTFail("Decoder reopened a closed reader") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
        replacement.close(); try await clean(source)
    }

    func testClosingReaderRevokesAlreadyBufferedNativeFrames() async throws {
        let source = try await fixture("three-valid-frames")
        let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        defer { decoder.close() }
        guard case .frame = try await decoder.next(requireAuthorization: {}) else {
            throw Failure.unexpectedStep
        }
        try await source.reader.close()
        do {
            _ = try await decoder.next(requireAuthorization: {})
            XCTFail("A closed committed reader still returned a native cached frame or completion")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
        // Closing the source is terminal for this decoder, even if its native buffer remains full.
        do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Closed source resumed") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
        try await clean(source)
    }

    func testCloseFromAuthorizationCallbackDoesNotReenterNativeLock() async throws {
        let file = try directory().appendingPathComponent("three-valid-frames.flac")
        let size = try Data(contentsOf: file).count
        let reader = try await PreparedOutboundFileReadSession.prepare(url: file,
            maximumSize: Int64(size), sourcePolicy: .regularFile)
        addTeardownBlock { try await reader.close() }
        let metadata = try await AudioFlacFile.inspect(fileSize: UInt64(size)) { offset, count in
            try await reader.read(offset: offset, length: count)
        }
        let decoder = try AudioFlacPCMDecoder(reader: reader, metadata: metadata)
        defer { decoder.close() }
        let once = OSAllocatedUnfairLock(initialState: false)
        do {
            _ = try await decoder.next(requireAuthorization: {
                let shouldClose = once.withLock { state in let first = !state; state = true; return first }
                if shouldClose { decoder.close() }
            })
            XCTFail("Decoder closed by its authorization callback returned PCM")
        } catch { XCTAssertEqual(error as? AudioFlacDecodeError, .closed) }
        do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Closed native owner resumed") }
        catch { XCTAssertEqual(error as? AudioFlacDecodeError, .closed) }
        try await reader.close()
    }

    func testUncachedFileMutationPropagatesOriginalCommitmentFailure() async throws {
        let source = try await fixture("reference-true32-stereo")
        let writer = try FileHandle(forWritingTo: source.file)
        try writer.seek(toOffset: 300_000)
        try writer.write(contentsOf: Data(repeating: 0x77, count: 100))
        try writer.close()
        let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        do { _ = try await decode(decoder); XCTFail("Mutated committed file decoded") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .contentChanged) }
        try await source.reader.close()
        do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Failed source was read again") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .contentChanged) }
        decoder.close(); try await clean(source)
    }

    func testAuthorizationRevocationInsideNativeCallIsPreservedAndSticky() async throws {
        let source = try await fixture("three-valid-frames")
        let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let authorize: @Sendable () throws -> Void = {
            let value = calls.withLock { $0 += 1; return $0 }
            if value == 5 { throw Failure.revoked }
        }
        do { _ = try await decoder.next(requireAuthorization: authorize); XCTFail("Revoked operation returned PCM") }
        catch { XCTAssertEqual(error as? Failure, .revoked) }
        XCTAssertEqual(calls.withLock { $0 }, 5)
        do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Revoked decoder resumed") }
        catch { XCTAssertEqual(error as? Failure, .revoked) }
        decoder.close(); try await clean(source)
    }

    func testTaskCancellationBeforeAndDuringNativeCallReturnsNoFrame() async throws {
        for duringCall in [false, true] {
            let source = try await fixture("three-valid-frames")
            let decoder = try AudioFlacPCMDecoder(reader: source.reader, metadata: source.metadata)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let operation = Task {
                if !duringCall { withUnsafeCurrentTask { $0?.cancel() } }
                return try await decoder.next(requireAuthorization: {
                    let value = calls.withLock { $0 += 1; return $0 }
                    if duringCall && value == 5 { withUnsafeCurrentTask { $0?.cancel() } }
                })
            }
            do { _ = try await operation.value; XCTFail("Cancelled decode returned a frame") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Cancelled owner resumed") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            decoder.close(); try await clean(source)
        }
    }

    func testFixtureHashesMatchFrozenIndependentInputs() throws {
        struct Manifest: Decodable {
            struct Entry: Decodable { let path: String; let sha256: String; let bytes: Int }
            let files: [Entry]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: resource("manifest", extension: "json"))
        XCTAssertEqual(manifest.files.count, 68)
        for entry in manifest.files {
            let url = try directory().appendingPathComponent(entry.path)
            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.count, entry.bytes, entry.path)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry.sha256, entry.path)
        }
    }

    private func decode(_ decoder: AudioFlacPCMDecoder) async throws -> (Data, AudioFlacDecodeReceipt) {
        var bytes = Data(), frames: UInt64 = 0
        // Every fixture has at most 65,537 frames. This is a test collector, never a product cache.
        for _ in 0..<70_000 {
            switch try await decoder.next(requireAuthorization: {}) {
            case let .frame(index, count, pcm):
                XCTAssertEqual(index, frames)
                XCTAssertEqual(pcm.count, Int(count) * Int(decoder.metadata.decodedFormat.bytesPerFrame))
                bytes.append(pcm); frames += UInt64(count)
            case .complete(let receipt): return (bytes, receipt)
            }
        }
        throw Failure.unexpectedStep
    }

    private func directory() throws -> URL {
        guard let url = Bundle.module.url(forResource: "flac-decoder-v1", withExtension: nil) else { throw Failure.missingFixture }
        return url
    }
    private func resource(_ name: String, extension suffix: String) throws -> Data {
        try Data(contentsOf: directory().appendingPathComponent(name + "." + suffix))
    }
    private func fixture(_ name: String) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("audio-flac-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("source.flac"), data = try resource(name, extension: "flac")
        try data.write(to: file, options: .withoutOverwriting)
        let reader = try await PreparedOutboundFileReadSession.prepare(url: file, maximumSize: Int64(data.count),
            sourcePolicy: .regularFile, expectedSHA256: Data(SHA256.hash(data: data)))
        addTeardownBlock {
            try await reader.close()
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        let metadata = try await AudioFlacFile.inspect(fileSize: UInt64(data.count)) { offset, length in
            try await reader.read(offset: offset, length: length)
        }
        return .init(directory: directory, file: file, reader: reader, metadata: metadata)
    }
    private func clean(_ source: Fixture) async throws {
        try await source.reader.close()
        try FileManager.default.removeItem(at: source.directory)
    }
}
#endif
