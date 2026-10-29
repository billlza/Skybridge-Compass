import CryptoKit
import Dispatch
import Foundation
import XCTest
import SkyBridgeAudioFile
import SkyBridgeProtocolCore
import os

@MainActor
final class AudioAlacPCMDecoderTests: XCTestCase {
    private final class Revoked: Error {}
    private enum Failure: Error { case timeout, expectedFrame }
    private struct Manifest: Decodable {
        struct Entry: Decodable { let name: String; let frames: UInt64; let encodedSha256: String; let pcmSha256: String }
        let cases: [Entry]
    }

    func testAllRealFilesDecodeToExactIntegerReferencesThroughTheHeldReader() async throws {
        let directory = try fixtures()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.cases.count, 24)
        for entry in manifest.cases {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(entry.name + ".m4a"))
            let expected = try Data(contentsOf: directory.appendingPathComponent(entry.name + ".pcm"))
            XCTAssertEqual(hex(bytes), entry.encodedSha256); XCTAssertEqual(hex(expected), entry.pcmSha256)
            let (file, _) = try await fixture(bytes)
            let decoder = try AudioAlacPCMDecoder(file: file)
            let (pcm, receipt) = try await decode(decoder)
            XCTAssertEqual(pcm, expected, entry.name)
            XCTAssertEqual(receipt.sourceFrames, entry.frames)
            XCTAssertEqual(receipt.packets, file.metadata.packetCount)
            XCTAssertEqual(receipt.encodedAudioBytes, file.metadata.encodedAudioBytes)
            guard case .complete(let repeated) = try await decoder.next(requireAuthorization: {}) else { throw Failure.expectedFrame }
            XCTAssertEqual(repeated, receipt)
            decoder.close(); decoder.close()
            let prefix = try await file.reader.read(offset: 0, length: 8)
            XCTAssertEqual(prefix, Data(bytes.prefix(8)), "Decoder closed its caller's reader")
        }
    }

    func testMissingDeclaredFrameIsAnExplicitStickyNativeFailure() async throws {
        var bytes = try input()
        let metadata = try AudioAlacFile.inspect(fileSize: UInt64(bytes.count), read: { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        })
        var cursor = metadata.makePacketCursor()
        let packet = try XCTUnwrap(cursor.next(read: { offset, count in bytes.subdata(in: Int(offset)..<(Int(offset) + count)) }))
        // ID_END before any sample element: the historical system decoder silently produced zeros.
        bytes[Int(packet.byteOffset)] = (bytes[Int(packet.byteOffset)] & 0x1f) | 0xe0
        let (file, _) = try await fixture(bytes)
        let decoder = try AudioAlacPCMDecoder(file: file)
        defer { decoder.close() }
        var first: AudioAlacDecodeError?
        for attempt in 0..<2 {
            do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Corrupt packet produced PCM") }
            catch let error as AudioAlacDecodeError {
                guard case .native(_, let code) = error else { XCTFail("Native cause was lost"); return }
                XCTAssertLessThan(code, 0)
                if attempt == 0 { first = error } else { XCTAssertEqual(error, first) }
            }
        }
    }

    func testRevocationBeforeDecodeAndDuringNativeCopyKeepsItsCause() async throws {
        let (file, _) = try await fixture(input())
        for stopAt in [1, 20] {
            let decoder = try AudioAlacPCMDecoder(file: file), revoked = Revoked()
            let calls = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try await decoder.next {
                    if calls.withLock({ $0 += 1; return $0 }) == stopAt { throw revoked }
                }
                XCTFail("Revoked decode published PCM")
            } catch { XCTAssertTrue((error as? Revoked) === revoked) }
            XCTAssertEqual(calls.withLock { $0 }, stopAt)
            do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Failed owner resumed") }
            catch { XCTAssertTrue((error as? Revoked) === revoked) }
            decoder.close()
        }
    }

    func testCloseFromAuthorizationCallbackDefersDestructionAndPublishesNoPCM() async throws {
        let (file, _) = try await fixture(input())
        for stopAt in [1, 20] {
            let decoder = try AudioAlacPCMDecoder(file: file)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try await decoder.next {
                    if calls.withLock({ $0 += 1; return $0 }) == stopAt { decoder.close() }
                }
                XCTFail("Closed owner published PCM")
            } catch { XCTAssertEqual(error as? AudioAlacDecodeError, .closed) }
            XCTAssertEqual(calls.withLock { $0 }, stopAt)
            decoder.close()
        }
    }

    func testTaskCancellationDuringNativeCallbackAndFinalPublicationIsTerminal() async throws {
        let (file, _) = try await fixture(input())
        let baseline = try AudioAlacPCMDecoder(file: file)
        let observed = OSAllocatedUnfairLock(initialState: 0)
        _ = try await baseline.next { observed.withLock { $0 += 1 } }
        let finalCall = observed.withLock { $0 }; baseline.close()
        XCTAssertGreaterThan(finalCall, 20)
        for stopAt in [20, finalCall] {
            let decoder = try AudioAlacPCMDecoder(file: file)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let task = Task {
                try await decoder.next {
                    if calls.withLock({ $0 += 1; return $0 }) == stopAt { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do { _ = try await task.value; XCTFail("Cancelled owner published PCM") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(calls.withLock { $0 }, stopAt)
            do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Cancelled owner resumed") }
            catch { XCTAssertTrue(error is CancellationError) }
            decoder.close()
        }
    }

    func testClosedOrMutatedReaderFailureIsPreserved() async throws {
        for closed in [false, true] {
            let (file, url) = try await fixture(input())
            let decoder = try AudioAlacPCMDecoder(file: file)
            if closed { try await file.reader.close() }
            else {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let modified = try XCTUnwrap(attributes[.modificationDate] as? Date).addingTimeInterval(10)
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            }
            do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Invalid reader produced PCM") }
            catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, closed ? .closed : .sourceChanged) }
            decoder.close()
        }
    }

    func testPathReplacementStillDecodesTheHeldOriginal() async throws {
        let bytes = try input(), replacement = try Data(contentsOf: fixtures().appendingPathComponent("44100-1-s16.m4a"))
        let (file, url) = try await fixture(bytes)
        try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("held.m4a"))
        try replacement.write(to: url, options: .withoutOverwriting)
        let decoder = try AudioAlacPCMDecoder(file: file); defer { decoder.close() }
        let (pcm, _) = try await decode(decoder)
        XCTAssertEqual(pcm, try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.pcm")))
    }

    func testConcurrentReadIsRejectedWithoutPoisoningTheActiveDecode() async throws {
        let (file, _) = try await fixture(input())
        let decoder = try AudioAlacPCMDecoder(file: file); defer { decoder.close() }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let first = Task.detached {
            try await decoder.next {
                if calls.withLock({ $0 += 1; return $0 }) == 20 {
                    entered.signal()
                    guard release.wait(timeout: .now() + 5) == .success else { throw Failure.timeout }
                }
            }
        }
        let ready = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        XCTAssertTrue(ready)
        if ready {
            do { _ = try await decoder.next(requireAuthorization: {}); XCTFail("Concurrent decode was queued") }
            catch { XCTAssertEqual(error as? AudioAlacDecodeError, .concurrentRead) }
        }
        release.signal()
        guard case .frame = try await first.value else { throw Failure.expectedFrame }
    }

    private func decode(_ decoder: AudioAlacPCMDecoder) async throws -> (Data, AudioAlacDecodeReceipt) {
        var bytes = Data(), frames: UInt64 = 0
        for _ in 0...decoder.metadata.packetCount {
            switch try await decoder.next(requireAuthorization: {}) {
            case .frame(let first, let count, let pcm):
                XCTAssertEqual(first, frames); frames += UInt64(count); bytes.append(pcm)
            case .complete(let receipt):
                XCTAssertEqual(receipt.sourceFrames, frames)
                return (bytes, receipt)
            }
        }
        throw Failure.expectedFrame
    }
    private func hex(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func fixtures() throws -> URL { try XCTUnwrap(Bundle.module.url(forResource: "alac-decoder-v1", withExtension: nil)) }
    private func input() throws -> Data { try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a")) }
    private func fixture(_ bytes: Data) async throws -> (AudioIndexedAlacFile, URL) {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("audio-alac-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.m4a"); try bytes.write(to: url, options: .withoutOverwriting)
        let reader = try await PreparedOutboundFileReadSession.prepare(url: url, maximumSize: Int64(bytes.count),
            sourcePolicy: .ownedSingleLinkStableMetadata, expectedSHA256: Data(SHA256.hash(data: bytes)))
        addTeardownBlock { try await reader.close() }
        return (try await AudioIndexedAlacFile.inspect(reader: reader, requireAuthorization: {}), url)
    }
}
