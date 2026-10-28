import XCTest
import Foundation
import CryptoKit
import Darwin
import os
import enum SkyBridgeProtocolCore.PreparedOutboundFileReadError
import enum SkyBridgeProtocolCore.AudioWavePCMFileError
import enum SkyBridgeProtocolCore.AudioAlacFileError
import enum SkyBridgeProtocolCore.AudioStreamingWire
import struct SkyBridgeProtocolCore.AudioStreamingPCMFormat
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
@MainActor
final class IOSPreparedAudioFileTests: XCTestCase {
    private let blockSize = 256 * 1024

    func testALACHoldsOriginalContainerBytesAndExactPrecisionWithoutDecoding() async throws {
        let formats: [(Int, AudioStreamingPCMFormat.Encoding)] =
            [(16, .signed16), (20, .signed24), (24, .signed24), (32, .signed32)]
        for (bits, encoding) in formats {
            let bytes = try IOSAudioALACFixture.data(bits: bits)
            let fixture = try makeFixture(bytes); defer { remove(fixture) }
            let scopes = PreparedAudioScopeCounter(), owner = try makeOwner(fixture, scopes: scopes)
            do {
                let content = try await owner.prepare()
                guard case .alac = content.source else { XCTFail("ALAC was misclassified"); try await owner.close(); continue }
                XCTAssertNil(content.wave); XCTAssertFalse(content.isFLAC)
                XCTAssertTrue(content.requiresReceiverValidation)
                XCTAssertEqual(content.requiredReceiverCapability, AudioStreamingWire.alacFileReceiveCapability)
                XCTAssertEqual(content.mimeType, "audio/mp4")
                XCTAssertEqual(content.frameCount, 4_817)
                XCTAssertEqual(content.format.sampleRate, 48_000); XCTAssertEqual(content.format.channels, 2)
                XCTAssertEqual(content.format.encoding, encoding); XCTAssertEqual(content.format.declaredValidBits, UInt8(bits))
                XCTAssertEqual(content.format.waveChannelMask, 3)
                let actual = try await owner.read(offset: 0, length: bytes.count)
                XCTAssertEqual(actual, bytes); XCTAssertEqual(content.digest, Data(SHA256.hash(data: bytes)))
                try await owner.close()
                XCTAssertEqual(scopes.starts, 1); XCTAssertEqual(scopes.stops, 1)
                XCTAssertEqual(scopes.descriptorsAtStop, [0])
            } catch { try await owner.close(); throw error }
        }
    }

    func testFLACIsInspectedAndHeldWithoutDecodingOrChangingSourceBytes() async throws {
        for unknown in [false, true] {
            let bytes = try IOSAudioFLACFixture.data(unknownFrames: unknown)
            if !unknown {
                XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), IOSAudioFLACFixture.sha256)
            }
            let fixture = try makeFixture(bytes); defer { remove(fixture) }
            let scopes = PreparedAudioScopeCounter(), owner = try makeOwner(fixture, scopes: scopes)
            let content = try await owner.prepare()
            XCTAssertTrue(content.isFLAC); XCTAssertNil(content.wave)
            XCTAssertEqual(content.format.sampleRate, 44_100); XCTAssertEqual(content.format.channels, 2)
            XCTAssertEqual(content.format.encoding, .signed32); XCTAssertEqual(content.format.declaredValidBits, 32)
            XCTAssertEqual(content.format.waveChannelMask, 3)
            XCTAssertEqual(content.frameCount, unknown ? nil : 31)
            let actual = try await owner.read(offset: 0, length: bytes.count)
            XCTAssertEqual(actual, bytes)
            XCTAssertEqual(content.digest, Data(SHA256.hash(data: bytes)))
            try await owner.close()
            XCTAssertEqual(scopes.starts, 1); XCTAssertEqual(scopes.stops, 1)
            XCTAssertEqual(scopes.descriptorsAtStop, [0])
        }
    }

    func testPreparedContentFixesRawTransferIDWholeHashLengthAndDeclaredFormat() async throws {
        let pcm = Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        let bytes = wave(bits: 32, validBits: 24, mask: 0x80000000, pcm: pcm)
        let fixture = try makeFixture(bytes); defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter()
        let rawID = "abcdefab-1234-5678-9abc-abcdefabcdef"
        let owner = try makeOwner(fixture, scopes: scopes, transferID: rawID)
        XCTAssertEqual(scopes.starts, 0)
        let content = try await owner.prepare()
        XCTAssertEqual(content.transferID, rawID); XCTAssertEqual(content.fileName, "source.wav")
        XCTAssertEqual(content.length, Int64(bytes.count)); XCTAssertEqual(content.digest, Data(SHA256.hash(data: bytes)))
        XCTAssertEqual((try XCTUnwrap(content.wave)).format.encoding, .signed32)
        XCTAssertEqual((try XCTUnwrap(content.wave)).format.declaredValidBits, 24)
        XCTAssertEqual((try XCTUnwrap(content.wave)).format.waveChannelMask, 0x80000000)
        XCTAssertEqual((try XCTUnwrap(content.wave)).pcmByteOffset, 68); XCTAssertEqual((try XCTUnwrap(content.wave)).pcmByteCount, UInt64(pcm.count))
        let returned = try await owner.read(offset: (try XCTUnwrap(content.wave)).pcmByteOffset, length: pcm.count)
        XCTAssertEqual(returned, pcm)
        let cachedProgress = OSAllocatedUnfairLock(initialState: [(Int64, Int64)]())
        let again = try await owner.prepare(onHashProgress: { completed, total in
            cachedProgress.withLock { $0.append((completed, total)) }
        })
        XCTAssertEqual(cachedProgress.withLock { $0.map(\.0) }, [content.length])
        XCTAssertEqual(cachedProgress.withLock { $0.map(\.1) }, [content.length])
        XCTAssertTrue(content.reader === again.reader); XCTAssertEqual(again.digest, content.digest)
        XCTAssertEqual(scopes.starts, 1); XCTAssertEqual(scopes.stops, 0)
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 1)
        try await owner.close()
        XCTAssertEqual(scopes.stops, 1); XCTAssertEqual(scopes.descriptorsAtStop, [0])
    }

    func testCachedHashObserverCannotReturnAReaderClosedDuringItsCallback() async throws {
        let fixture = try makeFixture(wave(pcm: Data(repeating: 0, count: 16)))
        defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(), owner = try makeOwner(fixture, scopes: scopes)
        _ = try await owner.prepare()
        do {
            _ = try await owner.prepare(onHashProgress: { _, _ in try await owner.close() })
            XCTFail("Cached preparation returned an already closed reader")
        } catch { XCTAssertEqual(error as? IOSPreparedAudioFileError, .closed) }
        XCTAssertEqual(scopes.starts, 1); XCTAssertEqual(scopes.stops, 1)
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 0)
    }

    func testInteger64AndIEEEPayloadsAndUnknownLegacyLayoutArePreserved() async throws {
        let cases: [(UInt16, UInt16, UInt32?, Data, AudioStreamingPCMFormat.Encoding)] = [
            (1, 64, 3, Data(repeating: 0xa5, count: 16), .signed64),
            (3, 32, 0, Data([0, 0, 0, 0x80, 0x45, 0x23, 0xc1, 0x7f]), .float32),
            (3, 64, 3, Data([0x45, 0x23, 1, 0, 0, 0, 0xf8, 0x7f, 0, 0, 0, 0, 0, 0, 0, 0x80]), .float64),
            (1, 16, nil, Data([0x12, 0x34, 0x56, 0x78]), .signed16)
        ]
        for (tag, bits, mask, pcm, encoding) in cases {
            let fixture = try makeFixture(wave(tag: tag, bits: bits, mask: mask, pcm: pcm)); defer { remove(fixture) }
            let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
            let content = try await owner.prepare()
            XCTAssertEqual((try XCTUnwrap(content.wave)).format.encoding, encoding)
            XCTAssertEqual((try XCTUnwrap(content.wave)).format.declaredValidBits, UInt8(bits))
            XCTAssertEqual((try XCTUnwrap(content.wave)).format.waveChannelMask, mask)
            let actual = try await owner.read(offset: (try XCTUnwrap(content.wave)).pcmByteOffset, length: pcm.count)
            XCTAssertEqual(actual, pcm, "Preparation must not normalize IEEE NaNs, negative zero or integer low bits")
            try await owner.close()
            XCTAssertEqual(scopes.descriptorsAtStop, [0])
        }
    }

    func testHeldDescriptorDoesNotFollowReplacementPathIntoAnUncachedBlock() async throws {
        let originalPCM = Data(repeating: 0x11, count: blockSize + 64)
        let fixture = try makeFixture(wave(pcm: originalPCM)); defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        let content = try await owner.prepare()
        let originalPath = fixture.directory.appendingPathComponent("selected-original.wav")
        try FileManager.default.moveItem(at: fixture.file, to: originalPath)
        try wave(pcm: Data(repeating: 0x22, count: originalPCM.count)).write(to: fixture.file, options: .withoutOverwriting)
        let actual = try await owner.read(offset: UInt64(blockSize), length: 8)
        XCTAssertEqual(actual, Data(repeating: 0x11, count: 8))
        XCTAssertEqual(content.digest, Data(SHA256.hash(data: wave(pcm: originalPCM))))
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: originalPath), 1)
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 0)
        try await owner.close()
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: originalPath), 0)
        XCTAssertEqual(scopes.stops, 1)
    }

    func testSameSizeUncachedContentRewriteReturnsNoModifiedBytes() async throws {
        let fixture = try makeFixture(wave(pcm: Data(repeating: 0x11, count: blockSize + 64)))
        defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        _ = try await owner.prepare()
        try rewrite(fixture.file, offset: off_t(blockSize), bytes: Data(repeating: 0x22, count: 8))
        var returned: Data?
        do { returned = try await owner.read(offset: UInt64(blockSize), length: 8); XCTFail("Changed bytes escaped") }
        catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .contentChanged) }
        XCTAssertNil(returned)
        try await owner.close(); XCTAssertEqual(scopes.descriptorsAtStop, [0])
    }

    func testAlreadyVerifiedCachedBlockReturnsOriginalCopyAfterRewrite() async throws {
        let pcm = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let fixture = try makeFixture(wave(pcm: pcm)); defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        let content = try await owner.prepare()
        try rewrite(fixture.file, offset: off_t((try XCTUnwrap(content.wave)).pcmByteOffset), bytes: Data(repeating: 0xee, count: pcm.count))
        var actual = try await owner.read(offset: (try XCTUnwrap(content.wave)).pcmByteOffset, length: pcm.count)
        XCTAssertEqual(actual, pcm)
        actual[0] = 0xff
        let repeated = try await owner.read(offset: (try XCTUnwrap(content.wave)).pcmByteOffset, length: pcm.count)
        XCTAssertEqual(repeated, pcm, "A caller mutated the committed block cache")
        try await owner.close()
    }

    func testCancelledPreparationAndCloseWaitForActualHeldDescriptorWork() async throws {
        let fixture = try makeFixture(wave(pcm: Data(repeating: 0x11, count: blockSize + 64)))
        defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        let barrier = PreparedAudioPreparationBarrier()
        let preparing = Task { try await owner.prepare(validateLifetime: { await barrier.checkpoint() }) }
        do {
            try await waitUntil { await barrier.isPaused }
            XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 1)
            preparing.cancel()
            let closed = PreparedAudioCompletionFlag()
            let closing = Task { try await owner.close(); await closed.mark() }
            try await waitUntil {
                do { _ = try await owner.preparedContent(); return false }
                catch { return (error as? IOSPreparedAudioFileError) == .closed }
            }
            let endedEarly = await closed.value
            XCTAssertFalse(endedEarly); XCTAssertEqual(scopes.stops, 0)
            XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 1)
            await barrier.release()
            do { _ = try await preparing.value; XCTFail("Canceled preparation succeeded") }
            catch { XCTAssertTrue(error is CancellationError, "Unexpected preparation error: \(error)") }
            try await closing.value
            XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 0)
            XCTAssertEqual(scopes.starts, 1); XCTAssertEqual(scopes.stops, 1)
            XCTAssertEqual(scopes.descriptorsAtStop, [0])
        } catch {
            let primary = error
            preparing.cancel(); await barrier.release()
            _ = await preparing.result
            do { try await owner.close() }
            catch { throw PreparedAudioTestCleanupFailure(primary: primary, cleanup: error, owner: owner) }
            throw primary
        }
    }

    func testConcurrentPreparationCannotAcquireAnotherDescriptorOrSendingClaim() async throws {
        let fixture = try makeFixture(wave(pcm: Data(repeating: 0x11, count: blockSize + 64)))
        defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        let barrier = PreparedAudioPreparationBarrier()
        let preparing = Task { try await owner.prepare(validateLifetime: { await barrier.checkpoint() }) }
        do {
            try await waitUntil { await barrier.isPaused }
            await assertOwnerError(.busy) { _ = try await owner.prepare() }
            await assertOwnerError(.notPrepared) { _ = try await owner.claimForSending() }
            await assertOwnerError(.notPrepared) { _ = try await owner.read(offset: 0, length: 1) }
            XCTAssertEqual(scopes.starts, 1); XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 1)
            await barrier.release(); _ = try await preparing.value
            try await owner.close()
            XCTAssertEqual(scopes.descriptorsAtStop, [0])
        } catch {
            let primary = error
            preparing.cancel(); await barrier.release()
            _ = await preparing.result
            do { try await owner.close() }
            catch { throw PreparedAudioTestCleanupFailure(primary: primary, cleanup: error, owner: owner) }
            throw primary
        }
    }

    func testSingleClaimReaderCloseAndOwnerCloseKeepSeparateScopeOwnership() async throws {
        let fixture = try makeFixture(wave(pcm: Data([1, 2, 3, 4]))); defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        let prepared = try await owner.prepare(), claimed = try await owner.claimForSending()
        XCTAssertTrue(prepared.reader === claimed.reader)
        await assertOwnerError(.alreadyClaimed) { _ = try await owner.claimForSending() }
        await assertOwnerError(.alreadyClaimed) { _ = try await owner.read(offset: 0, length: 1) }
        try await claimed.reader.close()
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 0)
        XCTAssertEqual(scopes.stops, 0, "The chunk helper prematurely released the owner's scope")
        try await owner.close(); try await owner.close()
        XCTAssertEqual(scopes.stops, 1); XCTAssertEqual(scopes.descriptorsAtStop, [0])
        await assertOwnerError(.closed) { _ = try await owner.prepare() }
        await assertOwnerError(.closed) { _ = try await owner.claimForSending() }
    }

    func testInvalidContainerRetainsExplicitCloseOwnerAndCannotReopenForRetry() async throws {
        let fixture = try makeFixture(Data(repeating: 0x41, count: 64)); defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        do { _ = try await owner.prepare(); XCTFail("Invalid container was prepared") }
        catch { XCTAssertEqual(error as? AudioAlacFileError, .truncated) }
        XCTAssertEqual(scopes.stops, 0); XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 1)
        await assertOwnerError(.preparationAlreadyAttempted) { _ = try await owner.prepare() }
        await assertOwnerError(.notPrepared) { _ = try await owner.claimForSending() }
        try await owner.close()
        XCTAssertEqual(scopes.descriptorsAtStop, [0])
    }

    func testSandboxSourceWithoutScopeAndCancelledCloseStillReleaseDescriptor() async throws {
        let fixture = try makeFixture(wave(pcm: Data([1, 2, 3, 4]))); defer { remove(fixture) }
        let scopes = PreparedAudioScopeCounter(grantsScope: false); let owner = try makeOwner(fixture, scopes: scopes)
        _ = try await owner.prepare()
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 1)
        let closing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await owner.close()
        }
        try await closing.value
        let isClosed = await owner.isClosed
        XCTAssertTrue(isClosed); XCTAssertEqual(scopes.starts, 1); XCTAssertEqual(scopes.stops, 0)
        XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 0)
    }

    func testPrecancelledPreparationAndReadsDoNotAcquireOrAbandonResources() async throws {
        let fixture = try makeFixture(wave(pcm: Data([1, 2, 3, 4]))); defer { remove(fixture) }
        let beforeScopes = PreparedAudioScopeCounter(); let before = try makeOwner(fixture, scopes: beforeScopes)
        let cancelledPrepare = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await before.prepare()
        }
        do { _ = try await cancelledPrepare.value; XCTFail("Precancelled preparation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(beforeScopes.starts, 0); try await before.close(); XCTAssertEqual(beforeScopes.stops, 0)

        let scopes = PreparedAudioScopeCounter(); let owner = try makeOwner(fixture, scopes: scopes)
        let content = try await owner.prepare()
        let cancelledRead = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await owner.read(offset: (try XCTUnwrap(content.wave)).pcmByteOffset, length: 4)
        }
        do { _ = try await cancelledRead.value; XCTFail("Precancelled read succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(scopes.stops, 0); XCTAssertEqual(PreparedAudioScopeCounter.descriptorCount(for: fixture.file), 1)
        let unchanged = try await owner.read(offset: (try XCTUnwrap(content.wave)).pcmByteOffset, length: 4)
        XCTAssertEqual(unchanged, Data([1, 2, 3, 4]))
        try await owner.close()
        XCTAssertEqual(scopes.descriptorsAtStop, [0])
    }

    private struct Fixture: Sendable { let directory: URL; let file: URL }
    private func makeFixture(_ bytes: Data) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ios-prepared-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("source.wav")
        try bytes.write(to: file, options: .withoutOverwriting)
        return Fixture(directory: directory, file: file)
    }
    private func remove(_ fixture: Fixture) { XCTAssertNoThrow(try FileManager.default.removeItem(at: fixture.directory)) }
    private func makeOwner(_ fixture: Fixture, scopes: PreparedAudioScopeCounter,
                           transferID: String = UUID().uuidString) throws -> IOSPreparedAudioFile {
        try IOSPreparedAudioFile(url: fixture.file, transferID: transferID,
            startScope: { scopes.start($0) }, stopScope: { scopes.stop($0) })
    }
    private func rewrite(_ file: URL, offset: off_t, bytes: Data) throws {
        let fd = Darwin.open(file.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { XCTAssertEqual(Darwin.close(fd), 0, "Fixture writer close failed") }
        let written = bytes.withUnsafeBytes { Darwin.pwrite(fd, $0.baseAddress, $0.count, offset) }
        guard written == bytes.count else { throw POSIXError(.EIO) }
    }
    private func wave(tag: UInt16 = 1, bits: UInt16 = 16, validBits: UInt16? = nil,
                      mask: UInt32? = 3, pcm: Data) -> Data {
        let extended = mask != nil || validBits != nil
        var format = Data()
        format.append(le16(extended ? 0xfffe : tag)); format.append(le16(2))
        format.append(le32(44_100)); format.append(le32(44_100 * UInt32(2 * (bits / 8))))
        format.append(le16(2 * (bits / 8))); format.append(le16(bits))
        if extended {
            format.append(le16(22)); format.append(le16(validBits ?? bits)); format.append(le32(mask ?? 0))
            format.append(le32(UInt32(tag))); format.append(contentsOf: [0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71])
        }
        var body = Data("WAVEfmt ".utf8); body.append(le32(UInt32(format.count))); body.append(format)
        body.append(Data("data".utf8)); body.append(le32(UInt32(pcm.count))); body.append(pcm)
        if pcm.count & 1 != 0 { body.append(0xa5) }
        var result = Data("RIFF".utf8); result.append(le32(UInt32(body.count))); result.append(body)
        return result
    }
    private func le16(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
              UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
    }
    private func assertOwnerError(_ expected: IOSPreparedAudioFileError,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? IOSPreparedAudioFileError, expected, file: file, line: line) }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            if clock.now >= deadline { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private struct PreparedAudioTestCleanupFailure: Error {
    let primary: any Error
    let cleanup: any Error
    let owner: IOSPreparedAudioFile
}

private actor PreparedAudioPreparationBarrier {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isPaused = false
    func checkpoint() async {
        calls += 1
        // First callback precedes open; second occurs with the real FD held.
        if calls == 2 && !released {
            await withCheckedContinuation { continuation in self.continuation = continuation; isPaused = true }
        }
    }
    func release() { released = true; let pending = continuation; continuation = nil; pending?.resume() }
}
private actor PreparedAudioCompletionFlag {
    private(set) var value = false
    func mark() { value = true }
}
private final class PreparedAudioScopeCounter: Sendable {
    private struct State: Sendable { var starts = 0; var stops = 0; var descriptorsAtStop: [Int] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let grantsScope: Bool
    init(grantsScope: Bool = true) { self.grantsScope = grantsScope }
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var descriptorsAtStop: [Int] { state.withLock { $0.descriptorsAtStop } }
    func start(_ url: URL) -> Bool { state.withLock { $0.starts += 1 }; return grantsScope }
    func stop(_ url: URL) {
        let count = Self.descriptorCount(for: url)
        state.withLock { $0.stops += 1; $0.descriptorsAtStop.append(count) }
    }
    static func descriptorCount(for file: URL) -> Int {
        var expected = stat()
        guard lstat(file.path, &expected) == 0 else { return -1 }
        return (0..<getdtablesize()).reduce(0) { count, fd in
            var actual = stat()
            return count + (fstat(fd, &actual) == 0 && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino ? 1 : 0)
        }
    }
}

// Frozen RFC 9639 verbatim fixture, independently checked against golden integer PCM by the
// native decoder tests: 44.1 kHz, stereo, true signed 32-bit precision, 31 samples per channel.
/// The shared golden containers are test resources, never audible test material.
enum IOSAudioALACFixture {
    static func data(bits: Int = 24) throws -> Data {
        let hashes = [
            16: "d3114d4af5256079facd17764319898d5b75475267d32ee224f3248627b86665",
            20: "db63226780f608b1e7b933ca0ea639966b0ed48e12fe2851362a26e9dfaafc42",
            24: "34f940ba7591ee804e2fb94c06102022f34631eb51e907a6d6630d865c76a4bc",
            32: "13eb6d30c814e3973f13a0ab5fcdc958835b1f0d8fe15fb2b5a28e3b4a2e3175"
        ]
        let expected = try XCTUnwrap(hashes[bits])
        let url = try XCTUnwrap(Bundle(for: IOSPreparedAudioFileTests.self)
            .url(forResource: "48000-2-s\(bits)", withExtension: "m4a"))
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected)
        return bytes
    }

    static func nonALACSampleEntry() throws -> Data {
        var bytes = try data()
        let entry = try XCTUnwrap(bytes.range(of: Data("alac".utf8)))
        bytes.replaceSubrange(entry, with: Data("mp4a".utf8))
        return bytes
    }
}

enum IOSAudioFLACFixture {
    static let sha256 = "4e598178741caeebaaedf1a9aee8acc291e09e6cfcebcd5367e1487f11f77910"
    static func data(unknownFrames: Bool = false) throws -> Data {
        var bytes = try XCTUnwrap(Data(base64Encoded: "ZkxhQ4AAACIAHwAfAAEDAAEDCsRD8AAAAB+vhnmplTunhqzrvzrLXD6M//hgEAAeEgKAAAAAf/////////8AAAAAAAAAAYAAAFWAAABmgAAAd4AAAIiAAACZgAAAqoAAALuAAADMgAAA3YAAAO6AAAD/gAABEIAAASGAAAEygAABQ4AAAVSAAAFlgAABdoAAAYeAAAGYgAABqYAAAbqAAAHLgAAB3IAAAe2AAAH+An//////////AAAAAAAAAAGAAAAAgAAAdIAAAIWAAACWgAAAp4AAALiAAADJgAAA2oAAAOuAAAD8gAABDYAAAR6AAAEvgAABQIAAAVGAAAFigAABc4AAAYSAAAGVgAABpoAAAbeAAAHIgAAB2YAAAeqAAAH7gAACDIAAAh3M3w=="))
        if unknownFrames {
            bytes[21] &= 0xf0
            for index in 22..<26 { bytes[index] = 0 }
        }
        return bytes
    }
}
