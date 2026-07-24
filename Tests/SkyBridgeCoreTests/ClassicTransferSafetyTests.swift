import CryptoKit
import Foundation
import SkyBridgeProtocolCore
import XCTest

final class ClassicTransferSafetyTests: XCTestCase {
    func testCanonicalTranscriptsMatchFixedV2HexVectors() throws {
        let metadata = try ClassicTransferCanonicalTranscript.metadata(
            transferID: "t",
            fileName: "f",
            fileSize: 0,
            fileHash: String(repeating: "a", count: 64),
            chunkSize: 65_536,
            securityVersion: 2,
            compression: nil,
            senderDeviceID: nil,
            senderDeviceName: nil,
            senderPlatform: nil,
            senderOSVersion: nil,
            senderModelName: nil,
            senderChip: nil
        )
        let receipt = try ClassicTransferCanonicalTranscript.receipt(
            transferID: "t",
            success: true,
            receivedBytes: 0,
            fileHash: nil,
            error: nil,
            securityVersion: 2
        )
        let resume = try ClassicTransferCanonicalTranscript.resumeRequest(
            transferID: "t",
            senderDeviceID: "d",
            resumeOffset: 0,
            securityVersion: 2
        )
        let acknowledgment = try ClassicTransferCanonicalTranscript.resumeAcknowledgment(
            transferID: "t",
            accepted: true,
            resumeOffset: 0,
            error: nil,
            securityVersion: 2
        )

        XCTAssertEqual(Self.hex(metadata), "536b79427269646765436c61737369635472616e73666572000100000002000c000b7472616e736665725f696401000000000000000174000966696c655f6e616d6501000000000000000166000966696c655f73697a6501000000000000000130000966696c655f6861736801000000000000004061616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161000a6368756e6b5f73697a650100000000000000053635353336000b636f6d7072657373696f6e000000000000000000001073656e6465725f6465766963655f6964000000000000000000001273656e6465725f6465766963655f6e616d65000000000000000000000f73656e6465725f706c6174666f726d000000000000000000001173656e6465725f6f735f76657273696f6e000000000000000000001173656e6465725f6d6f64656c5f6e616d65000000000000000000000b73656e6465725f63686970000000000000000000")
        XCTAssertEqual(Self.hex(receipt), "536b79427269646765436c61737369635472616e736665720002000000020005000b7472616e736665725f69640100000000000000017400077375636365737301000000000000000131000e72656365697665645f627974657301000000000000000130000966696c655f6861736800000000000000000000056572726f72000000000000000000")
        XCTAssertEqual(Self.hex(resume), "536b79427269646765436c61737369635472616e736665720003000000020003000b7472616e736665725f696401000000000000000174001073656e6465725f6465766963655f696401000000000000000164000d726573756d655f6f666673657401000000000000000130")
        XCTAssertEqual(Self.hex(acknowledgment), "536b79427269646765436c61737369635472616e736665720004000000020004000b7472616e736665725f6964010000000000000001740008616363657074656401000000000000000131000d726573756d655f6f66667365740100000000000000013000056572726f72000000000000000000")
    }

    func testCanonicalTranscriptsSeparatePurposeNilEmptyAndRejectEveryNonV2Version() throws {
        let nilError = try ClassicTransferCanonicalTranscript.receipt(
            transferID: "t", success: false, receivedBytes: 0,
            fileHash: nil, error: nil, securityVersion: 2
        )
        let emptyError = try ClassicTransferCanonicalTranscript.receipt(
            transferID: "t", success: false, receivedBytes: 0,
            fileHash: nil, error: "", securityVersion: 2
        )
        let resume = try ClassicTransferCanonicalTranscript.resumeRequest(
            transferID: "t", senderDeviceID: "d", resumeOffset: 0, securityVersion: 2
        )
        XCTAssertNotEqual(nilError, emptyError)
        XCTAssertNotEqual(nilError, resume)

        for version in [-1, 0, 1, 3, Int.max] {
            XCTAssertThrowsError(
                try ClassicTransferCanonicalTranscript.receipt(
                    transferID: "t", success: true, receivedBytes: 0,
                    fileHash: nil, error: nil, securityVersion: version
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClassicTransferMetadataContractError,
                    .unsupportedSecurityVersion
                )
            }
        }
    }

    func testMetadataContractRejectsHashCaseSlashConfusablesBidiAndBounds() throws {
        XCTAssertNoThrow(try ClassicTransferMetadataContract.validateFileName("report.txt"))
        for name in [
            "a/b", "a\\b", "a\u{2044}b", "a\u{2215}b", "a\u{29F8}b",
            "a\u{29F5}b", "a\u{29F9}b", "a\u{FE68}b", "a\u{FF0F}b",
            "a\u{FF3C}b", "a\u{202E}b", "a\n"
        ] {
            XCTAssertThrowsError(try ClassicTransferMetadataContract.validateFileName(name))
        }
        XCTAssertNoThrow(
            try ClassicTransferMetadataContract.validateSHA256Hex(String(repeating: "a", count: 64))
        )
        XCTAssertThrowsError(
            try ClassicTransferMetadataContract.validateSHA256Hex(String(repeating: "A", count: 64))
        )
        XCTAssertThrowsError(
            try ClassicTransferMetadataContract.validate(
                transferID: "t", fileName: "f", fileSize: 2_147_483_649,
                fileHash: String(repeating: "a", count: 64), declaredChunkSize: 65_536,
                compression: nil
            )
        )
    }

    func testResumeAcknowledgmentContractRejectsUnsafeOffsets() throws {
        let chunkSize = 65_536
        XCTAssertNoThrow(
            try ClassicTransferResumeAcknowledgmentContract.validate(
                acceptedOffset: 65_536,
                requestedOffset: 131_072,
                fileSize: 150_000,
                declaredChunkSize: chunkSize
            )
        )
        XCTAssertNoThrow(
            try ClassicTransferResumeAcknowledgmentContract.validate(
                acceptedOffset: 150_000,
                requestedOffset: 150_000,
                fileSize: 150_000,
                declaredChunkSize: chunkSize
            )
        )

        let invalidAcceptedOffsets: [(Int64, ClassicTransferResumeAcknowledgmentContractError)] = [
            (-1, .invalidAcceptedOffset),
            (131_073, .invalidAcceptedOffset),
            (196_608, .invalidAcceptedOffset),
            (1, .invalidAcceptedOffset)
        ]
        for (acceptedOffset, expectedError) in invalidAcceptedOffsets {
            XCTAssertThrowsError(
                try ClassicTransferResumeAcknowledgmentContract.validate(
                    acceptedOffset: acceptedOffset,
                    requestedOffset: 131_072,
                    fileSize: 150_000,
                    declaredChunkSize: chunkSize
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClassicTransferResumeAcknowledgmentContractError,
                    expectedError
                )
            }
        }

        for requestedOffset in [-1, 150_001, 1] as [Int64] {
            XCTAssertThrowsError(
                try ClassicTransferResumeAcknowledgmentContract.validate(
                    acceptedOffset: 0,
                    requestedOffset: requestedOffset,
                    fileSize: 150_000,
                    declaredChunkSize: chunkSize
                )
            ) { error in
                XCTAssertEqual(
                    error as? ClassicTransferResumeAcknowledgmentContractError,
                    .invalidRequestedOffset
                )
            }
        }
    }

    func testHMACSHA256AndSuccessfulReceiptHashContractsFailClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let payload = Data("authenticated-payload".utf8)
        let tag = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key))
        XCTAssertTrue(
            ClassicTransferAuthenticationContract.isValidHMACSHA256(
                tag,
                authenticating: payload,
                using: key
            )
        )
        XCTAssertFalse(
            ClassicTransferAuthenticationContract.isValidHMACSHA256(
                nil,
                authenticating: payload,
                using: key
            )
        )
        for invalidTag in [Data(tag.prefix(31)), tag + Data([0])] {
            XCTAssertFalse(
                ClassicTransferAuthenticationContract.isValidHMACSHA256(
                    invalidTag,
                    authenticating: payload,
                    using: key
                )
            )
        }
        var tamperedTag = tag
        tamperedTag[tamperedTag.startIndex] ^= 0x01
        XCTAssertFalse(
            ClassicTransferAuthenticationContract.isValidHMACSHA256(
                tamperedTag,
                authenticating: payload,
                using: key
            )
        )

        let expectedHash = String(repeating: "a", count: 64)
        XCTAssertNoThrow(
            try ClassicTransferReceiptContract.validateSuccessfulFileHash(
                expectedHash,
                expected: expectedHash
            )
        )
        for receivedHash in [nil, "", String(repeating: "b", count: 64)] as [String?] {
            XCTAssertThrowsError(
                try ClassicTransferReceiptContract.validateSuccessfulFileHash(
                    receivedHash,
                    expected: expectedHash
                )
            )
        }
        XCTAssertThrowsError(
            try ClassicTransferReceiptContract.validateSuccessfulFileHash(
                expectedHash,
                expected: nil
            )
        )
    }

    func testReceiveOperationCompletesExactlyOnceAndIgnoresLateCallbacks() async {
        let operation = ClassicTransferReceiveOperation(expectedLength: 4)
        XCTAssertEqual(operation.append(Data([1, 2])), .pending)
        XCTAssertTrue(operation.fail(ClassicTransferTestError.failed))
        XCTAssertFalse(operation.fail(ClassicTransferTestError.failed))
        XCTAssertEqual(operation.append(Data([3, 4])), .ignoredAfterCompletion)
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
            }
            XCTFail("The installed continuation must receive the stored failure")
        } catch let error as ClassicTransferTestError {
            XCTAssertEqual(error, .failed)
        } catch {
            XCTFail("Unexpected receive operation error: \(error)")
        }
    }

    func testReceiveOperationCoversZeroEarlyLateOverflowAndConcurrentFailure() async throws {
        let zero = ClassicTransferReceiveOperation(expectedLength: 0)
        let zeroData: Data = try await withCheckedThrowingContinuation { continuation in
            zero.install(continuation)
        }
        XCTAssertEqual(zeroData, Data())

        let early = ClassicTransferReceiveOperation(expectedLength: 2)
        XCTAssertEqual(early.append(Data([1, 2])), .completed)
        let earlyData: Data = try await withCheckedThrowingContinuation { continuation in
            early.install(continuation)
        }
        XCTAssertEqual(earlyData, Data([1, 2]))

        let afterInstall = ClassicTransferReceiveOperation(expectedLength: 2)
        let afterInstallData: Data = try await withCheckedThrowingContinuation { continuation in
            afterInstall.install(continuation)
            XCTAssertEqual(afterInstall.append(Data([3, 4])), .completed)
        }
        XCTAssertEqual(afterInstallData, Data([3, 4]))

        let overflow = ClassicTransferReceiveOperation(expectedLength: 2)
        XCTAssertEqual(overflow.append(Data([1, 2, 3])), .overflow)
        XCTAssertEqual(overflow.receivedByteCount, 0)
        XCTAssertTrue(overflow.fail(ClassicTransferTestError.failed))

        let racing = ClassicTransferReceiveOperation(expectedLength: 4)
        let winningCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<64 {
                group.addTask {
                    racing.fail(index.isMultiple(of: 2) ?
                        ClassicTransferTestError.timeout :
                        ClassicTransferTestError.cancelled)
                }
            }
            var winners = 0
            for await won in group where won {
                winners += 1
            }
            return winners
        }
        XCTAssertEqual(winningCount, 1)
        XCTAssertEqual(racing.append(Data([1, 2, 3, 4])), .ignoredAfterCompletion)
    }

    func testSendOperationTerminalRaceCompletesExactlyOnceAndIgnoresLateCallbacks() async throws {
        let earlySuccess = ClassicTransferSendOperation()
        XCTAssertTrue(earlySuccess.succeed())
        try await withCheckedThrowingContinuation { continuation in
            earlySuccess.install(continuation)
        }
        XCTAssertFalse(earlySuccess.succeed())
        XCTAssertFalse(earlySuccess.fail(ClassicTransferTestError.failed))

        let failureAfterInstall = ClassicTransferSendOperation()
        do {
            try await withCheckedThrowingContinuation { continuation in
                failureAfterInstall.install(continuation)
                XCTAssertTrue(failureAfterInstall.fail(ClassicTransferTestError.failed))
            }
            XCTFail("Failure after continuation install must throw")
        } catch let error as ClassicTransferTestError {
            XCTAssertEqual(error, .failed)
        }

        let racing = ClassicTransferSendOperation()
        let winningCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for index in 0..<96 {
                group.addTask {
                    switch index % 3 {
                    case 0:
                        return racing.succeed()
                    case 1:
                        return racing.fail(ClassicTransferTestError.timeout)
                    default:
                        return racing.fail(ClassicTransferTestError.cancelled)
                    }
                }
            }
            var winners = 0
            for await won in group where won {
                winners += 1
            }
            return winners
        }
        XCTAssertEqual(winningCount, 1)
        XCTAssertFalse(racing.succeed())
        XCTAssertFalse(racing.fail(ClassicTransferTestError.failed))
        do {
            try await withCheckedThrowingContinuation { continuation in
                racing.install(continuation)
            }
        } catch let error as ClassicTransferTestError {
            XCTAssertTrue(error == .timeout || error == .cancelled)
        }
    }

    func testSlotPolicyBoundsFIFOAndCancellation() {
        var policy = ClassicTransferSlotQueuePolicy()
        let active = UUID()
        let cancelled = UUID()
        let resumed = UUID()
        XCTAssertEqual(policy.request(identifier: active, configuredLimit: 1), .acquired)
        XCTAssertEqual(
            policy.request(identifier: cancelled, configuredLimit: 1, maximumPending: 1),
            .queued
        )
        XCTAssertEqual(
            policy.request(identifier: resumed, configuredLimit: 1, maximumPending: 1),
            .capacityExceeded
        )
        XCTAssertTrue(policy.cancelPending(identifier: cancelled))
        XCTAssertEqual(
            policy.request(identifier: resumed, configuredLimit: 1, maximumPending: 1),
            .queued
        )
        XCTAssertEqual(policy.release(configuredLimit: 1), [resumed])
        XCTAssertEqual(policy.inFlightCount, 1)
        XCTAssertEqual(policy.pendingCount, 0)
        XCTAssertEqual(policy.release(configuredLimit: 1), [])
        XCTAssertEqual(policy.inFlightCount, 0)

        var fifo = ClassicTransferSlotQueuePolicy()
        let first = UUID()
        let second = UUID()
        let cancelledMiddle = UUID()
        let fourth = UUID()
        XCTAssertEqual(fifo.request(identifier: first, configuredLimit: 1), .acquired)
        XCTAssertEqual(fifo.request(identifier: second, configuredLimit: 1), .queued)
        XCTAssertEqual(fifo.request(identifier: cancelledMiddle, configuredLimit: 1), .queued)
        XCTAssertEqual(fifo.request(identifier: fourth, configuredLimit: 1), .queued)
        XCTAssertTrue(fifo.cancelPending(identifier: cancelledMiddle))
        XCTAssertEqual(fifo.drain(configuredLimit: 3), [second, fourth])
    }

    func testSlotPolicyCancelsEveryPendingRequestWithoutReleasingInFlightSlots() {
        var policy = ClassicTransferSlotQueuePolicy()
        let active = UUID()
        let firstPending = UUID()
        let secondPending = UUID()

        XCTAssertEqual(policy.request(identifier: active, configuredLimit: 1), .acquired)
        XCTAssertEqual(policy.request(identifier: firstPending, configuredLimit: 1), .queued)
        XCTAssertEqual(policy.request(identifier: secondPending, configuredLimit: 1), .queued)

        XCTAssertEqual(policy.cancelAllPending(), [firstPending, secondPending])
        XCTAssertEqual(policy.pendingCount, 0)
        XCTAssertEqual(policy.inFlightCount, 1)
        XCTAssertEqual(policy.cancelAllPending(), [])
        XCTAssertEqual(policy.release(configuredLimit: 1), [])
        XCTAssertEqual(policy.inFlightCount, 0)
    }

    func testChunkCryptoAndJSONWorkersEnforceBoundsAndAuthentication() async throws {
        let key = SymmetricKey(size: .bits256)
        let payload = Data("payload".utf8)
        let sealed = try await ClassicTransferChunkCryptoWorker.shared.sealAndHash(
            payload: payload,
            plaintextChunk: payload,
            using: key,
            maximumPayloadSize: payload.count,
            maximumPlaintextChunkSize: payload.count
        )
        let openedPayload = try await ClassicTransferChunkCryptoWorker.shared.open(
            ciphertext: sealed.ciphertext, nonce: sealed.nonce, tag: sealed.tag,
            using: key, maximumCiphertextSize: sealed.ciphertext.count
        )
        XCTAssertEqual(openedPayload, payload)
        var tamperedTag = sealed.tag
        tamperedTag[tamperedTag.startIndex] ^= 0x01
        await XCTAssertThrowsErrorAsync(
            try await ClassicTransferChunkCryptoWorker.shared.open(
                ciphertext: sealed.ciphertext, nonce: sealed.nonce, tag: tamperedTag,
                using: key, maximumCiphertextSize: sealed.ciphertext.count
            )
        ) { error in
            XCTAssertEqual(error as? ClassicTransferChunkCryptoError, .authenticationFailed)
        }
        await XCTAssertThrowsErrorAsync(
            try await ClassicTransferJSONWorker.shared.encode(
                ClassicTransferJSONProbe(value: String(repeating: "x", count: 128)),
                maximumOutputSize: 8
            )
        ) { error in
            XCTAssertEqual(error as? ClassicTransferJSONCodecError, .outputLimitExceeded)
        }
        await XCTAssertThrowsErrorAsync(
            try await ClassicTransferJSONWorker.shared.decode(
                ClassicTransferJSONProbe.self,
                from: Data(repeating: 0x41, count: 9),
                maximumInputSize: 8
            )
        ) { error in
            XCTAssertEqual(error as? ClassicTransferJSONCodecError, .inputLimitExceeded)
        }
    }

    func testOutboundReaderRejectsSymlinkDetectsSizeChangeAndReturnsExactDigest() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: directory)) }
        let fileURL = directory.appendingPathComponent("source.bin")
        let payload = Data((0..<1024).map { UInt8($0 % 251) })
        try payload.write(to: fileURL, options: [.withoutOverwriting])

        let reader = try await ClassicTransferOutboundFileReadSession.open(
            url: fileURL,
            tracksSHA256: true
        )
        let firstChunk = try await reader.read(offset: 0, length: 512)
        let secondChunk = try await reader.read(offset: 512, length: 512)
        let digest = try await reader.finalizeAndClose()
        XCTAssertEqual(firstChunk, Data(payload.prefix(512)))
        XCTAssertEqual(secondChunk, Data(payload.suffix(512)))
        XCTAssertEqual(digest, Data(SHA256.hash(data: payload)))
        await XCTAssertThrowsErrorAsync(try await reader.read(offset: 0, length: 1)) { error in
            XCTAssertEqual(error as? ClassicTransferOutboundFileReadError, .closed)
        }

        let symlinkURL = directory.appendingPathComponent("source-link.bin")
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)
        await XCTAssertThrowsErrorAsync(
            try await ClassicTransferOutboundFileReadSession.open(
                url: symlinkURL,
                tracksSHA256: false
            )
        ) { error in
            XCTAssertEqual(error as? ClassicTransferOutboundFileReadError, .openFailed)
        }

        let changingReader = try await ClassicTransferOutboundFileReadSession.open(
            url: fileURL,
            tracksSHA256: false
        )
        let writeHandle = try FileHandle(forWritingTo: fileURL)
        try writeHandle.seekToEnd()
        try writeHandle.write(contentsOf: Data([7]))
        try writeHandle.close()
        await XCTAssertThrowsErrorAsync(
            try await changingReader.read(offset: 0, length: 1)
        ) { error in
            XCTAssertEqual(error as? ClassicTransferOutboundFileReadError, .readFailed)
        }
        try await changingReader.close()
    }

    func testOutboundReaderDigestDetectsSameSizeMutation() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { XCTAssertNoThrow(try fileManager.removeItem(at: directory)) }
        let fileURL = directory.appendingPathComponent("same-size.bin")
        let original = Data(repeating: 0x11, count: 1_024)
        try original.write(to: fileURL, options: [.withoutOverwriting])
        let originalDigest = Data(SHA256.hash(data: original))

        let reader = try await ClassicTransferOutboundFileReadSession.open(
            url: fileURL,
            tracksSHA256: true
        )
        _ = try await reader.read(offset: 0, length: 512)
        let writer = try FileHandle(forWritingTo: fileURL)
        try writer.seek(toOffset: 512)
        try writer.write(contentsOf: Data(repeating: 0x22, count: 512))
        try writer.synchronize()
        try writer.close()
        _ = try await reader.read(offset: 512, length: 512)
        let mutatedDigest = try await reader.finalizeAndClose()

        XCTAssertNotEqual(mutatedDigest, originalDigest)
        XCTAssertEqual(mutatedDigest, Data(SHA256.hash(data: try Data(contentsOf: fileURL))))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private enum ClassicTransferTestError: Error, Equatable {
    case failed
    case timeout
    case cancelled
}

private struct ClassicTransferJSONProbe: Codable, Sendable {
    let value: String
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
