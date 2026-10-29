import CryptoKit
import Foundation
import XCTest
import os
import SkyBridgeAudioFile
import SkyBridgeProtocolCore

/// Real held descriptors and block commitments. These tests inspect/index ALAC; they do not
/// substitute metadata validity for decoded PCM or output-device acceptance.
@MainActor
final class AudioIndexedAlacFileTests: XCTestCase {
    private final class Revoked: Error {}
    private struct Manifest: Decodable {
        struct Entry: Decodable { let name: String; let rate: UInt32; let channels: UInt16; let validBits: UInt8; let frames: UInt64; let encodedSha256: String }
        let cases: [Entry]
    }

    func testRealFilesBindDeclarationsToTheCallerReader() async throws {
        let root = try fixtures()
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.cases.count, 24)
        for item in manifest.cases {
            let data = try Data(contentsOf: root.appendingPathComponent(item.name + ".m4a"))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), item.encodedSha256)
            let source = try await fixture(data)
            let indexed = try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {})
            XCTAssertTrue(indexed.reader === source.reader)
            XCTAssertEqual(indexed.metadata.decodedFormat.sampleRate, item.rate)
            XCTAssertEqual(indexed.metadata.decodedFormat.channels, item.channels)
            XCTAssertEqual(indexed.metadata.decodedFormat.declaredValidBits, item.validBits)
            XCTAssertEqual(indexed.metadata.totalFrames, item.frames)
            let prefix = try await source.reader.read(offset: 0, length: 8)
            XCTAssertEqual(prefix, Data(data.prefix(8)))
            try await source.reader.close()
        }
    }

    func testPathReplacementDoesNotReopenAnotherFile() async throws {
        let original = try Data(contentsOf: fixtures().appendingPathComponent("44100-1-s16.m4a"))
        let replacement = try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a"))
        let source = try await fixture(original)
        try FileManager.default.moveItem(at: source.url, to: source.url.deletingLastPathComponent().appendingPathComponent("held.m4a"))
        try replacement.write(to: source.url, options: .withoutOverwriting)
        let indexed = try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {})
        XCTAssertEqual(indexed.metadata.decodedFormat.sampleRate, 44100)
        XCTAssertEqual(indexed.metadata.decodedFormat.channels, 1)
        XCTAssertEqual(indexed.metadata.decodedFormat.declaredValidBits, 16)
        XCTAssertEqual(indexed.reader.metadata.contentSHA256, Data(SHA256.hash(data: original)))
        XCTAssertEqual(try Data(contentsOf: source.url), replacement)
    }

    func testClosedReaderCannotBeReopenedByInspection() async throws {
        let source = try await fixture(Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a")))
        try await source.reader.close()
        do {
            _ = try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {})
            XCTFail("Closed reader produced an indexed source")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
    }

    func testAuthorizationFailureKeepsItsCauseAndCallerOwnership() async throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a"))
        for revokeAt in [1, 5] {
            let source = try await fixture(data), revocation = Revoked()
            let calls = OSAllocatedUnfairLock(initialState: 0)
            do {
                _ = try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {
                    if calls.withLock({ $0 += 1; return $0 }) == revokeAt { throw revocation }
                })
                XCTFail("Revoked source inspection completed")
            } catch { XCTAssertTrue((error as? Revoked) === revocation) }
            XCTAssertEqual(calls.withLock { $0 }, revokeAt)
            let bytes = try await source.reader.read(offset: 0, length: 8)
            XCTAssertEqual(bytes, Data(data.prefix(8)))
        }
    }

    func testCancellationBeforeAndInsideBorrowedScopeDoesNotReturnAnIndex() async throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a"))
        for during in [false, true] {
            let source = try await fixture(data)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let operation = Task {
                if !during { withUnsafeCurrentTask { $0?.cancel() } }
                return try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {
                    if during && calls.withLock({ $0 += 1; return $0 }) == 5 { withUnsafeCurrentTask { $0?.cancel() } }
                })
            }
            do { _ = try await operation.value; XCTFail("Cancelled source inspection completed") }
            catch { XCTAssertTrue(error is CancellationError) }
            let bytes = try await source.reader.read(offset: 0, length: 8)
            XCTAssertEqual(bytes, Data(data.prefix(8)))
        }
    }

    func testMutationWithinInspectionPreservesTheReaderFailure() async throws {
        let data = try Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a"))
        let source = try await fixture(data), url = source.url
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date).addingTimeInterval(2)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        do {
            _ = try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {
                if calls.withLock({ $0 += 1; return $0 }) == 5 {
                    let writer = try FileHandle(forWritingTo: url)
                    try writer.write(contentsOf: Data([0xff]))
                    try writer.close()
                    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
                }
            })
            XCTFail("Changed source completed inspection")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .sourceChanged) }
    }

    func testCancellationFromFinalAuthorizationCheckCannotPublishIndex() async throws {
        let source = try await fixture(Data(contentsOf: fixtures().appendingPathComponent("48000-2-s24.m4a")))
        let observed = OSAllocatedUnfairLock(initialState: 0)
        _ = try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {
            observed.withLock { $0 += 1 }
        })
        let finalCheck = observed.withLock { $0 }
        XCTAssertGreaterThan(finalCheck, 5)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let operation = Task {
            try await AudioIndexedAlacFile.inspect(reader: source.reader, requireAuthorization: {
                if calls.withLock({ $0 += 1; return $0 }) == finalCheck { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        do { _ = try await operation.value; XCTFail("Final authorization callback cancelled, but an index was published") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.withLock { $0 }, finalCheck)
    }

    private func fixtures() throws -> URL { try XCTUnwrap(Bundle.module.url(forResource: "alac-decoder-v1", withExtension: nil)) }
    private func fixture(_ data: Data) async throws -> (reader: PreparedOutboundFileReadSession, url: URL) {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("audio-alac-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("source.m4a")
        try data.write(to: file, options: .withoutOverwriting)
        let reader = try await PreparedOutboundFileReadSession.prepare(url: file, maximumSize: Int64(data.count),
            sourcePolicy: .ownedSingleLinkStableMetadata, expectedSHA256: Data(SHA256.hash(data: data)))
        addTeardownBlock { try await reader.close(); try FileManager.default.removeItem(at: directory) }
        return (reader, file)
    }
}
