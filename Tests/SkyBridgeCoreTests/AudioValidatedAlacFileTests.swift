import CryptoKit
import Dispatch
import Foundation
import XCTest
import SkyBridgeAudioFile
import SkyBridgeProtocolCore
import os

@MainActor
final class AudioValidatedAlacFileTests: XCTestCase {
    private enum Failure: Error, Equatable { case revoked, timeout, expectedFrame }
    private struct Manifest: Decodable {
        struct Entry: Decodable { let name: String; let frames: UInt64; let encodedSha256: String; let pcmSha256: String }
        let cases: [Entry]
    }

    func testAllRealFilesValidateAndSplitReadsPreserveExactPCM() async throws {
        let directory = try fixtures()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.cases.count, 24)
        for entry in manifest.cases {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(entry.name + ".m4a"))
            let expected = try Data(contentsOf: directory.appendingPathComponent(entry.name + ".pcm"))
            XCTAssertEqual(hex(bytes), entry.encodedSha256); XCTAssertEqual(hex(expected), entry.pcmSha256)
            let (held, _) = try await fixture(bytes)
            let file = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {})
            XCTAssertEqual(file.receipt.sourceFrames, entry.frames)
            XCTAssertEqual(file.receipt.packets, file.metadata.packetCount)
            XCTAssertEqual(file.receipt.encodedAudioBytes, file.metadata.encodedAudioBytes)
            let reader = try AudioAlacPCMReadSession(file: file)
            var actual = Data(), position: UInt64 = 0, turn = 0
            let frameBytes = Int(file.metadata.decodedFormat.bytesPerFrame)
            while position < entry.frames {
                let preferred = [1, 7, 19, AudioAlacPCMReadSession.maximumReadBytes / frameBytes][turn % 4]
                let count = Int(min(UInt64(preferred), entry.frames - position))
                let pcm = try await reader.read(frameOffset: position, frames: count, requireAuthorization: {})
                XCTAssertEqual(pcm.count, count * frameBytes); XCTAssertLessThanOrEqual(pcm.count, 65_536)
                actual.append(pcm); position += UInt64(count); turn += 1
            }
            try await reader.finish(requireAuthorization: {})
            try await reader.finish(requireAuthorization: {})
            XCTAssertEqual(actual, expected, entry.name)
            await reader.close(); await reader.close()
            let prefix = try await held.read(offset: 0, length: 8)
            XCTAssertEqual(prefix, Data(bytes.prefix(8)), "Codec must not take its caller's file ownership")
        }
    }

    func testCorruptLastPacketCannotAcquireAWholeFileWitnessAfterAValidPrefix() async throws {
        var bytes = try input()
        let metadata = try AudioAlacFile.inspect(fileSize: UInt64(bytes.count), read: { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        })
        XCTAssertGreaterThan(metadata.packetCount, 1)
        var cursor = metadata.makePacketCursor(), last: AudioAlacPacket?
        while let packet = try cursor.next(read: { offset, count in bytes.subdata(in: Int(offset)..<(Int(offset) + count)) }) { last = packet }
        let packet = try XCTUnwrap(last)
        bytes[Int(packet.byteOffset)] = (bytes[Int(packet.byteOffset)] & 0x1f) | 0xe0 // ID_END without samples.
        let (held, _) = try await fixture(bytes)
        let indexed = try await AudioIndexedAlacFile.inspect(reader: held, requireAuthorization: {})
        let prefix = try AudioAlacPCMDecoder(file: indexed)
        defer { prefix.close() }
        guard case .frame(let first, let count, _) = try await prefix.next(requireAuthorization: {}) else { throw Failure.expectedFrame }
        XCTAssertEqual(first, 0); XCTAssertGreaterThan(count, 0)
        prefix.close()
        do {
            _ = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {})
            XCTFail("A good prefix hid a damaged last packet")
        } catch let error as AudioAlacDecodeError {
            XCTAssertTrue(error.isContentMismatch)
            guard case .native(_, let code) = error else { XCTFail("Native failure cause was lost"); return }
            XCTAssertLessThan(code, 0)
        }
        let original = try await held.read(offset: 0, length: 8)
        XCTAssertEqual(original, Data(bytes.prefix(8)))
    }

    func testValidationDeadlineAndInvalidLimitsAreEnforced() async throws {
        let (held, _) = try await fixture(input())
        let clock = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        do {
            _ = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {},
                maximumTime: .milliseconds(50), now: {
                    clock.withLock { value in defer { value = value.advanced(by: .milliseconds(10)) }; return value }
                })
            XCTFail("Validation deadline was ignored")
        } catch { XCTAssertEqual(error as? AudioAlacValidationError, .timedOut) }
        for limit in [Duration.zero, .seconds(-1), .seconds(181)] {
            do {
                _ = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {}, maximumTime: limit)
                XCTFail("Invalid deadline admitted")
            } catch { XCTAssertEqual(error as? AudioAlacValidationError, .invalidLimit) }
        }
    }

    func testRevocationAndCancellationAtFinalValidationCallbackCannotPublishAWitness() async throws {
        let (held, _) = try await fixture(input())
        let observed = OSAllocatedUnfairLock(initialState: 0)
        _ = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: { observed.withLock { $0 += 1 } })
        let finalCall = observed.withLock { $0 }
        XCTAssertGreaterThan(finalCall, 20)
        for cancel in [false, true] {
            for stopAt in [1, 20, finalCall] {
                let calls = OSAllocatedUnfairLock(initialState: 0)
                let task = Task {
                    try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {
                        if calls.withLock({ $0 += 1; return $0 }) == stopAt {
                            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                            else { throw Failure.revoked }
                        }
                    })
                }
                do { _ = try await task.value; XCTFail("Retired validation published a witness") }
                catch {
                    if cancel { XCTAssertTrue(error is CancellationError, "\(error)") }
                    else { XCTAssertEqual(error as? Failure, .revoked) }
                }
                XCTAssertEqual(calls.withLock { $0 }, stopAt)
            }
        }
        _ = try await held.read(offset: 0, length: 8)
    }

    func testInvalidReadSequenceDoesNotAdvanceTheNativeOwner() async throws {
        let (held, _) = try await fixture(input())
        let file = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {})
        let reader = try AudioAlacPCMReadSession(file: file)
        for (offset, frames) in [(UInt64(1), 1), (0, 0), (0, -1), (0, AudioAlacPCMReadSession.maximumReadBytes / Int(file.metadata.decodedFormat.bytesPerFrame) + 1)] {
            do { _ = try await reader.read(frameOffset: offset, frames: frames, requireAuthorization: {}); XCTFail("Invalid request admitted") }
            catch { XCTAssertEqual(error as? AudioAlacValidationError, .invalidSequence) }
        }
        do { try await reader.finish(requireAuthorization: {}); XCTFail("Premature finish succeeded") }
        catch { XCTAssertEqual(error as? AudioAlacValidationError, .invalidSequence) }
        let first = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {})
        XCTAssertEqual(first, try reference().prefix(Int(file.metadata.decodedFormat.bytesPerFrame)))
        await reader.close()
    }

    func testCachedSamplesAreRevokedByReaderCloseFileChangePermissionAndOwnerClose() async throws {
        for cause in 0..<4 {
            let (held, url) = try await fixture(input())
            let file = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {})
            let reader = try AudioAlacPCMReadSession(file: file)
            _ = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {})
            if cause == 0 { try await held.close() }
            if cause == 1 {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let date = try XCTUnwrap(attributes[.modificationDate] as? Date).addingTimeInterval(10)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            }
            if cause == 3 { await reader.close() }
            for attempt in 0..<2 {
                do {
                    _ = try await reader.read(frameOffset: 1, frames: 1, requireAuthorization: {
                        if cause == 2 && attempt == 0 { throw Failure.revoked }
                    })
                    XCTFail("Retired cached PCM escaped")
                } catch {
                    switch cause {
                    case 0: XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed)
                    case 1: XCTAssertEqual(error as? PreparedOutboundFileReadError, .sourceChanged)
                    case 2: XCTAssertEqual(error as? Failure, .revoked)
                    default: XCTAssertEqual(error as? AudioAlacDecodeError, .closed)
                    }
                }
            }
            await reader.close()
        }
    }

    func testCancellationInFinalCachedReadCallbackReturnsNoPCMAndIsSticky() async throws {
        let (held, _) = try await fixture(input())
        let file = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {})
        let baseline = try AudioAlacPCMReadSession(file: file), observed = OSAllocatedUnfairLock(initialState: 0)
        _ = try await baseline.read(frameOffset: 0, frames: 1, requireAuthorization: {})
        _ = try await baseline.read(frameOffset: 1, frames: 1, requireAuthorization: { observed.withLock { $0 += 1 } })
        let finalCall = observed.withLock { $0 }; await baseline.close()
        XCTAssertGreaterThan(finalCall, 1)
        let reader = try AudioAlacPCMReadSession(file: file), calls = OSAllocatedUnfairLock(initialState: 0)
        _ = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {})
        let task = Task {
            try await reader.read(frameOffset: 1, frames: 1) {
                if calls.withLock({ $0 += 1; return $0 }) == finalCall { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled cached read returned PCM") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(calls.withLock { $0 }, finalCall)
        do { _ = try await reader.read(frameOffset: 1, frames: 1, requireAuthorization: {}); XCTFail("Cancelled read resumed") }
        catch { XCTAssertTrue(error is CancellationError) }
        await reader.close()
    }

    func testConcurrentReadIsRejectedWithoutPoisoningTheActiveRead() async throws {
        let (held, _) = try await fixture(input())
        let file = try await AudioValidatedAlacFile.validate(reader: held, requireAuthorization: {})
        let reader = try AudioAlacPCMReadSession(file: file)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let first = Task.detached {
            try await reader.read(frameOffset: 0, frames: 1) {
                if calls.withLock({ $0 += 1; return $0 }) == 20 {
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else { throw Failure.timeout }
                }
            }
        }
        let ready = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        XCTAssertTrue(ready)
        if ready {
            do { _ = try await reader.read(frameOffset: 0, frames: 1, requireAuthorization: {}); XCTFail("Overlapping read queued") }
            catch { XCTAssertEqual(error as? AudioAlacValidationError, .invalidSequence) }
        }
        release.signal()
        let firstBytes = try await first.value
        XCTAssertEqual(firstBytes, try reference().prefix(Int(file.metadata.decodedFormat.bytesPerFrame)))
        await reader.close()
    }

    private func hex(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func fixtures() throws -> URL { try XCTUnwrap(Bundle.module.url(forResource: "alac-decoder-v1", withExtension: nil)) }
    private func input() throws -> Data { try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a")) }
    private func reference() throws -> Data { try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.pcm")) }
    private func fixture(_ bytes: Data) async throws -> (PreparedOutboundFileReadSession, URL) {
        let source = try await AudioAlacTestFixture.prepare(data: bytes, in: self)
        return (source.reader, source.url)
    }
}

struct AudioAlacTestFixture: Sendable {
    let reader: PreparedOutboundFileReadSession
    let url: URL

    static func resource(_ name: String, extension suffix: String) throws -> Data {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "alac-decoder-v1", withExtension: nil))
        return try Data(contentsOf: directory.appendingPathComponent(name + "." + suffix))
    }

    static func withInvalidFinalPacket(_ name: String) throws -> Data {
        var bytes = try resource(name, extension: "m4a")
        let metadata = try AudioAlacFile.inspect(fileSize: UInt64(bytes.count), read: { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        })
        XCTAssertGreaterThan(metadata.packetCount, 1)
        var cursor = metadata.makePacketCursor(), last: AudioAlacPacket?
        while let packet = try cursor.next(read: { offset, count in bytes.subdata(in: Int(offset)..<(Int(offset) + count)) }) { last = packet }
        let packet = try XCTUnwrap(last)
        bytes[Int(packet.byteOffset)] = (bytes[Int(packet.byteOffset)] & 0x1f) | 0xe0
        return bytes
    }

    @MainActor static func prepare(_ name: String, in test: XCTestCase) async throws -> Self {
        try await prepare(data: resource(name, extension: "m4a"), in: test)
    }

    @MainActor static func prepare(data bytes: Data, in test: XCTestCase) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("audio-alac-validation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        test.addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.m4a"); try bytes.write(to: url, options: .withoutOverwriting)
        let reader = try await PreparedOutboundFileReadSession.prepare(url: url, maximumSize: Int64(bytes.count),
            sourcePolicy: .ownedSingleLinkStableMetadata, expectedSHA256: Data(SHA256.hash(data: bytes)))
        test.addTeardownBlock { try await reader.close() }
        return .init(reader: reader, url: url)
    }
}
