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
