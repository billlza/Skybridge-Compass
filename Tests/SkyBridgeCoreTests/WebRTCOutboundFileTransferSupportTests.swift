import CryptoKit
import Darwin
import XCTest
@testable import SkyBridgeCore

final class WebRTCOutboundFileTransferSupportTests: XCTestCase {
    func testWaiterKeyKeepsIdentifiersAndOptionalIndexAsTypedFields() {
        let key = WebRTCOutboundFileTransferSupport.waiterKey(
            sessionID: "session|with-delimiter",
            transferId: "transfer|with-delimiter",
            op: .metadataAck,
            chunkIndex: nil
        )

        XCTAssertEqual(key.sessionID, "session|with-delimiter")
        XCTAssertEqual(key.transferID, "transfer|with-delimiter")
        XCTAssertEqual(key.operation, CrossNetworkFileTransferOp.metadataAck.rawValue)
        XCTAssertNil(key.chunkIndex)
    }

    func testTotalChunksUsesIntegerCeilingAndRepresentsEmptyFiles() {
        let chunkSize = WebRTCOutboundFileTransferSupport.dataChannelChunkSize

        XCTAssertEqual(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: 1), 1)
        XCTAssertEqual(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: Int64(chunkSize)), 1)
        XCTAssertEqual(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: Int64(chunkSize + 1)), 2)
        XCTAssertEqual(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: 0), 0)
        XCTAssertNil(WebRTCOutboundFileTransferSupport.totalChunks(fileSize: 1, chunkSize: 0))
    }

    func testAdaptiveChunkSizingKeepsLargeFilesWithinProtocolChunkLimit() throws {
        let oneGiB: Int64 = 1_024 * 1_024 * 1_024
        let baseChunkSize = WebRTCOutboundFileTransferSupport.dataChannelChunkSize
        let cases: [(
            fileSize: Int64,
            expectedChunkSize: Int,
            expectedTotalChunks: Int
        )] = [
            (0, baseChunkSize, 0),
            (oneGiB, baseChunkSize, 65_536),
            (oneGiB + 1, baseChunkSize * 2, 32_769),
            (2 * oneGiB, baseChunkSize * 2, 65_536)
        ]

        for testCase in cases {
            let selectedChunkSize = try XCTUnwrap(
                WebRTCOutboundFileTransferSupport.dataChannelChunkSize(
                    forFileSize: testCase.fileSize
                )
            )
            let totalChunks = try XCTUnwrap(
                WebRTCOutboundFileTransferSupport.totalChunks(
                    fileSize: testCase.fileSize,
                    chunkSize: selectedChunkSize
                )
            )

            XCTAssertEqual(selectedChunkSize, testCase.expectedChunkSize)
            XCTAssertEqual(selectedChunkSize % baseChunkSize, 0)
            XCTAssertLessThanOrEqual(
                selectedChunkSize,
                WebRTCInboundFileTransferSupport.maxChunkSize
            )
            XCTAssertEqual(totalChunks, testCase.expectedTotalChunks)
            XCTAssertLessThanOrEqual(
                totalChunks,
                WebRTCInboundFileTransferSupport.maxTotalChunks
            )
        }
    }

    func testValidateCompletionAckRequiresExactBytesAndHash() throws {
        let payload = Data("hello".utf8)
        let fileSha = Data(SHA256.hash(data: payload))
        let ack = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: "transfer",
            receivedBytes: Int64(payload.count),
            fileSha256: fileSha
        )

        XCTAssertNoThrow(
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                ack,
                expectedFileSize: Int64(payload.count),
                expectedFileSha256: fileSha
            )
        )

        let wrongBytes = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: "transfer",
            receivedBytes: Int64(payload.count + 1),
            fileSha256: fileSha
        )
        XCTAssertThrowsError(
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                wrongBytes,
                expectedFileSize: Int64(payload.count),
                expectedFileSha256: fileSha
            )
        )

        let wrongHash = CrossNetworkFileTransferMessage(
            op: .completeAck,
            transferId: "transfer",
            receivedBytes: Int64(payload.count),
            fileSha256: Data(SHA256.hash(data: Data("other".utf8)))
        )
        XCTAssertThrowsError(
            try WebRTCOutboundFileTransferSupport.validateCompletionAck(
                wrongHash,
                expectedFileSize: Int64(payload.count),
                expectedFileSha256: fileSha
            )
        )
    }

    func testValidateChunkAckRequiresExactCumulativeBytes() throws {
        let exact = CrossNetworkFileTransferMessage(
            op: .chunkAck,
            transferId: "transfer",
            receivedBytes: 16_384
        )
        XCTAssertNoThrow(
            try WebRTCOutboundFileTransferSupport.validateChunkAck(
                exact,
                expectedReceivedBytes: 16_384
            )
        )

        for invalidValue in [nil, 16_383, 16_385] as [Int64?] {
            let invalid = CrossNetworkFileTransferMessage(
                op: .chunkAck,
                transferId: "transfer",
                receivedBytes: invalidValue
            )
            XCTAssertThrowsError(
                try WebRTCOutboundFileTransferSupport.validateChunkAck(
                    invalid,
                    expectedReceivedBytes: 16_384
                )
            )
        }
    }

    func testCompletionWaitPolicySeparatesAmbiguityFromExplicitFailure() {
        for error in [
            WebRTCFileTransferWaitError.timeout,
            WebRTCFileTransferWaitError.transportClosed("channel closed")
        ] {
            let normalized = WebRTCOutboundFileTransferSupport.normalizedCompletionWaitError(error)
            guard let transferError = normalized as? FileTransferError,
                  case .deliveryConfirmationUnknown = transferError else {
                return XCTFail("Terminal transport ambiguity must be typed as confirmation unknown")
            }
        }

        let rejection = WebRTCFileTransferWaitError.remoteRejected("policy denied")
        let normalizedRejection = WebRTCOutboundFileTransferSupport.normalizedCompletionWaitError(rejection)
        guard let waitError = normalizedRejection as? WebRTCFileTransferWaitError,
              case .remoteRejected(let reason) = waitError else {
            return XCTFail("Explicit receiver rejection must remain deterministic")
        }
        XCTAssertEqual(reason, "policy denied")

        let cancellation = CancellationError()
        let normalizedCancellation = WebRTCOutboundFileTransferSupport
            .normalizedCompletionWaitError(cancellation)
        guard let transferError = normalizedCancellation as? FileTransferError,
              case .deliveryConfirmationUnknown = transferError else {
            return XCTFail("Cancellation during terminal ACK wait is commit ambiguity")
        }
    }

    func testChunkAcknowledgmentRetriesOnlyTimeouts() {
        XCTAssertTrue(
            WebRTCOutboundFileTransferSupport.shouldRetryChunkAcknowledgment(
                after: WebRTCFileTransferWaitError.timeout
            )
        )
        XCTAssertFalse(
            WebRTCOutboundFileTransferSupport.shouldRetryChunkAcknowledgment(
                after: WebRTCFileTransferWaitError.remoteRejected("integrity rejected")
            )
        )
        XCTAssertFalse(
            WebRTCOutboundFileTransferSupport.shouldRetryChunkAcknowledgment(
                after: WebRTCFileTransferWaitError.transportClosed("closed")
            )
        )
        XCTAssertFalse(
            WebRTCOutboundFileTransferSupport.shouldRetryChunkAcknowledgment(
                after: CancellationError()
            )
        )
    }

    func testSecureReaderUsesOneDescriptorAndProducesExactDigest() async throws {
        let fixture = try makeFileFixture(Data((0..<251).map(UInt8.init)))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let reader = try await WebRTCOutboundFileReader.open(url: fixture.file)
        XCTAssertEqual(reader.fileSize, 251)
        let first = try await reader.read(offset: 0, length: 127)
        let second = try await reader.read(offset: 127, length: 124)
        let digest = try await reader.finalizeAndClose()

        XCTAssertEqual(first + second, fixture.payload)
        XCTAssertEqual(digest, Data(SHA256.hash(data: fixture.payload)))
    }

    func testSecureReaderRejectsSymlinkAndHardLink() async throws {
        let fixture = try makeFileFixture(Data("secure".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let symlink = fixture.directory.appendingPathComponent("symlink")
        let hardLink = fixture.directory.appendingPathComponent("hard-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.file)

        await XCTAssertThrowsErrorAsync(
            try await WebRTCOutboundFileReader.open(url: symlink)
        )

        try FileManager.default.linkItem(at: fixture.file, to: hardLink)
        await XCTAssertThrowsErrorAsync(
            try await WebRTCOutboundFileReader.open(url: fixture.file)
        )
    }

    func testReaderDetectsInPlaceMutation() async throws {
        let fixture = try makeFileFixture(Data(repeating: 0x41, count: 64))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let reader = try await WebRTCOutboundFileReader.open(url: fixture.file)

        let mutator = try FileHandle(forWritingTo: fixture.file)
        try mutator.seekToEnd()
        try mutator.write(contentsOf: Data([0x42]))
        try mutator.synchronize()
        try mutator.close()

        await XCTAssertThrowsErrorAsync(
            try await reader.read(offset: 0, length: 16)
        )
        try await reader.close()
    }

    func testReadExactlyAggregatesShortReadsAndRejectsPrematureEOF() throws {
        let fixture = try makeFileFixture(Data("short-read-fixture".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let descriptor = Darwin.open(fixture.file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }

        let aggregated = try WebRTCOutboundFileReader.readExactly(
            descriptor: descriptor,
            offset: 0,
            length: fixture.payload.count,
            readOperation: { descriptor, buffer, count, offset in
                Darwin.pread(descriptor, buffer, min(3, count), offset)
            }
        )
        XCTAssertEqual(aggregated, fixture.payload)

        XCTAssertThrowsError(
            try WebRTCOutboundFileReader.readExactly(
                descriptor: descriptor,
                offset: 0,
                length: fixture.payload.count + 1
            )
        )
    }

    func testReadExactlyObservesCancellationBetweenShortReads() async throws {
        let fixture = try makeFileFixture(Data(repeating: 0x51, count: 32))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let descriptor = Darwin.open(fixture.file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
        let probe = CancellableShortReadProbe()

        let readTask = Task {
            try WebRTCOutboundFileReader.readExactly(
                descriptor: descriptor,
                offset: 0,
                length: 32,
                readOperation: { descriptor, buffer, count, offset in
                    probe.read(descriptor: descriptor, buffer: buffer, count: count, offset: offset)
                }
            )
        }
        XCTAssertEqual(probe.firstReadStarted.wait(timeout: .now() + 2), .success)
        readTask.cancel()
        probe.releaseFirstRead.signal()

        await XCTAssertThrowsErrorAsync(try await readTask.value) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testFileTransferWaitersUseTokenizedCancellationAndCancellationStopsRetries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macWaiterSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift"
            ),
            encoding: .utf8
        )
        let iosWaiterSource = try String(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager+FileTransfer.swift"
            ),
            encoding: .utf8
        )
        let iosSenderSource = try String(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/FileTransferManager.swift"
            ),
            encoding: .utf8
        )

        for source in [macWaiterSource, iosWaiterSource] {
            XCTAssertTrue(source.contains("withTaskCancellationHandler"))
            XCTAssertTrue(source.contains("takeFileTransferWaiter(forKey: key, token: token)"))
            XCTAssertTrue(source.contains("pending.sendTask = sendTask"))
            XCTAssertTrue(source.contains("resume(throwing: CancellationError())"))
        }
        XCTAssertTrue(macWaiterSource.contains("catch is CancellationError"))
        XCTAssertTrue(iosSenderSource.contains("catch is CancellationError"))
    }

    func testOutboundReaderCloseFailuresRemainObservableAndRetryable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let transferSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/CrossNetworkConnectionManager+WebRTCFileTransfer.swift"
            ),
            encoding: .utf8
        )
        let readerSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCOutboundFileTransferSupport.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(transferSource.contains("try? await fileReader?.close()"))
        XCTAssertTrue(transferSource.contains("且本地文件句柄关闭失败"))
        XCTAssertFalse(transferSource.contains("attributesOfItem(atPath: url.path)"))
        XCTAssertFalse(transferSource.contains("ack.receivedBytes ??"))
        XCTAssertTrue(transferSource.contains("expectedReceivedBytes: expectedReceivedBytes"))
        XCTAssertTrue(readerSource.contains("O_RDONLY | O_NOFOLLOW | O_CLOEXEC"))
        XCTAssertTrue(readerSource.contains("fstat(descriptor, &metadata)"))
        XCTAssertTrue(readerSource.contains("metadata.st_ino > 0"))
        XCTAssertTrue(readerSource.contains("Darwin.pread"))
        XCTAssertTrue(readerSource.contains("try handle.close()\n        isClosed = true"))
        XCTAssertFalse(readerSource.contains("isClosed = true\n        try handle.close()"))
    }

    private func makeFileFixture(
        _ payload: Data
    ) throws -> (directory: URL, file: URL, payload: Data) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skybridge-webrtc-outbound-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("payload.bin")
        try payload.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return (directory, file, payload)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private final class CancellableShortReadProbe: @unchecked Sendable {
    let firstReadStarted = DispatchSemaphore(value: 0)
    let releaseFirstRead = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var isFirstRead = true

    func read(
        descriptor: Int32,
        buffer: UnsafeMutableRawPointer,
        count: Int,
        offset: off_t
    ) -> Int {
        lock.lock()
        let shouldBlock = isFirstRead
        isFirstRead = false
        lock.unlock()
        if shouldBlock {
            firstReadStarted.signal()
            releaseFirstRead.wait()
        }
        return Darwin.pread(descriptor, buffer, min(1, count), offset)
    }
}
