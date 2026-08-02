import CryptoKit
import Foundation
@testable import SkyBridgeProtocolCore
import XCTest

@available(macOS 14.0, iOS 17.0, *)
final class InboundFileTransferIOActorTests: XCTestCase {
    func testDarwinSystemRootAliasCanonicalizationPreservesDeeperSymlinkChecks() throws {
        XCTAssertEqual(
            try DarwinSecurePathPolicy
                .canonicalizingSystemRootAlias(URL(fileURLWithPath: "/var/mobile/container"))
                .path,
            "/private/var/mobile/container"
        )
        XCTAssertEqual(
            try DarwinSecurePathPolicy
                .canonicalizingSystemRootAlias(URL(fileURLWithPath: "/tmp/payload"))
                .path,
            "/private/tmp/payload"
        )
        XCTAssertEqual(
            try DarwinSecurePathPolicy
                .canonicalizingSystemRootAlias(URL(fileURLWithPath: "/various/payload"))
                .path,
            "/various/payload"
        )
    }

    func testMobileContainerTraversalAnchorsAtTrustedContainerWithoutWeakeningDescendants() throws {
        let trustedRoot = URL(
            fileURLWithPath: "/var/mobile/Containers/Data/Application/APP-ID",
            isDirectory: true
        )
        let target = trustedRoot
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)

        let plan = try DarwinSecurePathPolicy.directoryTraversalPlan(
            targetURL: target,
            trustedContainerRootURL: trustedRoot
        )

        XCTAssertEqual(
            plan.anchorURL.path,
            "/private/var/mobile/Containers/Data/Application/APP-ID"
        )
        XCTAssertEqual(plan.relativeComponents, ["Documents", "Downloads"])
        XCTAssertTrue(plan.requiresOwnedAnchor)
    }

    func testMobileContainerTraversalDoesNotAnchorSiblingOrEscapedTarget() throws {
        let trustedRoot = URL(
            fileURLWithPath: "/var/mobile/Containers/Data/Application/APP-ID",
            isDirectory: true
        )
        let sibling = URL(
            fileURLWithPath: "/var/mobile/Containers/Data/Application/OTHER-ID/Documents",
            isDirectory: true
        )
        let escaped = trustedRoot
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("OTHER-ID", isDirectory: true)

        for target in [sibling, escaped] {
            let plan = try DarwinSecurePathPolicy.directoryTraversalPlan(
                targetURL: target,
                trustedContainerRootURL: trustedRoot
            )
            XCTAssertEqual(plan.anchorURL.path, "/")
            XCTAssertFalse(plan.requiresOwnedAnchor)
        }
    }

    func testWriteDigestCommitAndReleasePreserveTwoPhaseLifecycle() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }

        let existingURL = directory.appendingPathComponent("payload.bin")
        try Data("existing".utf8).write(to: existingURL)
        let temporaryURL = directory.appendingPathComponent("payload.partial")
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)

        let handle = try await actor.createTemporaryFile(
            at: temporaryURL,
            declaredFileSize: Int64(payload.count)
        )
        let chunkDigest = try await actor.write(
            payload,
            atOffset: 0,
            using: handle,
            expectedSHA256: Data(SHA256.hash(data: payload))
        )
        XCTAssertEqual(chunkDigest, Data(SHA256.hash(data: payload)))
        let fileDigest = try await actor.closeAndDigest(using: handle)
        XCTAssertEqual(fileDigest, chunkDigest)

        let committedURL = try await actor.commit(
            using: handle,
            destinationDirectory: directory,
            fileName: "payload.bin"
        )
        XCTAssertEqual(committedURL.lastPathComponent, "payload (1).bin")
        XCTAssertEqual(try Data(contentsOf: committedURL), payload)
        let countBeforeRelease = await actor.activeTransferCount()
        XCTAssertEqual(countBeforeRelease, 1)

        try await actor.releaseCommittedFile(using: handle)
        let countAfterRelease = await actor.activeTransferCount()
        XCTAssertEqual(countAfterRelease, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL.path))
    }

    func testWebRTCCancellationNeverRollsBackACommittedFile() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let payload = Data("durable".utf8)
        let handle = try await actor.createTemporaryFile(
            at: directory.appendingPathComponent("durable.partial"),
            declaredFileSize: Int64(payload.count)
        )
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let committedURL = try await actor.commit(
            using: handle,
            destinationDirectory: directory,
            fileName: "durable.bin"
        )

        try await actor.discardUncommittedFile(handle)

        XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL.path))
        XCTAssertEqual(try Data(contentsOf: committedURL), payload)
        let activeTransferCount = await actor.activeTransferCount()
        XCTAssertEqual(activeTransferCount, 0)
    }

    func testCapacityAndBoundsFailClosedWithoutDiscardingAnotherTransfer() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }

        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let firstURL = directory.appendingPathComponent("first.partial")
        let first = try await actor.createTemporaryFile(at: firstURL, declaredFileSize: 4)

        await XCTAssertThrowsErrorAsync(
            try await actor.createTemporaryFile(
                at: directory.appendingPathComponent("second.partial"),
                declaredFileSize: 1
            )
        ) { error in
            XCTAssertEqual(error as? InboundFileTransferIOError, .capacityExceeded)
        }
        await XCTAssertThrowsErrorAsync(
            try await actor.write(Data(repeating: 1, count: 5), atOffset: 0, using: first)
        ) { error in
            XCTAssertEqual(error as? InboundFileTransferIOError, .writeOutOfBounds)
        }

        try await actor.discard(first)
        let activeCount = await actor.activeTransferCount()
        XCTAssertEqual(activeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
    }

    func testCancellationIsExplicitAndDiscardStillClosesResources() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }

        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let temporaryURL = directory.appendingPathComponent("cancel.partial")
        let handle = try await actor.createTemporaryFile(at: temporaryURL, declaredFileSize: 1)
        let gate = InboundFileTransferTestGate()
        let task = Task {
            await gate.wait()
            return try await actor.write(Data([7]), atOffset: 0, using: handle)
        }
        await gate.waitUntilRegistered()
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("A cancelled write must throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try await actor.discard(handle)
        let activeCount = await actor.activeTransferCount()
        XCTAssertEqual(activeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func testSuspendedPartialTerminalCleanupStillRunsFromCancelledTask() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }

        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let temporaryURL = directory.appendingPathComponent("suspended.partial")
        let handle = try await actor.createTemporaryFile(
            at: temporaryURL,
            declaredFileSize: 1
        )
        _ = try await actor.write(Data([7]), atOffset: 0, using: handle)
        try await actor.suspendForResume(handle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryURL.path))

        let cleanupTask = Task {
            await Task.yield()
            try await actor.discardSuspendedPartial(
                at: temporaryURL,
                isolatedDirectory: directory
            )
        }
        cleanupTask.cancel()
        try await cleanupTask.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        let activeCount = await actor.activeTransferCount()
        XCTAssertEqual(activeCount, 0)
    }

    func testDiscardRollsBackCommittedFileBeforeTerminalPublication() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }

        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let temporaryURL = directory.appendingPathComponent("rollback.partial")
        let handle = try await actor.createTemporaryFile(at: temporaryURL, declaredFileSize: 1)
        _ = try await actor.write(Data([1]), atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let committedURL = try await actor.commit(
            using: handle,
            destinationDirectory: directory,
            fileName: "rollback.bin"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL.path))

        try await actor.discard(handle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: committedURL.path))
        let activeCount = await actor.activeTransferCount()
        XCTAssertEqual(activeCount, 0)
    }

    func testResumeRejectsPartialSymlinkWithoutTruncatingExternalTarget() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let externalURL = directory.appendingPathComponent("external.bin")
        let externalData = Data("external-must-not-change".utf8)
        try externalData.write(to: externalURL, options: [.withoutOverwriting])
        let partialURL = directory.appendingPathComponent("resume.partial")
        try FileManager.default.createSymbolicLink(at: partialURL, withDestinationURL: externalURL)

        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        await XCTAssertThrowsErrorAsync(
            try await actor.resumeTemporaryFile(
                at: partialURL,
                isolatedDirectory: directory,
                declaredFileSize: Int64(externalData.count),
                resumeOffset: 1
            )
        ) { error in
            XCTAssertTrue(error is InboundFileTransferIOError)
        }
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
    }

    func testExclusiveCreateRejectsExistingSymlinkWithoutTouchingTarget() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let externalURL = directory.appendingPathComponent("external-create.bin")
        let externalData = Data("external-create".utf8)
        try externalData.write(to: externalURL, options: [.withoutOverwriting])
        let partialURL = directory.appendingPathComponent("create.partial")
        try FileManager.default.createSymbolicLink(at: partialURL, withDestinationURL: externalURL)

        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        await XCTAssertThrowsErrorAsync(
            try await actor.createTemporaryFile(at: partialURL, declaredFileSize: 1)
        ) { error in
            XCTAssertEqual(error as? InboundFileTransferIOError, .temporaryFileAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
    }

    func testExclusiveCreateAllowsOnlyOneConcurrentCreator() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let partialURL = directory.appendingPathComponent("raced.partial")
        let firstActor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let secondActor = InboundFileTransferIOActor(maxOpenTransfers: 1)

        let firstTask = Task { () -> Result<(Int, InboundFileTransferIOHandle), Error> in
            do {
                return .success((0, try await firstActor.createTemporaryFile(
                    at: partialURL,
                    declaredFileSize: 1
                )))
            } catch {
                return .failure(error)
            }
        }
        let secondTask = Task { () -> Result<(Int, InboundFileTransferIOHandle), Error> in
            do {
                return .success((1, try await secondActor.createTemporaryFile(
                    at: partialURL,
                    declaredFileSize: 1
                )))
            } catch {
                return .failure(error)
            }
        }
        let results = await [firstTask.value, secondTask.value]
        let successes = results.compactMap { result -> (Int, InboundFileTransferIOHandle)? in
            if case .success(let value) = result { return value }
            return nil
        }
        let failures = results.compactMap { result -> Error? in
            if case .failure(let error) = result { return error }
            return nil
        }

        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first as? InboundFileTransferIOError, .temporaryFileAlreadyExists)
        if let (owner, handle) = successes.first {
            if owner == 0 {
                try await firstActor.discard(handle)
            } else {
                try await secondActor.discard(handle)
            }
        }
    }

    func testOpenDescriptorHashAndCommitRejectPathIdentitySwap() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let partialURL = directory.appendingPathComponent("swap.partial")
        let displacedURL = directory.appendingPathComponent("displaced.partial")
        let externalURL = directory.appendingPathComponent("external-swap.bin")
        let payload = Data("authenticated-payload".utf8)
        let externalData = Data("external-must-not-be-published".utf8)
        try externalData.write(to: externalURL, options: [.withoutOverwriting])
        let handle = try await actor.createTemporaryFile(
            at: partialURL,
            declaredFileSize: Int64(payload.count)
        )
        _ = try await actor.write(payload, atOffset: 0, using: handle)

        try FileManager.default.moveItem(at: partialURL, to: displacedURL)
        try FileManager.default.createSymbolicLink(at: partialURL, withDestinationURL: externalURL)

        let digest = try await actor.closeAndDigest(using: handle)
        XCTAssertEqual(digest, Data(SHA256.hash(data: payload)))
        await XCTAssertThrowsErrorAsync(
            try await actor.commit(
                using: handle,
                destinationDirectory: directory,
                fileName: "published.bin"
            )
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .moveFailed = ioError else {
                return XCTFail("Expected identity-bound commit rejection, got \(error)")
            }
        }
        await XCTAssertThrowsErrorAsync(try await actor.discard(handle)) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .cleanupFailed = ioError else {
                return XCTFail("Expected identity-bound cleanup rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: externalURL), externalData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("published.bin").path))
    }

    func testSameVolumePreflightAcceptsAtomicCommitDirectories() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let stagingDirectory = directory.appendingPathComponent("staging", isDirectory: true)
        let destinationDirectory = directory.appendingPathComponent("destination", isDirectory: true)
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)

        try await actor.validateSameVolumeCommit(
            stagingURL: stagingDirectory.appendingPathComponent("payload.partial"),
            destinationDirectory: destinationDirectory
        )
    }

    func testCrossVolumePreflightRejectsBeforePayloadReceptionWhenAvailable() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        do {
            try await actor.validateSameVolumeCommit(
                stagingURL: directory.appendingPathComponent("payload.partial"),
                destinationDirectory: URL(fileURLWithPath: "/dev", isDirectory: true)
            )
            throw XCTSkip("/dev is not a distinct file system on this host")
        } catch InboundFileTransferIOError.crossDeviceCommitUnsupported {
            // Expected on standard macOS hosts.
        } catch let skip as XCTSkip {
            throw skip
        } catch {
            throw XCTSkip("A stable second readable volume is unavailable: \(error)")
        }
    }

    func testMaximumLengthCollisionAndSymlinkCandidateRemainSafe() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let fileManager = FileManager.default
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let originalName = String(repeating: "a", count: 251) + ".bin"
        XCTAssertEqual(originalName.utf8.count, 255)
        let existingURL = directory.appendingPathComponent(originalName)
        let existingPayload = Data("existing".utf8)
        try existingPayload.write(to: existingURL, options: [.withoutOverwriting])

        let externalURL = directory.appendingPathComponent("external.bin")
        let externalPayload = Data("external-must-not-change".utf8)
        try externalPayload.write(to: externalURL, options: [.withoutOverwriting])
        let firstCollisionName = String(repeating: "a", count: 247) + " (1).bin"
        XCTAssertEqual(firstCollisionName.utf8.count, 255)
        try fileManager.createSymbolicLink(
            at: directory.appendingPathComponent(firstCollisionName),
            withDestinationURL: externalURL
        )

        let payload = Data("new-authenticated-payload".utf8)
        let temporaryURL = directory.appendingPathComponent("maximum-name.partial")
        let handle = try await actor.createTemporaryFile(
            at: temporaryURL,
            declaredFileSize: Int64(payload.count)
        )
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let committedURL = try await actor.commit(
            using: handle,
            destinationDirectory: directory,
            fileName: originalName
        )

        XCTAssertLessThanOrEqual(committedURL.lastPathComponent.utf8.count, 255)
        XCTAssertNotEqual(committedURL.lastPathComponent, originalName)
        XCTAssertNotEqual(committedURL.lastPathComponent, firstCollisionName)
        XCTAssertEqual(try Data(contentsOf: committedURL), payload)
        XCTAssertEqual(try Data(contentsOf: existingURL), existingPayload)
        XCTAssertEqual(try Data(contentsOf: externalURL), externalPayload)
        try await actor.releaseCommittedFile(using: handle)
    }

    func testReceiversDoNotOwnBlockingFileHandlesOrSynchronousCommitPaths() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/SkyBridgeCore/RemoteConnection/WebRTC/WebRTCInboundFileTransferReceiver.swift"
            ),
            encoding: .utf8
        )
        let iosSource = try String(
            contentsOf: root.appendingPathComponent(
                "SkyBridge Compass iOS/SkyBridgeCompassiOS/Sources/Managers/CrossNetworkWebRTCManager+FileTransfer.swift"
            ),
            encoding: .utf8
        )

        for source in [macSource, iosSource] {
            XCTAssertFalse(source.contains("FileHandle"))
            XCTAssertFalse(source.contains("FileManager.default.moveItem"))
            XCTAssertFalse(source.contains("sha256File"))
            XCTAssertTrue(source.contains("closeAndDigest"))
            XCTAssertTrue(source.contains("releaseCommittedFile"))
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("InboundFileTransferIOActorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private actor InboundFileTransferTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = registrationWaiters
            registrationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRegistered() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            registrationWaiters.append(continuation)
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
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
