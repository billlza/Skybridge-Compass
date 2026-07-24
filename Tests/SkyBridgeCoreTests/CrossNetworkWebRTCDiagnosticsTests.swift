import XCTest
@testable import SkyBridgeCore

final class CrossNetworkWebRTCDiagnosticsTests: XCTestCase {
    func testSanitizeStatusRemovesLineBreaks() {
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.sanitizeStatus("alpha\nbeta\rgamma"),
            "alpha beta gamma"
        )
    }

    func testSanitizeStatusRedactsAdmissionSecretsAndPeerIdentifiers() {
        let raw = #"code 6BJ34VQR status waiting(code: "6BJ34VQR") session=6BJ34VQR sessionId: "6BJ34VQR" deviceId=device-alpha peerId=peer-beta fingerprint=abcdef012345 from=mac-device to=android-device"#
        let sanitized = CrossNetworkWebRTCDiagnostics.sanitizeStatus(raw)

        XCTAssertTrue(sanitized.contains("code <redacted>"))
        XCTAssertTrue(sanitized.contains(#"code: "<redacted>""#))
        XCTAssertTrue(sanitized.contains("session=<redacted>"))
        XCTAssertTrue(sanitized.contains(#"sessionId: "<redacted>""#))
        XCTAssertTrue(sanitized.contains("deviceId=<redacted>"))
        XCTAssertTrue(sanitized.contains("peerId=<redacted>"))
        XCTAssertTrue(sanitized.contains("fingerprint=<redacted>"))
        XCTAssertTrue(sanitized.contains("from=<redacted>"))
        XCTAssertTrue(sanitized.contains("to=<redacted>"))
        XCTAssertFalse(sanitized.contains("6BJ34VQR"))
        XCTAssertFalse(sanitized.contains("device-alpha"))
        XCTAssertFalse(sanitized.contains("peer-beta"))
        XCTAssertFalse(sanitized.contains("abcdef012345"))
    }

    func testDescribeScreenPayloadMagicDetectsKnownFormats() {
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x53, 0x42, 0x50, 0x32, 0x00])),
            "SBP2"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x53, 0x42, 0x52, 0x46, 0x00])),
            "SBRF"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x01, 0x02, 0x03, 0x04])),
            "cipher"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCDiagnostics.describeScreenPayloadMagic(Data([0x01, 0x02, 0x03])),
            "raw"
        )
    }

    func testDiagnosticInputIsBoundedBeforeEnqueueWithoutBreakingUTF8() {
        let oversized = String(repeating: "诊断🙂", count: 30_000)

        let bounded = CrossNetworkWebRTCDiagnostics.boundedDiagnosticInput(oversized)

        XCTAssertLessThanOrEqual(bounded.utf8.count, 48 * 1_024)
        XCTAssertTrue(bounded.hasSuffix(" [truncated]"))
        XCTAssertNotNil(bounded.data(using: .utf8))

        let sanitized = CrossNetworkWebRTCDiagnostics.sanitizeStatus(oversized)
        XCTAssertLessThanOrEqual(sanitized.utf8.count, 48 * 1_024)
        XCTAssertTrue(sanitized.hasSuffix(" [truncated]"))
    }

    func testDiagnosticWriterAppliesHardCountAndByteBackpressure() {
        let probe = BlockingDiagnosticWriteProbe()
        let writer = CrossNetworkWebRTCDiagnosticWriter(
            queue: DispatchQueue(label: "diagnostic-writer-backpressure-test"),
            maximumPendingCount: 2,
            maximumPendingBytes: 8,
            writeOperation: { data, _, _ in
                probe.write(data)
            },
            failureHandler: { _, error in
                probe.recordFailure(error)
            }
        )
        let destination = URL(fileURLWithPath: "/tmp/diagnostic-writer-test")

        XCTAssertFalse(writer.enqueue(data: Data(repeating: 0, count: 9), url: destination, label: "oversized"))
        XCTAssertTrue(writer.enqueue(data: Data(repeating: 1, count: 4), url: destination, label: "one"))
        XCTAssertEqual(probe.writeStarted.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(writer.enqueue(data: Data(repeating: 2, count: 4), url: destination, label: "two"))
        XCTAssertFalse(writer.enqueue(data: Data([3]), url: destination, label: "three"))
        let pending = writer.pendingSnapshotForTesting()
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.bytes, 8)

        probe.releaseWrites.signal()
        probe.releaseWrites.signal()
        writer.flushForTesting()
        XCTAssertEqual(probe.writeCount, 2)
        XCTAssertEqual(probe.failureCount, 0)
        XCTAssertEqual(writer.pendingSnapshotForTesting().count, 0)
    }

    func testDiagnosticWriterReportsWriteFailureAndReleasesCapacity() {
        let probe = DiagnosticFailureProbe()
        let writer = CrossNetworkWebRTCDiagnosticWriter(
            queue: DispatchQueue(label: "diagnostic-writer-failure-test"),
            maximumPendingCount: 1,
            maximumPendingBytes: 8,
            writeOperation: { _, _, _ in
                throw CocoaError(.fileWriteUnknown)
            },
            failureHandler: { label, error in
                probe.record(label: label, error: error)
            }
        )

        XCTAssertTrue(
            writer.enqueue(
                data: Data([1]),
                url: URL(fileURLWithPath: "/tmp/diagnostic-writer-failure-test"),
                label: "failure"
            )
        )
        writer.flushForTesting()

        XCTAssertEqual(probe.labels, ["failure"])
        XCTAssertEqual(writer.pendingSnapshotForTesting().count, 0)
    }

    func testDiagnosticWriterUsesBoundedNoFollowOwnerOnlyFileBoundary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/WebRTC/CrossNetworkWebRTCDiagnostics.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("maximumLogByteCount: off_t = 8 * 1_024 * 1_024"))
        XCTAssertTrue(source.contains("maximumEntryByteCount = 64 * 1_024"))
        XCTAssertTrue(source.contains("maximumPendingEntryCount = 128"))
        XCTAssertTrue(source.contains("maximumPendingByteCount = 1 * 1_024 * 1_024"))
        XCTAssertTrue(source.contains("pendingBytes <= maximumPendingBytes - data.count"))
        XCTAssertTrue(source.contains("O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW"))
        XCTAssertTrue(source.contains("metadata.st_uid == geteuid()"))
        XCTAssertTrue(source.contains("metadata.st_nlink == 1"))
        XCTAssertTrue(source.contains("ftruncate(descriptor, 0)"))
        XCTAssertTrue(source.contains("try writeAll(rolloverMarker, to: descriptor)"))
        XCTAssertFalse(source.contains("FileHandle(forWritingTo: url)"))
    }
}

private final class BlockingDiagnosticWriteProbe: @unchecked Sendable {
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

    func write(_ data: Data) {
        precondition(!data.isEmpty)
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

private final class DiagnosticFailureProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLabels: [String] = []

    var labels: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedLabels
    }

    func record(label: String, error: Error) {
        _ = error
        lock.lock()
        recordedLabels.append(label)
        lock.unlock()
    }
}
