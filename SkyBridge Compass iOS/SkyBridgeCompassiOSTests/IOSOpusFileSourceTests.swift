import XCTest
import Foundation
import Darwin
import os
import SkyBridgeAudioFile
import SkyBridgeOpus
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

@MainActor
final class IOSOpusFileSourceTests: XCTestCase {
    func testWaveConversionAndRealCodecPreserveFiniteDurationForSupportedInputs() async throws {
        let cases: [(UInt32, UInt16, UInt16, UInt16)] = [
            (48_000, 2, 16, 1), (44_100, 2, 24, 1), (8_000, 1, 16, 1),
            (96_000, 2, 32, 3), (384_000, 1, 64, 3)
        ]
        for (rate, channels, bits, tag) in cases {
            let frames = Int(rate) / 10 + 17
            let bytes = wave(rate: rate, channels: channels, bits: bits, tag: tag,
                             frames: frames, legacy: false)
            try await withFile(bytes) { url in
                let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
                do {
                    let plan = try await source.prepare()
                    XCTAssertEqual(plan.opus.bitrate, 128_000)
                    XCTAssertEqual(plan.originalFormat.sampleRate, rate)
                    XCTAssertEqual(plan.originalFormat.declaredValidBits, UInt8(bits))
                    XCTAssertEqual(plan.sourceFrames, UInt64(frames))
                    XCTAssertFalse(plan.interpretsLegacyWaveLayout)
                    let format = try await source.start()
                    let decoder = try SkyBridgeOpusStreamDecoder(format: format)
                    var decoded = Data(), packets: UInt64 = 0
                    while let packet = try await source.nextPacket() {
                        XCTAssertEqual(packet.sequence, packets)
                        XCTAssertEqual(packet.firstDecodedFrame, packets * 960)
                        XCTAssertEqual(packet.bytes.count, 320)
                        if let chunk = try decoder.append(packet: packet.bytes, sequence: packet.sequence) {
                            XCTAssertEqual(chunk.firstPCMFrame, UInt64(decoded.count / (2 * Int(channels))))
                            decoded.append(chunk.pcm16LE)
                        }
                        packets += 1
                    }
                    let completion = try await source.completedEncoding()
                    let wantedFrames = (UInt64(frames) * 48_000 + UInt64(rate) - 1) / UInt64(rate)
                    let final = try decoder.finish(expectedPCMFrames: wantedFrames)
                    decoded.append(final.finalChunk.pcm16LE)
                    XCTAssertEqual(decoded.count, Int(wantedFrames) * Int(channels) * 2)
                    XCTAssertEqual(completion.encoding.packetCount, packets)
                    XCTAssertEqual(completion.conversion.sourceFrames, UInt64(frames))
                    XCTAssertEqual(completion.conversion.convertedFrames, wantedFrames)
                    XCTAssertEqual(completion.encoding.sourceFrames, wantedFrames)
                    // Independent 1 kHz reference checks real decoded content and channel order,
                    // not merely the producer's accounting. Ignore codec/filter edge transients.
                    for channel in 0..<Int(channels) {
                        var dot = 0.0, energy = 0.0, referenceEnergy = 0.0
                        for frame in 960..<(Int(wantedFrames) - 960) {
                            let offset = (frame * Int(channels) + channel) * 2
                            let sample = Double(Int16(bitPattern: UInt16(decoded[offset]) | UInt16(decoded[offset + 1]) << 8)) / 32768
                            let reference = sin(Double(frame) * 2 * .pi * 1000 / 48_000) * (channel == 0 ? 0.25 : -0.125)
                            dot += sample * reference; energy += sample * sample; referenceEnergy += reference * reference
                        }
                        XCTAssertGreaterThan(dot / sqrt(energy * referenceEnergy), 0.94, "rate=\(rate), channel=\(channel)")
                    }
                    let state = await source.snapshot()
                    XCTAssertTrue(state.sourceVerified); XCTAssertTrue(state.resourcesReleased)
                    XCTAssertEqual(state.queuedPackets, 0)
                    XCTAssertLessThanOrEqual(state.maximumQueuedPackets, IOSOpusFileSource.maximumQueuedPackets)
                    try await source.close()
                } catch {
                    let original = error
                    try await source.close(); throw original
                }
            }
        }
    }

    func testALACIsNotSilentlyAcceptedByTheUnqualifiedBluetoothSource() async throws {
        try await withFile(IOSAudioALACFixture.data(), name: "source.m4a") { url in
            let source = try IOSOpusFileSource(url: url, bitrate: 256_000, requireEffectAuthorization: {})
            do { _ = try await source.prepare(); XCTFail("Bluetooth ALAC path is not qualified") }
            catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .unsupportedFormat) }
            try await source.close()
            let state = await source.snapshot()
            XCTAssertTrue(state.resourcesReleased); XCTAssertEqual(state.queuedPackets, 0)
        }
    }

    func testFrozenFLACIsValidatedDecodedConvertedAndEncodedWithExactFiniteEnd() async throws {
        let bytes = try IOSAudioFLACFixture.data()
        try await withFile(bytes, name: "source.flac") { url in
            let source = try IOSOpusFileSource(url: url, bitrate: 256_000, requireEffectAuthorization: {})
            do {
                let plan = try await source.prepare()
                XCTAssertEqual(plan.originalFormat.sampleRate, 44_100)
                XCTAssertEqual(plan.originalFormat.declaredValidBits, 32)
                XCTAssertEqual(plan.sourceFrames, 31); XCTAssertEqual(plan.convertedFrames, 34)
                let format = try await source.start()
                let decoder = try SkyBridgeOpusStreamDecoder(format: format)
                var frames: UInt64 = 0
                while let packet = try await source.nextPacket() {
                    XCTAssertEqual(packet.bytes.count, 640)
                    if let chunk = try decoder.append(packet: packet.bytes, sequence: packet.sequence) { frames += UInt64(chunk.frameCount) }
                }
                let end = try await source.completedEncoding()
                frames += UInt64(try decoder.finish(expectedPCMFrames: end.encoding.sourceFrames).finalChunk.frameCount)
                XCTAssertEqual(frames, 34)
                let snapshot = await source.snapshot()
                XCTAssertTrue(snapshot.resourcesReleased); XCTAssertTrue(snapshot.sourceVerified)
                XCTAssertEqual(descriptorCount(url), 0)
                try await source.close()
            } catch { let primary = error; try await source.close(); throw primary }
        }
    }

    func testPreparationAndStartDoNotProducePacketsAndPullBackpressureIsBounded() async throws {
        try await withFile(wave(rate: 8_000, channels: 1, bits: 16, frames: 40_000, legacy: true)) { url in
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
            do {
                let plan = try await source.prepare()
                XCTAssertTrue(plan.interpretsLegacyWaveLayout)
                XCTAssertNil(plan.originalFormat.waveChannelMask)
                XCTAssertEqual(plan.conversionInputFormat.waveChannelMask, 4)
                let prepared = await source.snapshot()
                XCTAssertEqual(prepared.sourceFramesRead, 0); XCTAssertEqual(prepared.queuedPackets, 0)
                _ = try await source.start()
                let started = await source.snapshot()
                XCTAssertEqual(started.sourceFramesRead, 0); XCTAssertEqual(started.returnedPackets, 0)
                let first = try await source.nextPacket()
                XCTAssertNotNil(first)
                let pulled = await source.snapshot()
                XCTAssertGreaterThan(pulled.queuedPackets, 0)
                XCTAssertLessThan(pulled.sourceFramesRead, plan.sourceFrames)
                try await Task.sleep(for: .milliseconds(50))
                let idle = await source.snapshot()
                XCTAssertEqual(idle.sourceFramesRead, pulled.sourceFramesRead)
                XCTAssertEqual(idle.queuedPackets, pulled.queuedPackets)
                XCTAssertEqual(idle.returnedPackets, 1)
                XCTAssertLessThanOrEqual(idle.queuedPackets, IOSOpusFileSource.maximumQueuedPackets)
                do { _ = try await source.completedEncoding(); XCTFail("A buffered partial source reported completion") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .invalidProgress) }
                try await source.close()
                let closed = await source.snapshot()
                XCTAssertTrue(closed.resourcesReleased); XCTAssertFalse(closed.sourceVerified)
                XCTAssertEqual(closed.queuedPackets, 0); XCTAssertEqual(descriptorCount(url), 0)
            } catch { let primary = error; try await source.close(); throw primary }
        }
    }

    func testRevocationRejectsAlreadyEncodedPacketAndCannotBeReenabled() async throws {
        try await withFile(wave(frames: 20_000)) { url in
            let authority = OpusSourceAuthority()
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: authority.check)
            do {
                _ = try await source.prepare(); _ = try await source.start(); _ = try await source.nextPacket()
                let before = await source.snapshot(); XCTAssertGreaterThan(before.queuedPackets, 0)
                authority.revoke()
                do { _ = try await source.nextPacket(); XCTFail("Revoked buffered packet escaped") }
                catch { XCTAssertEqual(error as? OpusSourceAuthority.Failure, .revoked) }
                authority.restore()
                do { try source.requireEffectCurrent(); XCTFail("A failed source was resurrected") }
                catch { XCTAssertEqual(error as? OpusSourceAuthority.Failure, .revoked) }
                let after = await source.snapshot()
                XCTAssertEqual(before.returnedPackets, after.returnedPackets)
                try await source.close()
                let closed = await source.snapshot()
                XCTAssertTrue(closed.resourcesReleased); XCTAssertFalse(closed.sourceVerified)
                XCTAssertEqual(descriptorCount(url), 0)
            } catch { let primary = error; try await source.close(); throw primary }
        }
    }

    func testTruncatingHeldSourceRejectsQueuedPacketBeforeItsRelease() async throws {
        try await withFile(wave(frames: 20_000)) { url in
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
            do {
                _ = try await source.prepare(); _ = try await source.start(); _ = try await source.nextPacket()
                let before = await source.snapshot(); XCTAssertGreaterThan(before.queuedPackets, 0)
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 32); try handle.close()
                do { _ = try await source.nextPacket(); XCTFail("Changed source returned a queued packet") }
                catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .sourceChanged) }
                let after = await source.snapshot(); XCTAssertEqual(after.returnedPackets, before.returnedPackets)
                try await source.close(); XCTAssertEqual(descriptorCount(url), 0)
            } catch { let primary = error; try await source.close(); throw primary }
        }
    }

    func testMalformedFLACNeverStartsEncodingAndCloseReleasesHeldReader() async throws {
        var bytes = try IOSAudioFLACFixture.data(); bytes[bytes.count - 1] ^= 1
        try await withFile(bytes, name: "corrupt.flac") { url in
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
            var failure: (any Error)?
            do { _ = try await source.prepare(); XCTFail("Corrupt FLAC was prepared") }
            catch { failure = error }
            XCTAssertNotNil(failure)
            do { _ = try await source.start(); XCTFail("Corrupt source started") }
            catch { XCTAssertEqual(String(describing: error), String(describing: try XCTUnwrap(failure))) }
            try await source.close()
            let state = await source.snapshot()
            XCTAssertEqual(state.sourceFramesRead, 0); XCTAssertEqual(state.returnedPackets, 0)
            XCTAssertFalse(state.sourceVerified); XCTAssertTrue(state.resourcesReleased)
            XCTAssertEqual(descriptorCount(url), 0)
        }
    }

    func testUnknownFLACDurationAndExplicitNoncanonicalLayoutAreRejected() async throws {
        let cases = [try IOSAudioFLACFixture.data(unknownFrames: true), wave(frames: 96, mask: 0)]
        for (index, bytes) in cases.enumerated() {
            try await withFile(bytes) { url in
                let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
                do { _ = try await source.prepare(); XCTFail("Unsupported input passed") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, index == 0 ? .invalidDuration : .unsupportedLayout) }
                try await source.close(); XCTAssertEqual(descriptorCount(url), 0)
            }
        }
    }

    func testCancelledCallerCanStillJoinCloseAndSourceRemainsRetired() async throws {
        try await withFile(wave(frames: 20_000)) { url in
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
            _ = try await source.prepare(); _ = try await source.start(); _ = try await source.nextPacket()
            let closing = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await source.close()
            }
            try await closing.value
            let state = await source.snapshot()
            XCTAssertTrue(state.resourcesReleased); XCTAssertFalse(state.cleanupPending)
            XCTAssertEqual(descriptorCount(url), 0)
            do { _ = try await source.nextPacket(); XCTFail("Closed source returned EOF/success") }
            catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .stopped) }
            try await source.close()
        }
    }

    func testPrecancelledPreparationAndExplicitCancelOpenNoFile() async throws {
        try await withFile(wave(frames: 96)) { url in
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
            let preparing = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await source.prepare()
            }
            do { _ = try await preparing.value; XCTFail("Cancelled prepare succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            try await source.close(); XCTAssertEqual(descriptorCount(url), 0)
            let another = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
            another.cancel()
            do { _ = try await another.prepare(); XCTFail("Explicitly cancelled source reopened") }
            catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .stopped) }
            try await another.close(); XCTAssertEqual(descriptorCount(url), 0)
        }
    }

    func testSingleStartAndInvalidCloseTimeoutDoNotReleaseActiveOwner() async throws {
        try await withFile(wave(frames: 96)) { url in
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: {})
            do {
                do { _ = try await source.start(); XCTFail("Unprepared source started") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .notPrepared) }
                _ = try await source.prepare(); _ = try await source.start()
                do { _ = try await source.start(); XCTFail("Source started twice") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .alreadyStarted) }
                do { try await source.close(timeout: .zero); XCTFail("Invalid timeout accepted") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .invalidCleanupTimeout) }
                XCTAssertEqual(descriptorCount(url), 1)
                let packet = try await source.nextPacket(); XCTAssertNotNil(packet)
                try await source.close(); XCTAssertEqual(descriptorCount(url), 0)
            } catch { let primary = error; try await source.close(); throw primary }
        }
    }

    func testCloseTimeoutRetainsActualInFlightPreparationUntilRejoined() async throws {
        try await withFile(wave(frames: 96)) { url in
            // Pause an actual held-descriptor operation, rather than treating a timer or a
            // cancelled Task handle as proof that its underlying file work has stopped.
            let barrier = OpusSourcePreparationBarrier(url: url)
            let source = try IOSOpusFileSource(url: url, requireEffectAuthorization: barrier.check)
            let preparing = Task { try await source.prepare() }
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !barrier.waiting {
                    guard ContinuousClock.now < deadline else { throw OpusSourcePreparationBarrier.Failure.notReached }
                    try await Task.sleep(for: .milliseconds(5))
                }
                do { try await source.close(timeout: .milliseconds(20)); XCTFail("Active file operation falsely reported closed") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .cleanupTimedOut) }
                let pending = await source.snapshot()
                XCTAssertTrue(pending.cleanupPending); XCTAssertFalse(pending.resourcesReleased)
                XCTAssertEqual(descriptorCount(url), 1)
                do { try source.requireEffectCurrent(); XCTFail("Timed-out cleanup still allowed effects") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .stopped) }
                barrier.release()
                do { _ = try await preparing.value; XCTFail("Retired preparation returned a usable plan") }
                catch { XCTAssertEqual(error as? IOSOpusFileSourceError, .stopped) }
                try await source.close()
                let closed = await source.snapshot()
                XCTAssertTrue(closed.resourcesReleased); XCTAssertFalse(closed.cleanupPending)
                XCTAssertEqual(closed.returnedPackets, 0); XCTAssertEqual(descriptorCount(url), 0)
            } catch {
                let primary = error
                barrier.release(); source.cancel(); preparing.cancel()
                _ = await preparing.result
                try await source.close(); throw primary
            }
        }
    }

    private func withFile(_ bytes: Data, name: String = "source.wav", operation: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("opus-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { do { try FileManager.default.removeItem(at: directory) } catch { XCTFail("Fixture cleanup: \(error)") } }
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file, options: .withoutOverwriting)
        try await operation(file)
    }

    private func wave(rate: UInt32 = 48_000, channels: UInt16 = 2, bits: UInt16 = 16, tag: UInt16 = 1,
                      frames: Int, legacy: Bool = false, mask: UInt32? = nil) -> Data {
        var pcm = Data()
        for frame in 0..<frames {
            for channel in 0..<Int(channels) {
                let value = sin(Double(frame) * 2 * .pi * 1000 / Double(rate)) * (channel == 0 ? 0.25 : -0.125)
                if tag == 3 {
                    if bits == 32 { appendLE(Float(value).bitPattern, to: &pcm) }
                    else { appendLE(value.bitPattern, to: &pcm) }
                } else {
                    let sample = Int64((value * pow(2, Double(bits - 1))).rounded())
                    for byte in 0..<Int(bits / 8) { pcm.append(UInt8(truncatingIfNeeded: sample >> (8 * byte))) }
                }
            }
        }
        var format = Data()
        appendLE(legacy ? tag : UInt16(0xfffe), to: &format)
        appendLE(channels, to: &format); appendLE(rate, to: &format)
        let alignment = channels * bits / 8
        appendLE(rate * UInt32(alignment), to: &format); appendLE(alignment, to: &format); appendLE(bits, to: &format)
        if !legacy {
            appendLE(UInt16(22), to: &format); appendLE(bits, to: &format)
            appendLE(mask ?? (channels == 1 ? 4 : 3), to: &format)
            appendLE(UInt32(tag), to: &format)
            format.append(Data([0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]))
        }
        var body = Data("WAVEfmt ".utf8)
        appendLE(UInt32(format.count), to: &body); body.append(format); body.append(Data("data".utf8))
        appendLE(UInt32(pcm.count), to: &body); body.append(pcm)
        if pcm.count % 2 != 0 { body.append(0) }
        var file = Data("RIFF".utf8); appendLE(UInt32(body.count), to: &file); file.append(body)
        return file
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

}

private func descriptorCount(_ url: URL) -> Int {
    var expected = stat()
    guard lstat(url.path, &expected) == 0 else { return -1 }
    return (0..<getdtablesize()).reduce(0) { count, fd in
        var actual = stat()
        return count + (fstat(fd, &actual) == 0 && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino ? 1 : 0)
    }
}

private final class OpusSourceAuthority: Sendable {
    enum Failure: Error { case revoked }
    private let allowed = OSAllocatedUnfairLock(initialState: true)
    func revoke() { allowed.withLock { $0 = false } }
    func restore() { allowed.withLock { $0 = true } }
    func check() throws { guard allowed.withLock({ $0 }) else { throw Failure.revoked } }
}

private final class OpusSourcePreparationBarrier: Sendable {
    enum Failure: Error { case notReached, notReleased }
    private struct State { var used = false; var waiting = false }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let released = DispatchSemaphore(value: 0)
    private let url: URL
    init(url: URL) { self.url = url }
    var waiting: Bool { state.withLock { $0.waiting } }
    func check() throws {
        guard !state.withLock({ $0.used }), descriptorCount(url) == 1 else { return }
        let pause = state.withLock { value in
            if value.used { return false }
            value.used = true; value.waiting = true; return true
        }
        guard pause else { return }
        guard released.wait(timeout: .now() + 5) == .success else { throw Failure.notReleased }
    }
    func release() { released.signal() }
}
