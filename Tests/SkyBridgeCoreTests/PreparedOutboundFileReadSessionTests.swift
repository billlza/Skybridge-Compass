import CryptoKit
import Darwin
import Foundation
import SkyBridgeProtocolCore
import XCTest
import os

@MainActor
final class PreparedOutboundFileReadSessionTests: XCTestCase {
    private let blockSize = 256 * 1_024

    func testUnchangedRangesReturnSelectedContentAndDigest() async throws {
        let bytes = Data((0..<(blockSize + 19)).map { UInt8($0 % 251) })
        let fixture = try makeFixture(bytes)
        defer { removeFixture(fixture) }
        let reader = try await prepare(fixture, expected: Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(reader.metadata.fileSize, Int64(bytes.count))
        XCTAssertEqual(reader.metadata.contentSHA256, Data(SHA256.hash(data: bytes)))
        let tail = try await reader.read(offset: UInt64(blockSize - 7), length: 26)
        let head = try await reader.read(offset: 0, length: 113)
        XCTAssertEqual(tail, bytes.suffix(26))
        XCTAssertEqual(head, bytes.prefix(113))
        try await reader.close()
        try await reader.close()
        do {
            _ = try await reader.read(offset: 0, length: 1)
            XCTFail("closed source returned data")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .closed) }
    }

    func testSameLengthInPlaceRewriteReturnsNoChangedBytes() async throws {
        let fixture = try makeFixture(Data(repeating: 0x41, count: 65_536))
        defer { removeFixture(fixture) }
        let reader = try await prepare(fixture)
        try rewrite(fixture.file, offset: 0, bytes: Data(repeating: 0x42, count: 65_536))
        var returned: Data?
        do {
            returned = try await reader.read(offset: 0, length: 65_536)
            XCTFail("mutated bytes escaped before verification")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .contentChanged) }
        XCTAssertNil(returned)
        try await reader.close()
    }

    func testCrossBlockFailureDoesNotReturnEvenItsValidPrefix() async throws {
        let fixture = try makeFixture(Data(repeating: 0x41, count: blockSize * 2))
        defer { removeFixture(fixture) }
        let reader = try await prepare(fixture)
        try rewrite(fixture.file, offset: UInt64(blockSize), bytes: Data(repeating: 0x42, count: blockSize))
        var returned: Data?
        do {
            returned = try await reader.read(offset: UInt64(blockSize - 4), length: 8)
            XCTFail("partially verified read escaped")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .contentChanged) }
        XCTAssertNil(returned)
        let unchanged = try await reader.read(offset: 0, length: 4)
        XCTAssertEqual(unchanged, Data(repeating: 0x41, count: 4))
        try await reader.close()
    }

    func testVerifiedCacheRetainsSelectedBytesAndCannotBeMutatedByCaller() async throws {
        let fixture = try makeFixture(Data(repeating: 0x41, count: blockSize))
        defer { removeFixture(fixture) }
        let reader = try await prepare(fixture)
        var first = try await reader.read(offset: 0, length: 16)
        first[0] = 0x7f
        try rewrite(fixture.file, offset: 0, bytes: Data(repeating: 0x42, count: blockSize))
        let repeated = try await reader.read(offset: 0, length: 32)
        XCTAssertEqual(repeated, Data(repeating: 0x41, count: 32))
        try await reader.close()
    }

    func testPreparationRejectsWrongPriorDigestAndMalformedDigest() async throws {
        let fixture = try makeFixture(Data(repeating: 0x41, count: 128))
        defer { removeFixture(fixture) }
        for (digest, expected) in [(Data(repeating: 0, count: 32), PreparedOutboundFileReadError.contentChanged),
                                   (Data(repeating: 0, count: 31), .invalidExpectedDigest)] {
            do {
                let reader = try await prepare(fixture, expected: digest)
                try await reader.close()
                XCTFail("invalid prior commitment admitted")
            } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, expected) }
        }
        XCTAssertEqual(openDescriptorCount(for: fixture.file), 0)
    }

    func testHeldDescriptorDoesNotFollowPathReplacement() async throws {
        let selected = Data(repeating: 0x41, count: 128)
        let fixture = try makeFixture(selected)
        defer { removeFixture(fixture) }
        let reader = try await prepare(fixture)
        try FileManager.default.moveItem(at: fixture.file, to: fixture.directory.appendingPathComponent("original"))
        try Data(repeating: 0x42, count: 128).write(to: fixture.file, options: .withoutOverwriting)
        let returned = try await reader.read(offset: 0, length: 128)
        XCTAssertEqual(returned, selected)
        try await reader.close()
    }

    func testSymlinkAndStrictHardLinkPoliciesArePreserved() async throws {
        let fixture = try makeFixture(Data([0x41]))
        defer { removeFixture(fixture) }
        let symbolic = fixture.directory.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: fixture.file)
        do {
            let reader = try await PreparedOutboundFileReadSession.prepare(
                url: symbolic, maximumSize: 1, sourcePolicy: .regularFile)
            try await reader.close()
            XCTFail("symlink followed")
        } catch {
            guard case .openFailed = error as? PreparedOutboundFileReadError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        try FileManager.default.linkItem(at: fixture.file, to: fixture.directory.appendingPathComponent("hard"))
        do {
            let reader = try await PreparedOutboundFileReadSession.prepare(
                url: fixture.file, maximumSize: 1, sourcePolicy: .ownedSingleLinkStableMetadata)
            try await reader.close()
            XCTFail("strict source accepted a hard link")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .sourceChanged) }
    }

    func testEmptyFileAndCapacityBounds() async throws {
        let fixture = try makeFixture(Data())
        defer { removeFixture(fixture) }
        let reader = try await PreparedOutboundFileReadSession.prepare(
            url: fixture.file, maximumSize: 0, sourcePolicy: .regularFile)
        XCTAssertEqual(reader.metadata.fileSize, 0)
        XCTAssertEqual(reader.metadata.contentSHA256, Data(SHA256.hash(data: Data())))
        do {
            _ = try await reader.read(offset: 0, length: 1)
            XCTFail("empty file returned bytes")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .invalidBounds) }
        try await reader.close()
        do {
            let invalid = try await PreparedOutboundFileReadSession.prepare(
                url: fixture.file, maximumSize: Int64.max, sourcePolicy: .regularFile)
            try await invalid.close()
            XCTFail("unbounded preparation admitted")
        } catch { XCTAssertEqual(error as? PreparedOutboundFileReadError, .invalidBounds) }
    }

    func testCancellationDuringPreparationClosesHeldDescriptor() async throws {
        let fixture = try makeFixture(Data(repeating: 0x41, count: blockSize * 2))
        defer { removeFixture(fixture) }
        let barrier = PreparationBarrier()
        let task = Task {
            try await PreparedOutboundFileReadSession.prepare(
                url: fixture.file, maximumSize: Int64(blockSize * 2), sourcePolicy: .regularFile,
                validateLifetime: { await barrier.checkpoint() })
        }
        await barrier.waitUntilPaused()
        XCTAssertEqual(openDescriptorCount(for: fixture.file), 1)
        task.cancel()
        await barrier.release()
        do {
            let reader = try await task.value
            try await reader.close()
            XCTFail("cancelled preparation returned a reader")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(openDescriptorCount(for: fixture.file), 0)
    }

    func testPOSIXReadAggregatesShortReadsAndEINTRButRejectsEOFAndInvalidCount() throws {
        let bytes = Data("partial-read-fixture".utf8)
        let fixture = try makeFixture(bytes)
        defer { removeFixture(fixture) }
        let descriptor = Darwin.open(fixture.file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let result = try PreparedOutboundFileReadSession.readExactly(
            descriptor, offset: 0, length: bytes.count,
            readOperation: { fd, buffer, count, offset in
                let first = calls.withLock { value in value += 1; return value == 1 }
                if first { errno = EINTR; return -1 }
                return Darwin.pread(fd, buffer, min(3, count), offset)
            })
        XCTAssertEqual(result, bytes)
        XCTAssertThrowsError(try PreparedOutboundFileReadSession.readExactly(
            descriptor, offset: 0, length: bytes.count + 1)) { error in
                XCTAssertEqual(error as? PreparedOutboundFileReadError, .unexpectedEndOfFile)
            }
        XCTAssertThrowsError(try PreparedOutboundFileReadSession.readExactly(
            descriptor, offset: 0, length: 1, readOperation: { _, _, count, _ in count + 1 })) { error in
                XCTAssertEqual(error as? PreparedOutboundFileReadError, .readFailed(EINVAL))
            }
    }

    private struct Fixture: Sendable { let directory: URL; let file: URL }
    private func makeFixture(_ bytes: Data) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("prepared-outbound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("source.bin")
        try bytes.write(to: file, options: .withoutOverwriting)
        return Fixture(directory: directory, file: file)
    }
    private func removeFixture(_ fixture: Fixture) {
        XCTAssertNoThrow(try FileManager.default.removeItem(at: fixture.directory))
    }
    private func prepare(_ fixture: Fixture, expected: Data? = nil) async throws -> PreparedOutboundFileReadSession {
        try await PreparedOutboundFileReadSession.prepare(url: fixture.file,
            maximumSize: 2 * 1_024 * 1_024, sourcePolicy: .regularFile, expectedSHA256: expected)
    }
    private func rewrite(_ file: URL, offset: UInt64, bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
        } catch {
            let operation = error
            do { try handle.close() } catch { throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: operation, "close": String(describing: error)]) }
            throw operation
        }
        try handle.close()
    }
    private func openDescriptorCount(for file: URL) -> Int {
        var expected = stat()
        guard lstat(file.path, &expected) == 0 else {
            XCTFail("fixture identity unavailable: errno=\(errno)")
            return -1
        }
        return (0..<getdtablesize()).reduce(0) { count, descriptor in
            var actual = stat()
            guard fstat(descriptor, &actual) == 0 else { return count }
            return count + (actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino ? 1 : 0)
        }
    }
}

private actor PreparationBarrier {
    private var calls = 0
    private var paused = false
    private var observer: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    func checkpoint() async {
        calls += 1
        guard calls == 2 else { return }
        paused = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { resume = $0 }
    }
    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { resume?.resume(); resume = nil }
}
