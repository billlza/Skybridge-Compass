import Foundation
import XCTest
@testable import SkyBridgeCore

#if os(macOS)
final class WebRTCMediaDiagnosticWriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-webrtc-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testWriterRedactsSessionIdentifierAndCreatesPrivateAppendOnlyFile() throws {
        let event = makeEvent(sessionID: "sensitive-session-id")
        let writer = WebRTCMediaDiagnosticFileWriter(logsRootURL: temporaryDirectory)

        try writer.append(event)
        try writer.append(event)

        let logURL = expectedLogURL(for: event)
        let data = try Data(contentsOf: logURL)
        let lines = data.split(separator: 0x0a)
        XCTAssertEqual(lines.count, 2)

        for line in lines {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            )
            XCTAssertNil(object["session_id"])
            XCTAssertEqual(
                object["session_ref"] as? String,
                WebRTCMediaDiagnosticWriter.safeSessionReference(event.sessionId)
            )
            XCTAssertEqual(object["kind"] as? String, "unit_test")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testWriterRejectsSymlinkedDiagnosticsDirectory() throws {
        let outsideDirectory = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent("SkyBridge", isDirectory: true),
            withDestinationURL: outsideDirectory
        )

        XCTAssertThrowsError(
            try WebRTCMediaDiagnosticFileWriter(logsRootURL: temporaryDirectory)
                .append(makeEvent())
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path).isEmpty)
    }

    func testWriterRejectsHardLinkedOrPubliclyReadableLogFile() throws {
        let event = makeEvent()
        let writer = WebRTCMediaDiagnosticFileWriter(logsRootURL: temporaryDirectory)
        try writer.append(event)
        let logURL = expectedLogURL(for: event)
        let initialData = try Data(contentsOf: logURL)

        let hardLinkURL = temporaryDirectory.appendingPathComponent("diagnostic-hard-link")
        try FileManager.default.linkItem(at: logURL, to: hardLinkURL)
        XCTAssertThrowsError(try writer.append(event)) { error in
            XCTAssertEqual(
                error as? WebRTCMediaDiagnosticWriteError,
                .unsafeFileSystemObject
            )
        }
        XCTAssertEqual(try Data(contentsOf: logURL), initialData)

        try FileManager.default.removeItem(at: hardLinkURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: logURL.path
        )
        XCTAssertThrowsError(try writer.append(event)) { error in
            XCTAssertEqual(
                error as? WebRTCMediaDiagnosticWriteError,
                .unsafeFileSystemObject
            )
        }
        XCTAssertEqual(try Data(contentsOf: logURL), initialData)
    }

    func testWriterRejectsOversizedDiagnosticBeforeTouchingFileSystem() throws {
        let event = WebRTCMediaDiagnosticEvent(
            sessionId: "session",
            kind: "unit_test",
            probable: String(repeating: "x", count: 4 * 1_024 * 1_024)
        )

        XCTAssertThrowsError(
            try WebRTCMediaDiagnosticFileWriter(logsRootURL: temporaryDirectory).append(event)
        ) { error in
            XCTAssertEqual(
                error as? WebRTCMediaDiagnosticWriteError,
                .payloadTooLarge
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory.appendingPathComponent("SkyBridge").path
            )
        )
    }

    func testQueueAppliesCountAndPendingByteBackpressureToEncodedData() {
        let probe = BlockingMediaDiagnosticWriteProbe()
        let queue = WebRTCMediaDiagnosticWriteQueue(
            queue: DispatchQueue(label: "webrtc-media-diagnostic-queue-test"),
            maximumPendingCount: 2,
            maximumPendingBytes: 8,
            writeOperation: { data, safeSessionReference in
                probe.write(data: data, safeSessionReference: safeSessionReference)
            },
            failureHandler: { error in
                probe.recordFailure(error)
            }
        )

        XCTAssertFalse(
            queue.enqueue(
                data: Data(repeating: 0, count: 9),
                safeSessionReference: "ref-0000000000000000"
            )
        )
        XCTAssertFalse(
            queue.enqueue(
                data: Data([0]),
                safeSessionReference: String(repeating: "x", count: 1_024 * 1_024)
            )
        )
        XCTAssertTrue(
            queue.enqueue(
                data: Data(repeating: 1, count: 4),
                safeSessionReference: "ref-0000000000000001"
            )
        )
        XCTAssertEqual(probe.writeStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(
            queue.enqueue(
                data: Data(repeating: 2, count: 4),
                safeSessionReference: "ref-0000000000000002"
            )
        )
        XCTAssertFalse(
            queue.enqueue(
                data: Data([3]),
                safeSessionReference: "ref-0000000000000003"
            )
        )
        let pending = queue.pendingSnapshotForTesting()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.bytes, 8)

        probe.releaseWrites.signal()
        probe.releaseWrites.signal()
        queue.flushForTesting()

        XCTAssertEqual(probe.writeCount, 2)
        XCTAssertEqual(probe.failureCount, 0)
        XCTAssertEqual(queue.pendingSnapshotForTesting().count, 0)
    }

    func testWriterFailsWithinBoundedAttemptsWhenDirectoryLockIsContended() throws {
        let writer = WebRTCMediaDiagnosticFileWriter(
            logsRootURL: temporaryDirectory,
            lockRetryCount: 3,
            lockRetryDelayMicroseconds: 0,
            lockAttempt: { _ in EAGAIN }
        )

        XCTAssertThrowsError(try writer.append(makeEvent())) { error in
            XCTAssertEqual(
                error as? WebRTCMediaDiagnosticWriteError,
                .lockUnavailable
            )
        }

        let logsDirectory = temporaryDirectory.appendingPathComponent("SkyBridge")
        let names = try FileManager.default.contentsOfDirectory(atPath: logsDirectory.path)
        XCTAssertEqual(names, [".webrtc-media.lock"])
    }

    func testWriterRotatesSessionFileBeforeCrossingPerFileLimit() throws {
        let event = makeEvent(sessionID: "rotation-session")
        var encodedLine = try WebRTCMediaDiagnosticWriter.publicDiagnosticJSONData(for: event)
        encodedLine.append(0x0a)
        let maximumFileBytes = encodedLine.count + 1
        let writer = WebRTCMediaDiagnosticFileWriter(
            logsRootURL: temporaryDirectory,
            maximumFileBytes: maximumFileBytes,
            maximumTotalBytes: maximumFileBytes * 4,
            maximumFileCount: 4
        )

        try writer.append(event)
        try writer.append(event)

        let currentURL = expectedLogURL(for: event)
        let rotatedURL = URL(fileURLWithPath: currentURL.path + ".1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotatedURL.path))
        XCTAssertEqual(try Data(contentsOf: currentURL).split(separator: 0x0a).count, 1)
        XCTAssertEqual(try Data(contentsOf: rotatedURL).split(separator: 0x0a).count, 1)
        XCTAssertLessThanOrEqual(try Data(contentsOf: currentURL).count, maximumFileBytes)
        XCTAssertLessThanOrEqual(try Data(contentsOf: rotatedURL).count, maximumFileBytes)
    }

    func testWriterPrunesOldestOwnedLogsToBoundTotalBytesAndFileCount() throws {
        let events = (0..<5).map { makeEvent(sessionID: "retention-session-\($0)") }
        let maximumLineBytes = try events.map { event -> Int in
            var line = try WebRTCMediaDiagnosticWriter.publicDiagnosticJSONData(for: event)
            line.append(0x0a)
            return line.count
        }.max() ?? 1
        let maximumFileBytes = maximumLineBytes + 16
        let maximumTotalBytes = maximumFileBytes * 2
        let writer = WebRTCMediaDiagnosticFileWriter(
            logsRootURL: temporaryDirectory,
            maximumFileBytes: maximumFileBytes,
            maximumTotalBytes: maximumTotalBytes,
            maximumFileCount: 2
        )

        for event in events {
            try writer.append(event)
        }

        let logsDirectory = temporaryDirectory.appendingPathComponent("SkyBridge")
        let retainedURLs = try FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("webrtc-media-ref-")
        }
        let retainedBytes = try retainedURLs.reduce(into: 0) { total, url in
            total += try Data(contentsOf: url).count
        }

        XCTAssertLessThanOrEqual(retainedURLs.count, 2)
        XCTAssertLessThanOrEqual(retainedBytes, maximumTotalBytes)
    }

    func testWriterSourceContractUsesBoundedTryLockAndDeterministicRetention() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/SkyBridgeCore/RemoteDesktop/WebRTCMediaDiagnostics.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("maximumPendingBytes: 1 * 1_024 * 1_024"))
        XCTAssertTrue(source.contains("pendingBytes <= maximumPendingBytes - data.count"))
        XCTAssertTrue(source.contains("F_TLOCK"))
        XCTAssertFalse(source.contains("lockf(descriptor, F_LOCK"))
        XCTAssertTrue(source.contains("maximumLogFileBytes = 8 * 1_024 * 1_024"))
        XCTAssertTrue(source.contains("maximumRetainedBytes = 32 * 1_024 * 1_024"))
        XCTAssertTrue(source.contains("Self.retentionOrder"))
    }

    private func makeEvent(sessionID: String = "session") -> WebRTCMediaDiagnosticEvent {
        WebRTCMediaDiagnosticEvent(
            sessionId: sessionID,
            kind: "unit_test",
            framesSent: 1,
            packetsSent: 2
        )
    }

    private func expectedLogURL(for event: WebRTCMediaDiagnosticEvent) -> URL {
        let filename = "webrtc-media-\(WebRTCMediaDiagnosticWriter.safeSessionReference(event.sessionId)).jsonl"
        return temporaryDirectory
            .appendingPathComponent("SkyBridge", isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class BlockingMediaDiagnosticWriteProbe: @unchecked Sendable {
    let writeStarted = DispatchSemaphore(value: 0)
    let releaseWrites = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writes = 0
    private var failures = 0

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    func write(data: Data, safeSessionReference: String) {
        precondition(!data.isEmpty)
        precondition(!safeSessionReference.isEmpty)
        writeStarted.signal()
        releaseWrites.wait()
        lock.lock()
        writes += 1
        lock.unlock()
    }

    func recordFailure(_ error: Error) {
        _ = error
        lock.lock()
        failures += 1
        lock.unlock()
    }
}
#endif
