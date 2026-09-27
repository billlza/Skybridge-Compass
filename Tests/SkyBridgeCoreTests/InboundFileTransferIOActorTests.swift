import CryptoKit
import Foundation
@testable import SkyBridgeProtocolCore
import XCTest

@available(macOS 14.0, iOS 17.0, *)
final class InboundFileTransferIOActorTests: XCTestCase {
    func testCopiedHandleRevocationPreventsPublicationWithoutRevokingAnotherTransfer() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 2)
        let payload = Data("publication ownership".utf8)
        let revoked = try await actor.createTemporaryFile(
            at: directory.appendingPathComponent("revoked.partial"), declaredFileSize: Int64(payload.count))
        let surviving = try await actor.createTemporaryFile(
            at: directory.appendingPathComponent("surviving.partial"), declaredFileSize: Int64(payload.count))
        for handle in [revoked, surviving] {
            _ = try await actor.write(payload, atOffset: 0, using: handle)
            _ = try await actor.closeAndDigest(using: handle)
        }
        let copiedHandle = revoked
        copiedHandle.revokePublication()
        copiedHandle.revokePublication()
        await XCTAssertThrowsErrorAsync(try await actor.commit(
            using: revoked, destinationDirectory: directory, fileName: "revoked.bin")) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("revoked.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("revoked.partial").path))
        let committed = try await actor.commit(
            using: surviving, destinationDirectory: directory, fileName: "surviving.bin")
        XCTAssertEqual(try Data(contentsOf: committed), payload)
        try await actor.discardUncommittedFile(revoked)
        try await actor.releaseCommittedFile(using: surviving)
        let count = await actor.activeTransferCount()
        XCTAssertEqual(count, 0)
    }

    func testRevocationAfterPublicationDoesNotRollBackDurableCommit() async throws {
        let directory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: directory)) }
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let payload = Data("already published".utf8)
        let handle = try await actor.createTemporaryFile(
            at: directory.appendingPathComponent("payload.partial"), declaredFileSize: Int64(payload.count))
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let committed = try await actor.commit(
            using: handle, destinationDirectory: directory, fileName: "payload.bin")
        handle.revokePublication()
        try await actor.discardUncommittedFile(handle)
        XCTAssertEqual(try Data(contentsOf: committed), payload)
        let count = await actor.activeTransferCount()
        XCTAssertEqual(count, 0)
    }

    func testPreparedDestinationCapacityFollowsActualTransferOwnership() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        var target: InboundFileTransferDestinationCapability? = try await actor.prepareDestinationDirectory(at: root)
        weak let heldTarget = target
        let originalScope = try XCTUnwrap(target).scopeDigest
        await XCTAssertThrowsErrorAsync(try await actor.prepareDestinationDirectory(at: root)) {
            XCTAssertEqual($0 as? InboundFileTransferIOError, .capacityExceeded)
        }
        let temporary = root.appendingPathComponent("payload.partial")
        let payload = Data("test".utf8)
        let handle = try await actor.createTemporaryFile(
            at: temporary, declaredFileSize: Int64(payload.count), destination: target
        )
        target = nil
        XCTAssertNotNil(heldTarget)
        let retainedCount = await actor.activeDestinationCapabilityCount()
        XCTAssertEqual(retainedCount, 1)
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        await XCTAssertThrowsErrorAsync(try await actor.commit(
            using: handle, destinationDirectory: root, fileName: "payload.bin"
        )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .destinationCapabilityMismatch) }
        XCTAssertEqual(try Data(contentsOf: temporary), payload)
        let observation = try await actor.commitToPreparedDestination(using: handle, fileName: "payload.bin")
        XCTAssertEqual(try Data(contentsOf: observation.destinationURL), payload)
        try await actor.releaseCommittedFile(using: handle)
        XCTAssertNil(heldTarget)
        let releasedCount = await actor.activeDestinationCapabilityCount()
        XCTAssertEqual(releasedCount, 0)
        let replacement = try await actor.prepareDestinationDirectory(at: root)
        XCTAssertNotEqual(replacement.scopeDigest, originalScope)
    }

    func testForeignDestinationCannotCreateFileOrSatisfyAnotherTargetScope() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let firstActor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let secondActor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let firstTarget = try await firstActor.prepareDestinationDirectory(at: root.appendingPathComponent("first"))
        let secondDirectory = root.appendingPathComponent("second")
        let secondTarget = try await secondActor.prepareDestinationDirectory(at: secondDirectory)
        let temporary = root.appendingPathComponent("payload.partial")
        let payload = Data("test".utf8)
        await XCTAssertThrowsErrorAsync(try await secondActor.createTemporaryFile(
            at: temporary, declaredFileSize: Int64(payload.count), destination: firstTarget
        )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .destinationCapabilityMismatch) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        let handle = try await secondActor.createTemporaryFile(at: temporary, declaredFileSize: Int64(payload.count))
        _ = try await secondActor.write(payload, atOffset: 0, using: handle)
        _ = try await secondActor.closeAndDigest(using: handle)
        await XCTAssertThrowsErrorAsync(try await secondActor.bindCommit(
            using: handle, request: commitRequest(payload, target: firstTarget),
            destination: secondTarget, fileName: "payload.bin"
        )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .destinationCapabilityMismatch) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: secondDirectory.path), [])
        let binding = try await secondActor.bindCommit(
            using: handle, request: commitRequest(payload, target: secondTarget),
            destination: secondTarget, fileName: "payload.bin"
        )
        let observation = try await secondActor.commitBoundFile(binding)
        XCTAssertEqual(try Data(contentsOf: observation.destinationURL), payload)
        try await secondActor.releaseCommittedFile(using: handle)
    }

    func testPreparedDestinationCleanupUsesOriginalDirectoryAfterReplacement() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        for published in [false, true] {
            let directory = root.appendingPathComponent(published ? "published" : "staged")
            let displaced = directory.appendingPathExtension("original")
            let actor = InboundFileTransferIOActor(
                maxOpenTransfers: 1,
                commitDurabilityFaultsForTesting: published ? [.installedFileSync] : []
            )
            let target = try await actor.prepareDestinationDirectory(at: directory)
            let temporary = directory.appendingPathComponent("payload.partial")
            let payload = Data("original".utf8)
            let handle = try await actor.createTemporaryFile(
                at: temporary, declaredFileSize: Int64(payload.count), destination: target
            )
            _ = try await actor.write(payload, atOffset: 0, using: handle)
            if published {
                _ = try await actor.closeAndDigest(using: handle)
                await XCTAssertThrowsErrorAsync(try await actor.commitToPreparedDestination(
                    using: handle, fileName: "payload.bin"
                )) {
                    guard case .moveFailed = $0 as? InboundFileTransferIOError else {
                        return XCTFail("Expected durability fault, got \($0)")
                    }
                }
            }
            try FileManager.default.moveItem(at: directory, to: displaced)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fileName = published ? "payload.bin" : "payload.partial"
            let unrelated = directory.appendingPathComponent(fileName)
            let unrelatedBytes = Data("replacement".utf8)
            try unrelatedBytes.write(to: unrelated)
            try await actor.discardUncommittedFile(handle)
            XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: displaced.path), [])
            let remaining = await actor.activeTransferCount()
            XCTAssertEqual(remaining, 0)
        }
    }

    func testOperationBindingRejectsRelabelingAndGenericCommit() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let temporary = root.appendingPathComponent("payload.partial")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let otherDestination = root.appendingPathComponent("other", isDirectory: true)
        let payload = Data("bound payload".utf8)
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 3)
        let handle = try await actor.createTemporaryFile(at: temporary, declaredFileSize: Int64(payload.count))
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let target = try await actor.prepareDestinationDirectory(at: destination)
        let otherTarget = try await actor.prepareDestinationDirectory(at: otherDestination)
        let request = commitRequest(payload, target: target)
        let binding = try await actor.bindCommit(
            using: handle, request: request, destination: target, fileName: "payload.bin"
        )
        let duplicate = try await actor.bindCommit(
            using: handle, request: request, destination: target, fileName: "payload.bin"
        )
        XCTAssertEqual(binding, duplicate)
        // A value-equal reconstruction cannot prebind/commit and then register
        // retrospectively using a coordinator's independently owned request.
        let copiedFields = commitRequest(payload, target: target)
        XCTAssertNotEqual(request, copiedFields)
        await XCTAssertThrowsErrorAsync(try await actor.bindCommit(
            using: handle, request: copiedFields,
            destination: target, fileName: "payload.bin"
        )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .operationBindingMismatch) }
        for field in 0..<8 {
            await XCTAssertThrowsErrorAsync(try await actor.bindCommit(
                using: handle, request: commitRequest(payload, target: target, changedField: field),
                destination: target, fileName: "payload.bin"
            )) {
                XCTAssertEqual($0 as? InboundFileTransferIOError,
                               field == 4 ? .destinationCapabilityMismatch : .operationBindingMismatch)
            }
        }
        for (directory, name) in [(otherTarget, "payload.bin"), (target, "other.bin")] {
            await XCTAssertThrowsErrorAsync(try await actor.bindCommit(
                using: handle, request: request, destination: directory, fileName: name
            )) {
                XCTAssertEqual($0 as? InboundFileTransferIOError,
                               directory == otherTarget ? .destinationCapabilityMismatch : .operationBindingMismatch)
            }
        }
        await XCTAssertThrowsErrorAsync(try await actor.commitWithDurabilityObservation(
            using: handle, destinationDirectory: destination, fileName: "payload.bin"
        )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .operationBindingMismatch) }
        let unrelatedActor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        await XCTAssertThrowsErrorAsync(try await unrelatedActor.commitBoundFile(binding)) {
            XCTAssertEqual($0 as? InboundFileTransferIOError, .unknownHandle)
        }
        XCTAssertEqual(try Data(contentsOf: temporary), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: otherDestination.path), [])
        let committed = try await actor.commitBoundFile(binding)
        let repeated = try await actor.commitBoundFile(binding)
        XCTAssertEqual(committed, repeated)
        XCTAssertEqual(committed.operationBinding, binding)
        XCTAssertEqual(try Data(contentsOf: committed.destinationURL), payload)
        await XCTAssertThrowsErrorAsync(try await actor.bindCommit(
            using: handle, request: commitRequest(payload, target: target, changedField: 0),
            destination: target, fileName: "payload.bin"
        )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .operationBindingMismatch) }
        try await actor.releaseCommittedFile(using: handle)
        await XCTAssertThrowsErrorAsync(try await actor.commitBoundFile(binding)) {
            XCTAssertEqual($0 as? InboundFileTransferIOError, .unknownHandle)
        }
    }

    func testBoundCommitRejectsReplacedDestinationBeforeRename() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let temporary = root.appendingPathComponent("payload.partial")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let displaced = root.appendingPathComponent("displaced", isDirectory: true)
        let payload = Data("directory binding".utf8)
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let handle = try await actor.createTemporaryFile(at: temporary, declaredFileSize: Int64(payload.count))
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let target = try await actor.prepareDestinationDirectory(at: destination)
        let binding = try await actor.bindCommit(
            using: handle, request: commitRequest(payload, target: target),
            destination: target, fileName: "payload.bin"
        )
        try FileManager.default.moveItem(at: destination, to: displaced)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        await XCTAssertThrowsErrorAsync(try await actor.commitBoundFile(binding)) {
            XCTAssertEqual($0 as? InboundFileTransferIOError, .destinationCapabilityMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: temporary), payload)
        for directory in [destination, displaced] {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: displaced, to: destination)
        let committed = try await actor.commitBoundFile(binding)
        XCTAssertEqual(committed.operationBinding, binding)
        XCTAssertEqual(try Data(contentsOf: committed.destinationURL), payload)
        try await actor.releaseCommittedFile(using: handle)
    }

    func testBoundCommitRetainsBindingAcrossEveryDurabilityRetry() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let temporary = root.appendingPathComponent("payload.partial")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let payload = Data("durability binding".utf8)
        let actor = InboundFileTransferIOActor(
            maxOpenTransfers: 1,
            commitDurabilityFaultsForTesting: [.installedFileReopen, .installedFileSync,
                                              .sourceDirectorySync, .destinationDirectorySync]
        )
        let handle = try await actor.createTemporaryFile(at: temporary, declaredFileSize: Int64(payload.count))
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let target = try await actor.prepareDestinationDirectory(at: destination)
        let request = commitRequest(payload, target: target)
        let binding = try await actor.bindCommit(
            using: handle, request: request, destination: target, fileName: "payload.bin"
        )
        try Data("existing".utf8).write(to: destination.appendingPathComponent("payload.bin"))
        let installed = destination.appendingPathComponent("payload (1).bin")
        for _ in 0..<4 {
            await XCTAssertThrowsErrorAsync(try await actor.commitBoundFile(binding)) {
                guard case .moveFailed = $0 as? InboundFileTransferIOError else {
                    return XCTFail("Expected durability failure, got \($0)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: installed), payload)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
            await XCTAssertThrowsErrorAsync(try await actor.commit(
                using: handle, destinationDirectory: destination, fileName: "other.bin"
            )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .operationBindingMismatch) }
            let retained = try await actor.bindCommit(
                using: handle, request: request, destination: target, fileName: "payload.bin"
            )
            XCTAssertEqual(retained, binding)
        }
        let committed = try await actor.commitBoundFile(binding)
        XCTAssertEqual(committed.operationBinding, binding)
        XCTAssertEqual(committed.destinationURL, installed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(),
                       ["payload (1).bin", "payload.bin"])
        try await actor.releaseCommittedFile(using: handle)
    }

    func testBindingCannotRetrofitAClassicCommitAndRejectsWrongStagedPurpose() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let temporary = root.appendingPathComponent("payload.partial")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let payload = Data("classic commit".utf8)
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let handle = try await actor.createTemporaryFile(at: temporary, declaredFileSize: Int64(payload.count))
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let target = try await actor.prepareDestinationDirectory(at: destination)
        for field in [5, 6] {
            await XCTAssertThrowsErrorAsync(try await actor.bindCommit(
                using: handle, request: commitRequest(payload, target: target, changedField: field),
                destination: target, fileName: "payload.bin"
            )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .operationBindingMismatch) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        let classic = try await actor.commitWithDurabilityObservation(
            using: handle, destinationDirectory: destination, fileName: "payload.bin"
        )
        XCTAssertNil(classic.operationBinding)
        await XCTAssertThrowsErrorAsync(try await actor.bindCommit(
            using: handle, request: commitRequest(payload, target: target),
            destination: target, fileName: "payload.bin"
        )) { XCTAssertEqual($0 as? InboundFileTransferIOError, .operationBindingMismatch) }
        XCTAssertEqual(try Data(contentsOf: classic.destinationURL), payload)
        try await actor.releaseCommittedFile(using: handle)
    }

    func testCancelledBoundCommitKeepsStagedFileForExplicitRetry() async throws {
        let root = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let temporary = root.appendingPathComponent("payload.partial")
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        let payload = Data("cancelled bound commit".utf8)
        let actor = InboundFileTransferIOActor(maxOpenTransfers: 1)
        let handle = try await actor.createTemporaryFile(at: temporary, declaredFileSize: Int64(payload.count))
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)
        let target = try await actor.prepareDestinationDirectory(at: destination)
        let binding = try await actor.bindCommit(
            using: handle, request: commitRequest(payload, target: target),
            destination: target, fileName: "payload.bin"
        )
        let gate = InboundFileTransferTestGate()
        let task = Task {
            await gate.wait()
            return try await actor.commitBoundFile(binding)
        }
        await gate.waitUntilRegistered()
        task.cancel()
        await gate.open()
        await XCTAssertThrowsErrorAsync(try await task.value) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: temporary), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        let committed = try await actor.commitBoundFile(binding)
        XCTAssertEqual(try Data(contentsOf: committed.destinationURL), payload)
        try await actor.releaseCommittedFile(using: handle)
    }

    private func commitRequest(
        _ payload: Data, target: InboundFileTransferDestinationCapability,
        changedField: Int? = nil
    ) -> InboundFileTransferCommitRequest {
        var scope = target.scopeDigest
        if changedField == 4 { scope[0] ^= 1 }
        return InboundFileTransferCommitRequest(
            operationID: Data(repeating: changedField == 0 ? 0x22 : 0x11, count: 32),
            sequence: changedField == 1 ? 2 : 1,
            requestDigest: Data(repeating: changedField == 2 ? 0x22 : 0x11, count: 32),
            transferID: Data(repeating: changedField == 3 ? 0x22 : 0x11, count: 32),
            targetScope: scope,
            declaredBytes: UInt64(payload.count + (changedField == 5 ? 1 : 0)),
            contentSHA256: changedField == 6 ? Data(repeating: 0x22, count: 32) : Data(SHA256.hash(data: payload)),
            requestedFileName: changedField == 7 ? "other.bin" : "payload.bin"
        )
    }

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

        let durableCommit = try await actor.commitWithDurabilityObservation(
            using: handle,
            destinationDirectory: directory,
            fileName: "payload.bin"
        )
        let committedURL = durableCommit.destinationURL
        XCTAssertEqual(committedURL.lastPathComponent, "payload (1).bin")
        XCTAssertEqual(durableCommit.destinationRelativePath, "payload (1).bin")
        XCTAssertEqual(durableCommit.byteCount, UInt64(payload.count))
        XCTAssertEqual(durableCommit.sha256, Data(SHA256.hash(data: payload)))
        XCTAssertEqual(
            durableCommit.durabilityPrimitive,
            .fileAndParentDirectorySync
        )
        XCTAssertEqual(try Data(contentsOf: committedURL), payload)
        let countBeforeRelease = await actor.activeTransferCount()
        XCTAssertEqual(countBeforeRelease, 1)

        try await actor.releaseCommittedFile(using: handle)
        let countAfterRelease = await actor.activeTransferCount()
        XCTAssertEqual(countAfterRelease, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committedURL.path))
    }

    func testPostRenameDurabilityFailuresRetryOnlyTheExactInstalledPath() async throws {
        let rootDirectory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: rootDirectory)) }
        let stagingDirectory = rootDirectory.appendingPathComponent("staging", isDirectory: true)
        let destinationDirectory = rootDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        let unrelatedRetryDirectory = rootDirectory.appendingPathComponent(
            "unrelated-retry",
            isDirectory: true
        )
        let temporaryURL = stagingDirectory.appendingPathComponent("payload.partial")
        let installedURL = destinationDirectory.appendingPathComponent("payload.bin")
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let actor = InboundFileTransferIOActor(
            maxOpenTransfers: 1,
            commitDurabilityFaultsForTesting: [
                .installedFileReopen,
                .installedFileSync,
                .sourceDirectorySync,
                .destinationDirectorySync
            ]
        )
        let handle = try await actor.createTemporaryFile(
            at: temporaryURL,
            declaredFileSize: Int64(payload.count)
        )
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)

        for attempt in 0..<4 {
            let requestedDirectory = attempt == 0
                ? destinationDirectory
                : unrelatedRetryDirectory
            let requestedName = attempt == 0 ? "payload.bin" : "must-not-be-installed.bin"
            await XCTAssertThrowsErrorAsync(
                try await actor.commit(
                    using: handle,
                    destinationDirectory: requestedDirectory,
                    fileName: requestedName
                )
            ) { error in
                guard let ioError = error as? InboundFileTransferIOError,
                      case .moveFailed = ioError else {
                    return XCTFail("Expected injected post-rename failure, got \(error)")
                }
            }
            await XCTAssertThrowsErrorAsync(
                try await actor.releaseCommittedFile(using: handle)
            ) { error in
                XCTAssertEqual(
                    error as? InboundFileTransferIOError,
                    .releaseBeforeCommit
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
            XCTAssertEqual(try Data(contentsOf: installedURL), payload)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: unrelatedRetryDirectory.path)
            )
        }

        let committedURL = try await actor.commit(
            using: handle,
            destinationDirectory: unrelatedRetryDirectory,
            fileName: "must-not-be-installed.bin"
        )
        XCTAssertEqual(committedURL.standardizedFileURL, installedURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelatedRetryDirectory.path))

        let idempotentURL = try await actor.commit(
            using: handle,
            destinationDirectory: unrelatedRetryDirectory,
            fileName: "another-name.bin"
        )
        XCTAssertEqual(idempotentURL.standardizedFileURL, installedURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: installedURL), payload)
        try await actor.releaseCommittedFile(using: handle)
        let activeTransferCount = await actor.activeTransferCount()
        XCTAssertEqual(activeTransferCount, 0)
    }

    func testPostRenameDigestMismatchRejectsReleaseAndCleanupRemovesPendingFile() async throws {
        let rootDirectory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: rootDirectory)) }
        let stagingDirectory = rootDirectory.appendingPathComponent("staging", isDirectory: true)
        let destinationDirectory = rootDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        let temporaryURL = stagingDirectory.appendingPathComponent("payload.partial")
        let installedURL = destinationDirectory.appendingPathComponent("payload.bin")
        let payload = Data("authenticated-payload".utf8)
        let actor = InboundFileTransferIOActor(
            maxOpenTransfers: 1,
            commitDurabilityFaultsForTesting: [.installedFileReopen]
        )
        let handle = try await actor.createTemporaryFile(
            at: temporaryURL,
            declaredFileSize: Int64(payload.count)
        )
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)

        await XCTAssertThrowsErrorAsync(
            try await actor.commit(
                using: handle,
                destinationDirectory: destinationDirectory,
                fileName: "payload.bin"
            )
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .moveFailed = ioError else {
                return XCTFail("Expected injected reopen failure, got \(error)")
            }
        }
        try overwriteInPlace(
            installedURL,
            with: Data(repeating: 0xA5, count: payload.count)
        )

        await XCTAssertThrowsErrorAsync(
            try await actor.commit(
                using: handle,
                destinationDirectory: destinationDirectory,
                fileName: "payload.bin"
            )
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .moveFailed(let details) = ioError else {
                return XCTFail("Expected installed digest rejection, got \(error)")
            }
            XCTAssertTrue(details.contains("digest changed after rename"))
        }
        await XCTAssertThrowsErrorAsync(
            try await actor.releaseCommittedFile(using: handle)
        ) { error in
            XCTAssertEqual(error as? InboundFileTransferIOError, .releaseBeforeCommit)
        }

        let cleanupTask = Task {
            await Task.yield()
            try await actor.discardUncommittedFile(handle)
        }
        cleanupTask.cancel()
        try await cleanupTask.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        let activeTransferCount = await actor.activeTransferCount()
        XCTAssertEqual(activeTransferCount, 0)
    }

    func testPostRenameIdentitySwapCannotCommitOrDeleteReplacement() async throws {
        let rootDirectory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: rootDirectory)) }
        let stagingDirectory = rootDirectory.appendingPathComponent("staging", isDirectory: true)
        let destinationDirectory = rootDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        let temporaryURL = stagingDirectory.appendingPathComponent("payload.partial")
        let installedURL = destinationDirectory.appendingPathComponent("payload.bin")
        let displacedURL = destinationDirectory.appendingPathComponent("displaced.bin")
        let payload = Data("identity-bound-payload".utf8)
        let actor = InboundFileTransferIOActor(
            maxOpenTransfers: 1,
            commitDurabilityFaultsForTesting: [.installedFileReopen]
        )
        let handle = try await actor.createTemporaryFile(
            at: temporaryURL,
            declaredFileSize: Int64(payload.count)
        )
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)

        await XCTAssertThrowsErrorAsync(
            try await actor.commit(
                using: handle,
                destinationDirectory: destinationDirectory,
                fileName: "payload.bin"
            )
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .moveFailed = ioError else {
                return XCTFail("Expected injected reopen failure, got \(error)")
            }
        }

        try FileManager.default.moveItem(at: installedURL, to: displacedURL)
        try payload.write(to: installedURL, options: [.withoutOverwriting])
        await XCTAssertThrowsErrorAsync(
            try await actor.commit(
                using: handle,
                destinationDirectory: destinationDirectory,
                fileName: "payload.bin"
            )
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .moveFailed(let details) = ioError else {
                return XCTFail("Expected installed identity rejection, got \(error)")
            }
            XCTAssertTrue(details.contains("identity changed after rename"))
        }
        await XCTAssertThrowsErrorAsync(
            try await actor.releaseCommittedFile(using: handle)
        ) { error in
            XCTAssertEqual(error as? InboundFileTransferIOError, .releaseBeforeCommit)
        }
        await XCTAssertThrowsErrorAsync(
            try await actor.discardUncommittedFile(handle)
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .cleanupFailed = ioError else {
                return XCTFail("Expected identity-bound cleanup rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: installedURL), payload)
        XCTAssertEqual(try Data(contentsOf: displacedURL), payload)

        try FileManager.default.removeItem(at: installedURL)
        try FileManager.default.moveItem(at: displacedURL, to: installedURL)
        try await actor.discardUncommittedFile(handle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        let activeTransferCount = await actor.activeTransferCount()
        XCTAssertEqual(activeTransferCount, 0)
    }

    func testPendingCleanupRetriesAfterSourceDirectoryIdentityFailure() async throws {
        let rootDirectory = try makeDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: rootDirectory)) }
        let stagingDirectory = rootDirectory.appendingPathComponent("staging", isDirectory: true)
        let displacedStagingDirectory = rootDirectory.appendingPathComponent(
            "staging-displaced",
            isDirectory: true
        )
        let destinationDirectory = rootDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        let temporaryURL = stagingDirectory.appendingPathComponent("payload.partial")
        let installedURL = destinationDirectory.appendingPathComponent("payload.bin")
        let payload = Data("cleanup-retry".utf8)
        let actor = InboundFileTransferIOActor(
            maxOpenTransfers: 1,
            commitDurabilityFaultsForTesting: [.installedFileReopen]
        )
        let handle = try await actor.createTemporaryFile(
            at: temporaryURL,
            declaredFileSize: Int64(payload.count)
        )
        _ = try await actor.write(payload, atOffset: 0, using: handle)
        _ = try await actor.closeAndDigest(using: handle)

        await XCTAssertThrowsErrorAsync(
            try await actor.commit(
                using: handle,
                destinationDirectory: destinationDirectory,
                fileName: "payload.bin"
            )
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .moveFailed = ioError else {
                return XCTFail("Expected injected reopen failure, got \(error)")
            }
        }
        try FileManager.default.moveItem(
            at: stagingDirectory,
            to: displacedStagingDirectory
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false
        )

        await XCTAssertThrowsErrorAsync(
            try await actor.discardUncommittedFile(handle)
        ) { error in
            guard let ioError = error as? InboundFileTransferIOError,
                  case .cleanupFailed(let details) = ioError else {
                return XCTFail("Expected source directory cleanup rejection, got \(error)")
            }
            XCTAssertTrue(details.contains("source directory sync"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installedURL.path))
        let pendingTransferCount = await actor.activeTransferCount()
        XCTAssertEqual(pendingTransferCount, 1)

        try FileManager.default.removeItem(at: stagingDirectory)
        try FileManager.default.moveItem(
            at: displacedStagingDirectory,
            to: stagingDirectory
        )
        try await actor.discardUncommittedFile(handle)
        let activeTransferCount = await actor.activeTransferCount()
        XCTAssertEqual(activeTransferCount, 0)
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

    private func overwriteInPlace(_ fileURL: URL, with data: Data) throws {
        let writer = try FileHandle(forWritingTo: fileURL)
        let operationResult: Result<Void, Error>
        do {
            try writer.seek(toOffset: 0)
            try writer.write(contentsOf: data)
            try writer.synchronize()
            operationResult = .success(())
        } catch {
            operationResult = .failure(error)
        }

        do {
            try writer.close()
        } catch {
            if case .failure(let operationError) = operationResult {
                throw InboundFileTransferIOError.writeFailed(
                    "\(operationError.localizedDescription); test mutation close failed: "
                        + error.localizedDescription
                )
            }
            throw error
        }
        try operationResult.get()
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
