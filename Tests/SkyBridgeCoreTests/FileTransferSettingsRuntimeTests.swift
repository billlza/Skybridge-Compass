import XCTest
import Network

@testable import SkyBridgeCore

@MainActor
final class FileTransferSettingsRuntimeTests: XCTestCase {
    func testDefaultReceiveDirectoryPreservesEachPlatformLayout() {
        let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
        let documents = URL(fileURLWithPath: "/container/Documents", isDirectory: true)

        XCTAssertEqual(
            FileTransferDirectoryLayout.defaultReceiveDirectory(
                platform: .macOS,
                downloadsDirectory: downloads,
                documentsDirectory: documents
            ),
            downloads.appendingPathComponent("SkyBridge", isDirectory: true)
        )
        XCTAssertEqual(
            FileTransferDirectoryLayout.defaultReceiveDirectory(
                platform: .iOS,
                downloadsDirectory: downloads,
                documentsDirectory: documents
            ),
            documents.appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    func testDefaultReceiveDirectoryFailsWhenDurablePlatformRootIsUnavailable() {
        XCTAssertNil(
            FileTransferDirectoryLayout.defaultReceiveDirectory(
                platform: .macOS,
                downloadsDirectory: nil,
                documentsDirectory: URL(fileURLWithPath: "/unused", isDirectory: true)
            )
        )
        XCTAssertNil(
            FileTransferDirectoryLayout.defaultReceiveDirectory(
                platform: .iOS,
                downloadsDirectory: URL(fileURLWithPath: "/unused", isDirectory: true),
                documentsDirectory: nil
            )
        )
    }

    func testIOSReceiveDirectoryCandidatesNeverFallBackToHiddenApplicationSupport() {
        let explicit = URL(fileURLWithPath: "/container/Documents/Chosen", isDirectory: true)
        let canonical = URL(fileURLWithPath: "/container/Documents/Downloads", isDirectory: true)
        let hidden = URL(fileURLWithPath: "/container/Library/Application Support/SkyBridge/Received Files", isDirectory: true)

        XCTAssertEqual(
            FileTransferDirectoryLayout.receiveDirectoryCandidates(
                platform: .iOS,
                explicitDirectory: explicit,
                defaultDirectory: canonical,
                applicationSupportDirectory: hidden
            ),
            [explicit, canonical]
        )
    }

    func testMacReceiveDirectoryCandidatesKeepDocumentedFallbackAndDeduplicate() {
        let canonical = URL(fileURLWithPath: "/Users/test/Downloads/SkyBridge", isDirectory: true)
        let appSupport = URL(fileURLWithPath: "/Users/test/Library/Application Support/SkyBridge/Received Files", isDirectory: true)

        XCTAssertEqual(
            FileTransferDirectoryLayout.receiveDirectoryCandidates(
                platform: .macOS,
                explicitDirectory: canonical,
                defaultDirectory: canonical,
                applicationSupportDirectory: appSupport
            ),
            [canonical, appSupport]
        )
    }

    func testResumableRetryDecisionHonorsAutoRetrySwitch() {
        XCTAssertFalse(
            ResumableTransferRetryDecision.shouldScheduleAutomaticRetry(
                autoRetryFailedTransfers: false,
                retryCount: 1,
                maxRetryAttempts: 3
            )
        )
        XCTAssertTrue(
            ResumableTransferRetryDecision.shouldScheduleAutomaticRetry(
                autoRetryFailedTransfers: true,
                retryCount: 1,
                maxRetryAttempts: 3
            )
        )
        XCTAssertFalse(
            ResumableTransferRetryDecision.shouldScheduleAutomaticRetry(
                autoRetryFailedTransfers: true,
                retryCount: 3,
                maxRetryAttempts: 3
            )
        )
    }

    func testCanonicalAutomaticResumeDecisionHonorsRuntimeSettingsAndSafetyBoundaries() {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)

        func shouldResume(
            peerSupportsResume: Bool = true,
            status: TransferStatus = .transferring,
            transferredBytes: Int64 = 1,
            fileSize: Int64 = 10,
            error: Error
        ) -> Bool {
            manager.shouldAttemptAutomaticOutgoingResume(
                peerSupportsResume: peerSupportsResume,
                transferStatus: status,
                transferredBytes: transferredBytes,
                fileSize: fileSize,
                error: error
            )
        }

        XCTAssertTrue(shouldResume(error: FileTransferError.connectionClosed))
        XCTAssertTrue(shouldResume(error: FileTransferError.timeout))

        manager.updateSettings(automaticResumeEnabled: false)
        XCTAssertFalse(shouldResume(error: FileTransferError.connectionClosed))
        XCTAssertFalse(shouldResume(error: FileTransferError.timeout))

        manager.updateSettings(chunkSize: 128 * 1_024)
        XCTAssertFalse(
            shouldResume(error: FileTransferError.connectionClosed),
            "Updating an unrelated setting must not reset the automatic-resume preference"
        )

        manager.updateSettings(automaticResumeEnabled: true)
        XCTAssertTrue(shouldResume(error: FileTransferError.connectionClosed))
        XCTAssertFalse(shouldResume(peerSupportsResume: false, error: FileTransferError.connectionClosed))
        for status in TransferStatus.allCases {
            XCTAssertEqual(
                shouldResume(status: status, error: FileTransferError.connectionClosed),
                status == .transferring,
                "Only an actively transferring operation may enter automatic resume"
            )
        }
        XCTAssertFalse(shouldResume(transferredBytes: 0, error: FileTransferError.connectionClosed))
        XCTAssertFalse(shouldResume(transferredBytes: -1, error: FileTransferError.connectionClosed))
        XCTAssertFalse(
            shouldResume(
                transferredBytes: 10,
                fileSize: 10,
                error: FileTransferError.connectionClosed
            ),
            "A fully-sent payload awaiting its receipt must not be resumed as a partial transfer"
        )
        XCTAssertFalse(shouldResume(error: FileTransferError.integrityCheckFailed))
        XCTAssertFalse(shouldResume(error: FileTransferError.receiverRejected))
        XCTAssertFalse(shouldResume(error: FileTransferError.transferCancelled))
        XCTAssertFalse(
            shouldResume(error: NSError(domain: "FileTransferSettingsRuntimeTests", code: 1))
        )
        for code in [
            POSIXErrorCode.ECONNABORTED,
            .ECONNRESET,
            .EHOSTUNREACH,
            .ENETDOWN,
            .ENETRESET,
            .ENETUNREACH,
            .ENOTCONN,
            .EPIPE,
            .ETIMEDOUT
        ] {
            XCTAssertTrue(shouldResume(error: NWError.posix(code)))
        }
        XCTAssertFalse(shouldResume(error: NWError.posix(.ECANCELED)))
        XCTAssertFalse(shouldResume(error: NWError.posix(.EACCES)))
    }

    func testZeroSpeedLimitExplicitlyClearsAnExistingLimit() {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        manager.updateSettings(maxTransferSpeedBytesPerSecond: 8 * 1_024 * 1_024)
        XCTAssertEqual(manager.configuredSpeedLimitBytesPerSecondForTesting, 8 * 1_024 * 1_024)

        manager.updateSettings(maxTransferSpeedBytesPerSecond: 0)
        XCTAssertNil(manager.configuredSpeedLimitBytesPerSecondForTesting)
    }

    func testNonFiniteSpeedLimitsAreRejectedWithoutReplacingLastValidValue() {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let validLimit = 8.0 * 1_024 * 1_024
        manager.updateSettings(maxTransferSpeedBytesPerSecond: validLimit)

        manager.updateSettings(maxTransferSpeedBytesPerSecond: .infinity)
        XCTAssertEqual(manager.configuredSpeedLimitBytesPerSecondForTesting, validLimit)

        manager.updateSettings(maxTransferSpeedBytesPerSecond: .nan)
        XCTAssertEqual(manager.configuredSpeedLimitBytesPerSecondForTesting, validLimit)
    }

    func testReceiveDirectoryResolverUsesValidatedPreferredDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("receive-directory-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let preferred = root.appendingPathComponent("preferred", isDirectory: true)
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)

        let result = await FileTransferSettingsBridge.resolveReceiveDirectory(
            preferredPath: preferred.path,
            fallbackURL: fallback
        )
        guard case .success(let url, let usedFallback, let failure) = result else {
            return XCTFail("Expected preferred directory success, got \(result)")
        }
        XCTAssertEqual(url, preferred.standardizedFileURL)
        XCTAssertFalse(usedFallback)
        XCTAssertNil(failure)
    }

    func testReceiveDirectoryResolverFallsBackWhenPreferredCandidateIsAFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("receive-directory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let preferredFile = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: preferredFile, options: .atomic)
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)

        let result = await FileTransferSettingsBridge.resolveReceiveDirectory(
            preferredPath: preferredFile.path,
            fallbackURL: fallback
        )
        guard case .success(let url, let usedFallback, let failure) = result else {
            return XCTFail("Expected validated fallback success, got \(result)")
        }
        XCTAssertEqual(url, fallback.standardizedFileURL)
        XCTAssertTrue(usedFallback)
        XCTAssertNotNil(failure)
    }

    func testReceiveDirectoryResolverCanRetrySamePathAfterExplicitFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("receive-directory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let preferredFile = root.appendingPathComponent("preferred-file")
        let fallbackFile = root.appendingPathComponent("fallback-file")
        try Data("preferred".utf8).write(to: preferredFile, options: .atomic)
        try Data("fallback".utf8).write(to: fallbackFile, options: .atomic)

        let result = await FileTransferSettingsBridge.resolveReceiveDirectory(
            preferredPath: preferredFile.path,
            fallbackURL: fallbackFile
        )
        guard case .failure(let preferredFailure, _) = result else {
            return XCTFail("Expected terminal directory failure, got \(result)")
        }
        XCTAssertNotNil(preferredFailure)

        try FileManager.default.removeItem(at: preferredFile)
        try FileManager.default.removeItem(at: fallbackFile)
        let recovered = await FileTransferSettingsBridge.resolveReceiveDirectory(
            preferredPath: preferredFile.path,
            fallbackURL: fallbackFile
        )
        guard case .success(let url, let usedFallback, let failure) = recovered else {
            return XCTFail("Expected the repaired preferred path to be revalidated, got \(recovered)")
        }
        XCTAssertEqual(url, preferredFile.standardizedFileURL)
        XCTAssertFalse(usedFallback)
        XCTAssertNil(failure)
    }

    func testReceiveDirectoryCoalescingOnlyReusesAnActiveSamePathRequest() {
        XCTAssertTrue(
            FileTransferDirectoryResolutionCoalescingPolicy.shouldReuseActiveRequest(
                requestKey: "/same",
                lastRequestedKey: "/same",
                hasActiveTask: true,
                force: false
            )
        )
        XCTAssertFalse(
            FileTransferDirectoryResolutionCoalescingPolicy.shouldReuseActiveRequest(
                requestKey: "/same",
                lastRequestedKey: "/same",
                hasActiveTask: false,
                force: false
            )
        )
        XCTAssertFalse(
            FileTransferDirectoryResolutionCoalescingPolicy.shouldReuseActiveRequest(
                requestKey: "/same",
                lastRequestedKey: "/other",
                hasActiveTask: true,
                force: false
            )
        )
        XCTAssertFalse(
            FileTransferDirectoryResolutionCoalescingPolicy.shouldReuseActiveRequest(
                requestKey: "/same",
                lastRequestedKey: "/same",
                hasActiveTask: true,
                force: true
            )
        )
    }

    func testKeepAwakeSettingControlsTransferLifecycleAssertion() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let powerAssertion = RecordingPowerAssertion()
        let manager = FileTransferManager(historyStore: historyStore, powerAssertion: powerAssertion)
        manager.updateSettings(keepSystemAwakeDuringTransfer: true)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        try Data("awake".utf8).write(to: fileURL, options: .atomic)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: fileURL)) }

        let transferId = UUID().uuidString
        let token = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: transferId,
            fileURL: fileURL,
            fileSize: 5,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone",
            cancellationHandler: {}
        ))

        XCTAssertTrue(powerAssertion.isHoldingAssertion)
        XCTAssertEqual(powerAssertion.updates.last?.shouldKeepAwake, true)
        XCTAssertEqual(powerAssertion.updates.last?.hasActiveTransfers, true)

        manager.completeExternalOutboundTransfer(token: token)

        XCTAssertFalse(powerAssertion.isHoldingAssertion)
        XCTAssertEqual(powerAssertion.updates.last?.hasActiveTransfers, false)
        XCTAssertEqual(powerAssertion.releaseCount, 1)
    }

    func testSecurityContextPreflightFailureCleansActiveTransferAndPowerAssertion() async throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let powerAssertion = RecordingPowerAssertion()
        let manager = FileTransferManager(
            historyStore: historyStore,
            powerAssertion: powerAssertion
        )
        manager.updateSettings(keepSystemAwakeDuringTransfer: true)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("security-preflight-\(UUID().uuidString).bin")
        try Data("security-preflight".utf8).write(to: fileURL, options: .atomic)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: fileURL)) }

        do {
            try await manager.sendFile(
                at: fileURL,
                to: "untrusted-peer-\(UUID().uuidString)",
                deviceName: "Untrusted Peer",
                ipAddress: "198.51.100.88",
                port: 8_080
            )
            XCTFail("Expected an authenticated classic-transfer context to be required")
        } catch let error as FileTransferError {
            guard case .secureSessionRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertTrue(manager.activeTransfers.isEmpty)
        XCTAssertFalse(manager.isTransferring)
        XCTAssertFalse(powerAssertion.isHoldingAssertion)
        XCTAssertEqual(manager.transferHistory.last?.status, .failed)
    }

    func testKeepAwakeDisabledDoesNotAcquireAssertionForActiveTransfer() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let powerAssertion = RecordingPowerAssertion()
        let manager = FileTransferManager(historyStore: historyStore, powerAssertion: powerAssertion)
        manager.updateSettings(keepSystemAwakeDuringTransfer: false)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        try Data("awake-disabled".utf8).write(to: fileURL, options: .atomic)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: fileURL)) }

        _ = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: UUID().uuidString,
            fileURL: fileURL,
            fileSize: 14,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone",
            cancellationHandler: {}
        ))

        XCTAssertFalse(powerAssertion.isHoldingAssertion)
        XCTAssertEqual(powerAssertion.updates.last?.shouldKeepAwake, false)
        XCTAssertEqual(powerAssertion.updates.last?.hasActiveTransfers, true)
    }

    func testExternalOutboundProgressPublishesRealBytesAndWeightedTotalProgress() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let smallTransferId = UUID().uuidString
        let largeTransferId = UUID().uuidString
        let smallFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(smallTransferId).bin")
        let largeFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(largeTransferId).bin")

        let progressEvents = FileTransferProgressEventRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("com.skybridge.fileTransfer.progressUpdated"),
            object: nil,
            queue: nil
        ) { notification in
            guard let userInfo = notification.userInfo,
                  let event = FileTransferProgressEvent(userInfo: userInfo),
                  event.transferId == smallTransferId || event.transferId == largeTransferId else {
                return
            }
            progressEvents.append(event)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let smallToken = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: smallTransferId,
            fileURL: smallFileURL,
            fileSize: 100,
            toDeviceId: "peer-a",
            toDeviceName: "Peer A",
            cancellationHandler: {}
        ))
        let largeToken = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: largeTransferId,
            fileURL: largeFileURL,
            fileSize: 900,
            toDeviceId: "peer-b",
            toDeviceName: "Peer B",
            cancellationHandler: {}
        ))

        manager.updateExternalOutboundProgress(token: smallToken, transferredBytes: 100)
        XCTAssertEqual(manager.activeTransfers[smallTransferId]?.progress, 1.0)
        XCTAssertEqual(manager.totalProgress, 0.1, accuracy: 0.000_001)

        manager.updateExternalOutboundProgress(token: largeToken, transferredBytes: 450)
        XCTAssertEqual(manager.activeTransfers[largeTransferId]?.progress, 0.5)
        XCTAssertEqual(manager.totalProgress, 0.55, accuracy: 0.000_001)

        let largeTransferEvent = try XCTUnwrap(progressEvents.last(transferId: largeTransferId))
        XCTAssertEqual(largeTransferEvent.progress, 0.5)
        XCTAssertEqual(largeTransferEvent.transferredBytes, 450)
        XCTAssertEqual(largeTransferEvent.fileSize, 900)
        XCTAssertEqual(largeTransferEvent.totalBytes, 900)
        XCTAssertEqual(largeTransferEvent.direction, "outgoing")
    }

    func testExternalInboundProgressUsesSameRealByteProgressPath() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferId = UUID().uuidString

        let token = try XCTUnwrap(manager.beginExternalInboundTransfer(
            transferId: transferId,
            fileName: "incoming.mov",
            fileSize: 200,
            fromDeviceId: "peer-in",
            fromDeviceName: "Peer In",
            cancellationHandler: {}
        ))
        manager.updateExternalInboundProgress(token: token, transferredBytes: 50)

        let transfer = try XCTUnwrap(manager.activeTransfers[transferId])
        XCTAssertEqual(transfer.status, .transferring)
        XCTAssertEqual(transfer.transferredBytes, 50)
        XCTAssertEqual(transfer.progress, 0.25)
        XCTAssertEqual(manager.totalProgress, 0.25, accuracy: 0.000_001)
    }

    func testExternalTransferTokenRejectsStaleSameIdentifierCallbacks() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferID = "peer-controlled-reused-id"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        let staleToken = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: transferID,
            fileURL: fileURL,
            fileSize: 100,
            toDeviceId: "peer-a",
            toDeviceName: "Peer A",
            cancellationHandler: {}
        ))
        manager.failExternalOutboundTransfer(token: staleToken, errorMessage: "first failed")

        let currentToken = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: transferID,
            fileURL: fileURL,
            fileSize: 100,
            toDeviceId: "peer-a",
            toDeviceName: "Peer A",
            cancellationHandler: {}
        ))
        manager.updateExternalOutboundProgress(token: staleToken, transferredBytes: 100)
        manager.completeExternalOutboundTransfer(token: staleToken)

        let currentTransfer = try XCTUnwrap(manager.activeTransfers[transferID])
        XCTAssertEqual(currentTransfer.status, .preparing)
        XCTAssertEqual(currentTransfer.transferredBytes, 0)

        manager.updateExternalOutboundProgress(token: currentToken, transferredBytes: 25)
        XCTAssertEqual(manager.activeTransfers[transferID]?.transferredBytes, 25)
    }

    func testExternalTransferCancellationDelegatesToTransportBeforeTerminalPresentation() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferID = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(transferID).bin")
        var cancellationCount = 0
        let token = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: transferID,
            fileURL: fileURL,
            fileSize: 10,
            toDeviceId: "peer",
            toDeviceName: "Peer",
            cancellationHandler: {
                cancellationCount += 1
            }
        ))

        XCTAssertNil(manager.beginExternalOutboundTransfer(
            transferId: transferID,
            fileURL: fileURL,
            fileSize: 10,
            toDeviceId: "peer",
            toDeviceName: "Peer",
            cancellationHandler: {}
        ))

        manager.cancelTransfer(transferID)

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNotNil(
            manager.activeTransfers[transferID],
            "The transport owns terminal cleanup after it has actually stopped"
        )

        manager.failExternalOutboundTransfer(
            token: token,
            errorMessage: FileTransferError.transferCancelled.localizedDescription
        )
        XCTAssertNil(manager.activeTransfers[transferID])
        XCTAssertEqual(manager.transferHistory.last?.id, transferID)
        XCTAssertEqual(manager.transferHistory.last?.status, .failed)
    }

    func testCleanupCancelsExternalTransportWithoutOverwritingItsRealTerminalOutcome() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferID = UUID().uuidString
        var cancellationCount = 0
        let token = try XCTUnwrap(manager.beginExternalInboundTransfer(
            transferId: transferID,
            fileName: "incoming.bin",
            fileSize: 10,
            fromDeviceId: "peer",
            fromDeviceName: "Peer",
            cancellationHandler: {
                cancellationCount += 1
            }
        ))

        manager.cleanup()

        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNotNil(manager.activeTransfers[transferID])
        manager.failExternalTransfer(
            token: token,
            errorMessage: FileTransferError.transferCancelled.localizedDescription
        )
        XCTAssertTrue(manager.activeTransfers.isEmpty)
        XCTAssertEqual(manager.transferHistory.last?.id, transferID)
        XCTAssertEqual(manager.transferHistory.last?.status, .failed)
    }

    func testExternalInboundTerminalEvidenceMovesToHistory() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferID = UUID().uuidString
        let token = try XCTUnwrap(manager.beginExternalInboundTransfer(
            transferId: transferID,
            fileName: "durable.bin",
            fileSize: 10,
            fromDeviceId: "peer",
            fromDeviceName: "Peer",
            cancellationHandler: {}
        ))
        let savedURL = FileManager.default.temporaryDirectory.appendingPathComponent("durable.bin")

        manager.completeExternalInboundTransfer(
            token: token,
            savedTo: savedURL,
            receiptDeliveryStatus: .unknown,
            operationalWarning: FileTransferError.committedFileReleaseFailed.localizedDescription
        )

        let history = try XCTUnwrap(manager.transferHistory.first(where: { $0.id == transferID }))
        XCTAssertEqual(history.localPath, savedURL)
        XCTAssertEqual(history.receiptDeliveryStatus, .unknown)
        XCTAssertEqual(
            history.error,
            FileTransferError.committedFileReleaseFailed.localizedDescription
        )
    }

    func testStopClearsCompletedTransferActivityGraceState() async throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let token = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: UUID().uuidString,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("grace.bin"),
            fileSize: 1,
            toDeviceId: "peer",
            toDeviceName: "Peer",
            cancellationHandler: {}
        ))
        manager.completeExternalOutboundTransfer(token: token)
        XCTAssertTrue(manager.isTransferring)

        await manager.stop()

        XCTAssertFalse(manager.isTransferring)
        XCTAssertEqual(manager.totalProgress, 0)
    }

    func testStopWaitsForExternalTokenToPublishItsRealCancellationTerminalState() async throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferID = UUID().uuidString
        var cancellationCount = 0
        let token = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: transferID,
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("external-stop.bin"),
            fileSize: 1,
            toDeviceId: "peer",
            toDeviceName: "Peer",
            cancellationHandler: {
                cancellationCount += 1
            }
        ))
        let completionProbe = ExternalTransferStopCompletionProbe()
        let stopTask = Task { @MainActor in
            await manager.stop()
            await completionProbe.markCompleted()
        }

        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while cancellationCount == 0, ContinuousClock.now < cancellationDeadline {
            await Task.yield()
        }

        XCTAssertEqual(cancellationCount, 1)
        let completedBeforeTerminalState = await completionProbe.isCompleted
        XCTAssertFalse(completedBeforeTerminalState)
        XCTAssertNotNil(manager.activeTransfers[transferID])

        manager.cancelExternalOutboundTransfer(token: token)
        await stopTask.value

        let completedAfterTerminalState = await completionProbe.isCompleted
        XCTAssertTrue(completedAfterTerminalState)
        XCTAssertNil(manager.activeTransfers[transferID])
        let terminalTransfer = try XCTUnwrap(
            manager.transferHistory.last(where: { $0.id == transferID })
        )
        XCTAssertEqual(terminalTransfer.status, .cancelled)
        XCTAssertEqual(
            terminalTransfer.error,
            FileTransferError.transferCancelled.localizedDescription
        )
        XCTAssertFalse(manager.isTransferring)
        XCTAssertEqual(manager.totalProgress, 0)
    }

    func testCleanupClearsCompletedTransferActivityGraceState() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { XCTAssertNoThrow(try historyStore.remove()) }

        let manager = FileTransferManager(historyStore: historyStore)
        let token = try XCTUnwrap(manager.beginExternalOutboundTransfer(
            transferId: UUID().uuidString,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-grace.bin"),
            fileSize: 1,
            toDeviceId: "peer",
            toDeviceName: "Peer",
            cancellationHandler: {}
        ))
        manager.completeExternalOutboundTransfer(token: token)
        XCTAssertTrue(manager.isTransferring)

        manager.cleanup()

        XCTAssertFalse(manager.isTransferring)
        XCTAssertEqual(manager.totalProgress, 0)
    }

    func testFileTransferEncryptionAlgorithmIsSingleSupportedAES256GCMState() throws {
        XCTAssertEqual(
            try FileTransferEncryptionAlgorithm(persistedValue: "AES-256-GCM"),
            .aes256GCM
        )
        XCTAssertEqual(
            try FileTransferEncryptionAlgorithm(persistedValue: "AES-256"),
            .aes256GCM
        )
        XCTAssertThrowsError(try FileTransferEncryptionAlgorithm(persistedValue: "ChaCha20"))
        XCTAssertThrowsError(try FileTransferEncryptionAlgorithm(persistedValue: "AES-128"))
    }
}

private final class RecordingPowerAssertion: FileTransferPowerAssertionControlling {
    struct Update: Equatable {
        let shouldKeepAwake: Bool
        let hasActiveTransfers: Bool
    }

    private(set) var updates: [Update] = []
    private(set) var releaseCount = 0
    private(set) var isHoldingAssertion = false

    func update(shouldKeepAwake: Bool, hasActiveTransfers: Bool) {
        updates.append(Update(shouldKeepAwake: shouldKeepAwake, hasActiveTransfers: hasActiveTransfers))
        let shouldHold = shouldKeepAwake && hasActiveTransfers
        if isHoldingAssertion && !shouldHold {
            releaseCount += 1
        }
        isHoldingAssertion = shouldHold
    }

    func release() {
        if isHoldingAssertion {
            releaseCount += 1
        }
        isHoldingAssertion = false
    }
}

private actor ExternalTransferStopCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}

private struct FileTransferProgressEvent: Sendable {
    let transferId: String
    let progress: Double
    let transferredBytes: Int64
    let fileSize: Int64
    let totalBytes: Int64
    let direction: String

    init?(userInfo: [AnyHashable: Any]) {
        guard let transferId = userInfo["transferId"] as? String,
              let progress = userInfo["progress"] as? Double,
              let transferredBytes = Self.int64Value(userInfo["transferredBytes"]),
              let fileSize = Self.int64Value(userInfo["fileSize"]),
              let totalBytes = Self.int64Value(userInfo["totalBytes"]),
              let direction = userInfo["direction"] as? String else {
            return nil
        }

        self.transferId = transferId
        self.progress = progress
        self.transferredBytes = transferredBytes
        self.fileSize = fileSize
        self.totalBytes = totalBytes
        self.direction = direction
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        return nil
    }
}

private final class FileTransferProgressEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FileTransferProgressEvent] = []

    func append(_ event: FileTransferProgressEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func last(transferId: String) -> FileTransferProgressEvent? {
        lock.lock()
        defer { lock.unlock() }
        return events.last { $0.transferId == transferId }
    }
}
