import XCTest

@testable import SkyBridgeCore

@MainActor
final class FileTransferSettingsRuntimeTests: XCTestCase {
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

    func testKeepAwakeSettingControlsTransferLifecycleAssertion() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { try? historyStore.remove() }

        let powerAssertion = RecordingPowerAssertion()
        let manager = FileTransferManager(historyStore: historyStore, powerAssertion: powerAssertion)
        manager.updateSettings(keepSystemAwakeDuringTransfer: true)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        try Data("awake".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let transferId = UUID().uuidString
        manager.beginExternalOutboundTransfer(
            transferId: transferId,
            fileURL: fileURL,
            fileSize: 5,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone"
        )

        XCTAssertTrue(powerAssertion.isHoldingAssertion)
        XCTAssertEqual(powerAssertion.updates.last?.shouldKeepAwake, true)
        XCTAssertEqual(powerAssertion.updates.last?.hasActiveTransfers, true)

        manager.completeExternalOutboundTransfer(transferId: transferId)

        XCTAssertFalse(powerAssertion.isHoldingAssertion)
        XCTAssertEqual(powerAssertion.updates.last?.hasActiveTransfers, false)
        XCTAssertEqual(powerAssertion.releaseCount, 1)
    }

    func testKeepAwakeDisabledDoesNotAcquireAssertionForActiveTransfer() throws {
        let relativePath = "FileTransferTests/\(UUID().uuidString).json"
        let historyStore = CodablePersistenceStore<[PersistedFileTransferHistoryEntry]>(
            location: .protectedApplicationSupport(path: relativePath),
            rootDirectoryName: "SkyBridgeStateTests"
        )
        defer { try? historyStore.remove() }

        let powerAssertion = RecordingPowerAssertion()
        let manager = FileTransferManager(historyStore: historyStore, powerAssertion: powerAssertion)
        manager.updateSettings(keepSystemAwakeDuringTransfer: false)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        try Data("awake-disabled".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        manager.beginExternalOutboundTransfer(
            transferId: UUID().uuidString,
            fileURL: fileURL,
            fileSize: 14,
            toDeviceId: "peer-device",
            toDeviceName: "Bill iPhone"
        )

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
        defer { try? historyStore.remove() }

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

        manager.beginExternalOutboundTransfer(
            transferId: smallTransferId,
            fileURL: smallFileURL,
            fileSize: 100,
            toDeviceId: "peer-a",
            toDeviceName: "Peer A"
        )
        manager.beginExternalOutboundTransfer(
            transferId: largeTransferId,
            fileURL: largeFileURL,
            fileSize: 900,
            toDeviceId: "peer-b",
            toDeviceName: "Peer B"
        )

        manager.updateExternalOutboundProgress(transferId: smallTransferId, transferredBytes: 100)
        XCTAssertEqual(manager.activeTransfers[smallTransferId]?.progress, 1.0)
        XCTAssertEqual(manager.totalProgress, 0.1, accuracy: 0.000_001)

        manager.updateExternalOutboundProgress(transferId: largeTransferId, transferredBytes: 450)
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
        defer { try? historyStore.remove() }

        let manager = FileTransferManager(historyStore: historyStore)
        let transferId = UUID().uuidString

        manager.beginExternalInboundTransfer(
            transferId: transferId,
            fileName: "incoming.mov",
            fileSize: 200,
            fromDeviceId: "peer-in",
            fromDeviceName: "Peer In"
        )
        manager.updateExternalInboundProgress(transferId: transferId, transferredBytes: 50)

        let transfer = try XCTUnwrap(manager.activeTransfers[transferId])
        XCTAssertEqual(transfer.status, .transferring)
        XCTAssertEqual(transfer.transferredBytes, 50)
        XCTAssertEqual(transfer.progress, 0.25)
        XCTAssertEqual(manager.totalProgress, 0.25, accuracy: 0.000_001)
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
